usage() {
  echo "Usage: program-fpga image.sof" >&2
  echo "Program an Intel FPGA over JTAG with quartus_pgm. Pass the image path" >&2
  echo "explicitly or set FPGA_BITSTREAM. FPGA_PART_HINT selects the device on" >&2
  echo "the JTAG chain and the optional FPGA_JTAG_TARGET selects the cable." >&2
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

image="${1:-${FPGA_BITSTREAM:-}}"
part_hint="${FPGA_PART_HINT:-}"
target_hint="${FPGA_JTAG_TARGET:-}"

if [ -z "$image" ]; then
  echo "ERROR: program-fpga requires an image path or FPGA_BITSTREAM." >&2
  usage
  exit 1
fi
if [ -z "$part_hint" ]; then
  echo "ERROR: FPGA_PART_HINT is required (a substring of the device name)." >&2
  exit 1
fi
case "$image" in
  *.sof) ;;
  *)
    echo "ERROR: image must be a .sof file: $image" >&2
    exit 1
    ;;
esac
if [ ! -f "$image" ]; then
  echo "ERROR: image not found: $image" >&2
  exit 1
fi

fpga_nix_require_cmd jtagconfig
fpga_nix_require_cmd quartus_pgm

# jtagconfig lists each cable as "N) name [port]", followed by one indented
# "IDCODE device-name" line per device on its chain. quartus_pgm addresses
# devices by their 1-based position on the chain.
chain="$(jtagconfig)" || {
  echo "ERROR: jtagconfig failed:" >&2
  printf '%s\n' "$chain" >&2
  exit 1
}

matches=()
cable=""
position=0
while IFS= read -r line; do
  # Drop progress output that ends in a carriage return.
  line="${line##*$'\r'}"
  if [[ "$line" =~ ^[0-9]+\)\ (.+)$ ]]; then
    cable="${BASH_REMATCH[1]}"
    position=0
  elif [[ -n "$cable" && "$line" =~ ^[[:space:]]+[[:xdigit:]]{8}[[:space:]]+(.+)$ ]]; then
    position=$((position + 1))
    device="${BASH_REMATCH[1]}"
    if [ -n "$target_hint" ] && [[ "${cable,,}" != *"${target_hint,,}"* ]]; then
      continue
    fi
    if [[ "${device,,}" == *"${part_hint,,}"* ]]; then
      matches+=("$cable"$'\t'"$position"$'\t'"$device")
    fi
  fi
done <<<"$chain"

if [ "${#matches[@]}" -ne 1 ]; then
  scope=""
  if [ -n "$target_hint" ]; then
    scope=" on cables matching '$target_hint'"
  fi
  echo "ERROR: expected exactly one device matching '$part_hint'$scope" \
    "but found ${#matches[@]}." >&2
  echo "JTAG chain:" >&2
  printf '%s\n' "$chain" | sed 's/^/  /' >&2
  exit 1
fi

IFS=$'\t' read -r cable position device <<<"${matches[0]}"

# Two programming runs on one cable would interfere with each other.
lock_name="${cable//[^a-zA-Z0-9_.-]/_}"
lock_dir="$(fpga_nix_env_or PROGRAM_LOCK_DIR "/tmp/fpga-nix-program-intel-$lock_name.lock")"
if ! mkdir "$lock_dir" 2>/dev/null; then
  echo "ERROR: another program-fpga invocation appears to be using cable" \
    "'$cable'. Lock: $lock_dir" >&2
  exit 1
fi
printf 'user=%s\npid=%s\n' "$(id -un 2>/dev/null || id -u)" "$$" >"$lock_dir/info" || true
trap 'rm -rf "$lock_dir"' EXIT
trap 'exit 130' INT TERM

echo "Programming $device (position $position) on '$cable' with $image"
quartus_pgm -c "$cable" -m jtag -o "p;$image@$position"
