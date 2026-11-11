usage() {
  echo "Usage: set-hugepages [count]" >&2
  echo "Set vm.nr_hugepages. Defaults to FPGA_NIX_HUGEPAGES or 1024." >&2
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

if [ $# -gt 1 ]; then
  usage
  exit 1
fi

# COYOTE_HUGEPAGES is the variable name used by older coyote-nix shells.
count="${1:-$(fpga_nix_env HUGEPAGES || printf '%s\n' "${COYOTE_HUGEPAGES:-1024}")}"
if [[ ! "$count" =~ ^[0-9]+$ ]]; then
  echo "ERROR: hugepage count must be a non-negative integer: $count" >&2
  exit 1
fi
sudo sysctl -w "vm.nr_hugepages=$count"
