# Helpers for running Xilinx tools inside the site's xilinx-shell.
# Nix prepends tools/common.sh and substitutes the @...@ placeholders.

fpga_nix_default_xilinx_share_root="@XILINX_SHARE_ROOT@"
fpga_nix_default_ncurses6_lib="@NCURSES6_LIB@"

fpga_nix_shell_quote() {
  printf '%q' "$1"
}

fpga_nix_xilinx_share_root() {
  printf '%s\n' "$fpga_nix_default_xilinx_share_root"
}

# Find a path inside a Xilinx component for one version. Both supported
# install layouts are tried: <root>/<version>/<component> and
# <root>/<component>/<version>. <relpath> is empty or starts with "/".
# Usage: fpga_nix_xilinx_find <test-op> <component> <version> <relpath>
fpga_nix_xilinx_find() {
  local test_op="$1" component="$2" version="$3" relpath="$4" root p
  root="$(fpga_nix_xilinx_share_root)"
  for p in "$root/$version/$component$relpath" "$root/$component/$version$relpath"; do
    if test "$test_op" "$p"; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

# Print the requested Xilinx version. There is deliberately no fallback to
# "whatever is installed": the site flake decides which version a board uses.
fpga_nix_xilinx_version() {
  local version
  if ! version="$(fpga_nix_env XILINX_VERSION)"; then
    echo "ERROR: FPGA_NIX_XILINX_VERSION is not set" >&2
    return 1
  fi
  printf '%s\n' "$version"
}

fpga_nix_xilinx_license_file() {
  fpga_nix_env XILINX_LICENSE_FILE
}

fpga_nix_hw_server_port() {
  fpga_nix_env HW_SERVER_PORT || printf '%s\n' "${HW_SERVER_PORT:-3121}"
}

# Make sure a hw_server log is writable, falling back to a second path.
fpga_nix_prepare_hw_server_log() {
  local log_path="$1" fallback_path="${2:-}"

  mkdir -p "$(dirname "$log_path")" 2>/dev/null || true
  if : >>"$log_path" 2>/dev/null; then
    chmod a+rw "$log_path" 2>/dev/null || true
    printf '%s\n' "$log_path"
    return 0
  fi

  if [ -n "$fallback_path" ] && [ "$fallback_path" != "$log_path" ]; then
    mkdir -p "$(dirname "$fallback_path")"
    : >>"$fallback_path"
    chmod a+rw "$fallback_path" 2>/dev/null || true
    echo "hw_server: log $log_path is not writable; using $fallback_path" >&2
    printf '%s\n' "$fallback_path"
    return 0
  fi

  echo "ERROR: hw_server log is not writable: $log_path" >&2
  return 1
}

fpga_nix_gmake_compat_dir() {
  # Keep compatibility state ephemeral and out of $HOME.
  fpga_nix_env GMAKE_COMPAT_DIR ||
    printf '%s\n' "${TMPDIR:-${XDG_RUNTIME_DIR:-/tmp}}/fpga-nix-gmake-${UID:-0}/bin"
}

# Print shell code that prepares the environment inside xilinx-shell:
# Tcl user data, ncurses compatibility, license variables and a gmake shim.
fpga_nix_xilinx_env_prelude() {
  local out lib libdir license compat q

  # User Tcl-store caches can be stale or owned by someone else. Prefer the
  # apps shipped with the selected installation unless the caller opts in.
  # shellcheck disable=SC2016 # Expanded later, inside xilinx-shell.
  out='export XILINX_LOCAL_USER_DATA="${XILINX_LOCAL_USER_DATA:-no}";'

  lib="$(fpga_nix_env NCURSES6_LIB || printf '%s\n' "$fpga_nix_default_ncurses6_lib")"
  if [ -n "$lib" ] && [ -e "$lib" ]; then
    libdir="$(fpga_nix_shell_quote "$(dirname "$lib")")"
    out="$out case \":\${LD_LIBRARY_PATH:-}:\" in *:$libdir:*) ;;"
    out="$out *) export LD_LIBRARY_PATH=$libdir\"\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\";;"
    out="$out esac;"
  fi

  if license="$(fpga_nix_xilinx_license_file)"; then
    q="$(fpga_nix_shell_quote "$license")"
    out="$out export XILINXD_LICENSE_FILE=$q XILINX_LICENSE_FILE=$q LM_LICENSE_FILE=$q;"
  fi

  # Current Xilinx FHS environments provide gmake. Older ones only have make.
  compat="$(fpga_nix_shell_quote "$(fpga_nix_gmake_compat_dir)")"
  out="$out if ! command -v gmake >/dev/null 2>&1 && command -v make >/dev/null 2>&1;"
  out="$out then mkdir -p $compat; ln -sf \"\$(command -v make)\" $compat/gmake;"
  out="$out case \":\${PATH:-}:\" in *:$compat:*) ;;"
  out="$out *) export PATH=$compat\"\${PATH:+:\$PATH}\";; esac; fi;"

  printf '%s\n' "$out"
}

# Print shell code that selects exactly one Xilinx version inside xilinx-shell.
fpga_nix_xilinx_version_prelude() {
  local version="$1" root out settings component q

  root="$(fpga_nix_shell_quote "$(fpga_nix_xilinx_share_root)")"

  # xilinx-shell may source a default version from its /etc/profile. Mixing a
  # tool binary with another version's XILINX_* variables corrupts the part
  # database initialization, so clear that state first.
  out="unset XILINX_VIVADO XILINX_HLS XILINX_VITIS XILINX_SDX XILINX_PATH"
  out="$out MYVIVADO MYXILINX RDI_BINROOT RDI_APPROOT RDI_BASEROOT"
  out="$out RDI_INSTALLROOT RDI_INSTALLVER RDI_BASELINE RDI_PATCHROOT"
  out="$out RDI_SHARED_DATA HDI_APPROOT _RDI_SETENV_RUN;"
  out="$out PATH=\"\$(printf '%s' \"\$PATH\" | tr ':' '\n'"
  out="$out | awk -v root=$root '\$0 !~ (\"^\" root \"/\")' | paste -sd: -)\";"
  out="$out export PATH;"

  for component in Vivado Vitis Vitis_HLS; do
    if settings="$(fpga_nix_xilinx_find -f "$component" "$version" \
      "/.settings64-$component.sh")"; then
      q="$(fpga_nix_shell_quote "$settings")"
      out="$out source $q >/dev/null 2>&1 || true;"
    fi
  done

  printf '%s\n' "$out"
}

fpga_nix_resolve_xilinx_shell() {
  local shell
  if shell="$(fpga_nix_env XILINX_SHELL)" && [ -x "$shell" ]; then
    printf '%s\n' "$shell"
  elif command -v xilinx-shell >/dev/null 2>&1; then
    command -v xilinx-shell
  elif [ -x /run/current-system/sw/bin/xilinx-shell ]; then
    printf '%s\n' /run/current-system/sw/bin/xilinx-shell
  else
    return 1
  fi
}

# Run a shell command for one Xilinx version inside xilinx-shell.
# Usage: fpga_nix_xilinx_exec <version> <command> [args...]
fpga_nix_xilinx_exec() {
  local version="$1" command="$2" shell env_prelude version_prelude
  shift 2

  if ! shell="$(fpga_nix_resolve_xilinx_shell)"; then
    echo "ERROR: xilinx-shell not found; set FPGA_NIX_XILINX_SHELL or add it to PATH" >&2
    return 127
  fi
  env_prelude="$(fpga_nix_xilinx_env_prelude)"
  version_prelude="$(fpga_nix_xilinx_version_prelude "$version")"
  exec "$shell" -c "$version_prelude $env_prelude $command" -- "$@"
}

# Run one tool binary for a Xilinx version inside xilinx-shell.
fpga_nix_xilinx_exec_tool() {
  local version="$1" tool_bin
  tool_bin="$(fpga_nix_shell_quote "$2")"
  shift 2
  fpga_nix_xilinx_exec "$version" "exec $tool_bin \"\$@\"" "$@"
}

# Resolve the version and a tool path, or explain what is missing.
# Usage: fpga_nix_xilinx_tool <component> <relpath>
fpga_nix_xilinx_tool() {
  local component="$1" relpath="$2" version tool
  version="$(fpga_nix_xilinx_version)" || return 1
  if ! tool="$(fpga_nix_xilinx_find -x "$component" "$version" "$relpath")"; then
    echo "ERROR: $component $version$relpath not found under" \
      "$(fpga_nix_xilinx_share_root)" >&2
    return 1
  fi
  printf '%s\n' "$tool"
}
