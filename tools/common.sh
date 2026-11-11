# Shared helpers for fpga-nix shell tools.

# Print FPGA_NIX_<name>. The older COYOTE_NIX_<name> is accepted as a fallback
# so existing site flakes and shells keep working during the migration.
fpga_nix_env() {
  local new="FPGA_NIX_$1" old="COYOTE_NIX_$1"
  if [ -n "${!new:-}" ]; then
    printf '%s\n' "${!new}"
  elif [ -n "${!old:-}" ]; then
    printf '%s\n' "${!old}"
  else
    return 1
  fi
}

# Like fpga_nix_env, but print a default when neither variable is set.
fpga_nix_env_or() {
  fpga_nix_env "$1" || printf '%s\n' "$2"
}

fpga_nix_require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $1" >&2
    exit 1
  fi
}

fpga_nix_project_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

fpga_nix_build_root() {
  fpga_nix_env BUILD_ROOT || printf '%s/.build\n' "$(fpga_nix_project_root)"
}
