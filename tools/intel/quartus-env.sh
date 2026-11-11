# Run any command with the selected Quartus installation, inside the Quartus
# shell. For projects that build through their own scripts, such as OFS.
# Usage: quartus-env <command> [args...]

if [ "$#" -eq 0 ] || [ "$1" = -h ] || [ "$1" = --help ]; then
  echo "Usage: quartus-env <command> [args...]" >&2
  echo "Run a command with FPGA_NIX_QUARTUS_VERSION's Quartus inside the Quartus shell." >&2
  [ "$#" -gt 0 ]
  exit
fi

# shellcheck disable=SC2016 # Expanded inside the Quartus shell.
fpga_nix_quartus_exec 'exec "$@"' "$@"
