# Helpers for running Intel Quartus tools inside a Quartus FHS shell.
# Nix prepends tools/common.sh and substitutes the @...@ placeholders.

fpga_nix_default_quartus_share_root="@QUARTUS_SHARE_ROOT@"
fpga_nix_default_quartus_shell="@QUARTUS_SHELL@"

fpga_nix_shell_quote() {
  printf '%q' "$1"
}

fpga_nix_quartus_share_root() {
  printf '%s\n' "$fpga_nix_default_quartus_share_root"
}

# Print the requested Quartus version. As for Xilinx, nothing is guessed from
# the installation: the site flake decides which version a board uses.
fpga_nix_quartus_version() {
  local version
  if ! version="$(fpga_nix_env QUARTUS_VERSION)"; then
    echo "ERROR: FPGA_NIX_QUARTUS_VERSION is not set" >&2
    return 1
  fi
  printf '%s\n' "$version"
}

# Print the installation root of the requested version.
fpga_nix_quartus_root() {
  local version root
  version="$(fpga_nix_quartus_version)" || return 1
  root="$(fpga_nix_quartus_share_root)/$version"
  if [ ! -x "$root/quartus/bin/quartus_sh" ]; then
    echo "ERROR: Quartus $version not found under $(fpga_nix_quartus_share_root)" >&2
    return 1
  fi
  printf '%s\n' "$root"
}

fpga_nix_resolve_quartus_shell() {
  local shell
  if shell="$(fpga_nix_env QUARTUS_SHELL)" && [ -x "$shell" ]; then
    printf '%s\n' "$shell"
  elif [ -n "$fpga_nix_default_quartus_shell" ] && [ -x "$fpga_nix_default_quartus_shell" ]; then
    printf '%s\n' "$fpga_nix_default_quartus_shell"
  else
    return 1
  fi
}

# Print shell code that selects one Quartus installation inside the shell.
fpga_nix_quartus_prelude() {
  local root="$1" q_root license out

  q_root="$(fpga_nix_shell_quote "$root")"
  # Settings from other installations, for example a host profile, would mix
  # tools and device data from different versions.
  out="unset QUARTUS_ROOTDIR QUARTUS_ROOTDIR_OVERRIDE QSYS_ROOTDIR QUARTUS_64BIT;"
  out="$out export QUARTUS_ROOTDIR=$q_root/quartus QUARTUS_ROOTDIR_OVERRIDE=$q_root/quartus;"
  out="$out export QSYS_ROOTDIR=$q_root/qsys/bin;"
  out="$out export PATH=$q_root/quartus/bin:$q_root/qsys/bin\"\${PATH:+:\$PATH}\";"
  if license="$(fpga_nix_env QUARTUS_LICENSE_FILE)"; then
    out="$out export LM_LICENSE_FILE=$(fpga_nix_shell_quote "$license");"
  fi
  printf '%s\n' "$out"
}

# Run a shell command with the selected Quartus inside the Quartus shell.
# Usage: fpga_nix_quartus_exec <command> [args...]
fpga_nix_quartus_exec() {
  local command="$1" shell root prelude
  shift

  root="$(fpga_nix_quartus_root)" || return 1
  if ! shell="$(fpga_nix_resolve_quartus_shell)"; then
    echo "ERROR: Quartus shell not found; set FPGA_NIX_QUARTUS_SHELL" >&2
    return 127
  fi
  prelude="$(fpga_nix_quartus_prelude "$root")"
  exec "$shell" -c "$prelude $command" -- "$@"
}

# Resolve a tool of the selected installation: quartus/bin, then qsys/bin.
fpga_nix_quartus_tool() {
  local tool="$1" root dir
  root="$(fpga_nix_quartus_root)" || return 1
  for dir in quartus/bin qsys/bin; do
    if [ -x "$root/$dir/$tool" ]; then
      printf '%s\n' "$root/$dir/$tool"
      return 0
    fi
  done
  echo "ERROR: $tool not found in Quartus $(fpga_nix_quartus_version)" >&2
  return 1
}
