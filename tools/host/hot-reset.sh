usage() {
  echo "Usage: hot-reset [bdf]" >&2
  echo "Run a PCIe secondary-bus hot reset for the FPGA endpoint." >&2
  echo "If bdf is omitted, FPGA_BDF is used." >&2
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

bdf="${1:-${FPGA_BDF:-}}"
reset_hold_s="$(fpga_nix_env_or HOT_RESET_HOLD_S 0.5)"
post_reset_settle_s="$(fpga_nix_env_or HOT_RESET_SETTLE_S 2)"
ready_timeout_s="$(fpga_nix_env_or HOT_RESET_READY_TIMEOUT_S 30)"
ready_poll_s="$(fpga_nix_env_or HOT_RESET_READY_POLL_S 0.2)"
# A secondary-bus hot reset is not always enough after reprogramming: Linux
# can keep stale endpoint/BAR state. By default the endpoint is removed and
# rediscovered after the reset. Set FPGA_NIX_HOT_RESET_PCI_RESCAN=0 to skip it.
pci_rescan="$(fpga_nix_env_or HOT_RESET_PCI_RESCAN 1)"
rescan_settle_s="$(fpga_nix_env_or HOT_RESET_RESCAN_SETTLE_S 2)"
pci_sysfs_root="$(fpga_nix_env_or PCI_SYSFS_ROOT /sys/bus/pci)"
# PCI vendor IDs that may appear in the reset domain. Nix sets the default.
read -r -a fpga_vendors <<<"$(fpga_nix_env_or PCI_VENDORS "@FPGA_PCI_VENDORS@")"

dev="$bdf"
if [ -z "$dev" ]; then
  echo "ERROR: missing BDF. Pass it as argument or set FPGA_BDF." >&2
  exit 1
fi

if [ ! -e "$pci_sysfs_root/devices/$dev" ]; then
  dev="0000:$dev"
fi

if [ ! -e "$pci_sysfs_root/devices/$dev" ]; then
  echo "ERROR: device $dev not found" >&2
  exit 1
fi

if ! command -v setpci >/dev/null 2>&1; then
  echo "ERROR: setpci is required for bridge-level hot reset." >&2
  exit 1
fi

endpoint_path="$(readlink -f "$pci_sysfs_root/devices/$dev")"
bridge_path="$(dirname "$endpoint_path")"
port="$(basename "$bridge_path")"
if [ ! -e "$pci_sysfs_root/devices/$port" ]; then
  echo "ERROR: upstream port $port not found" >&2
  exit 1
fi

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

read_cfg_word() {
  sudo setpci -s "$1" "$2" 2>/dev/null | tr -d '[:space:]'
}

is_fpga_vendor() {
  local vendor
  for vendor in "${fpga_vendors[@]}"; do
    [ "$1" != "$vendor" ] || return 0
  done
  return 1
}

wait_for_endpoint_ready() {
  local deadline vendor_id context="${1:-hot reset}"
  deadline=$(($(date +%s) + ready_timeout_s))

  while :; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "ERROR: endpoint $dev did not become config-space-ready within" \
        "${ready_timeout_s}s after $context" >&2
      return 1
    fi

    vendor_id="$(read_cfg_word "$dev" VENDOR_ID || true)"
    vendor_id="${vendor_id,,}"
    if [[ "$vendor_id" =~ ^[0-9a-f]{4}$ ]] &&
      [ "$vendor_id" != ffff ] && [ "$vendor_id" != 0000 ]; then
      sleep "$post_reset_settle_s"
      return 0
    fi

    sleep "$ready_poll_s"
  done
}

pci_rescan_enabled() {
  case "${pci_rescan,,}" in
    0 | false | no | off) return 1 ;;
    *) return 0 ;;
  esac
}

# Only a directly attached, exclusive FPGA slot is allowed. A switch or another
# endpoint below this bridge would widen the reset domain.
validate_reset_domain() {
  local path resolved name vendor class bus_number require_endpoint="${1:-1}"
  functions=()
  for path in "$pci_sysfs_root"/devices/*; do
    resolved="$(readlink -f "$path")" || fail "cannot resolve PCI device $path"
    name="$(basename "$path")"
    # Check both ancestry and the hardware forwarding bus range.
    if [[ "$resolved" != "$bridge_path/"* ]]; then
      if [[ "${name:0:4}" == "${dev:0:4}" && "${name:5:2}" =~ ^[[:xdigit:]]{2}$ ]]; then
        bus_number=$((16#${name:5:2}))
        if ((bus_number >= 16#$secondary && bus_number <= 16#$subordinate)); then
          fail "device $name in reset bus range outside verified ancestry"
        fi
      fi
      continue
    fi
    [[ "$(dirname "$resolved")" == "$bridge_path" && "${name%.*}" == "${dev%.*}" ]] ||
      fail "foreign descendant $name in reset domain"
    [[ ! -e "$path/driver" && ! -L "$path/driver" ]] ||
      fail "reset domain function $name is driver-bound"
    vendor="$(<"$path/vendor")"
    class="$(<"$path/class")"
    is_fpga_vendor "$vendor" && [[ "$class" =~ ^0x[[:xdigit:]]{6}$ && "$class" != 0x06* ]] ||
      fail "non-FPGA endpoint $name in reset domain"
    if pci_rescan_enabled; then
      [[ -e "$path/remove" ]] || fail "function $name cannot be removed"
    fi
    functions+=("$name")
  done
  if ((require_endpoint)); then
    [[ " ${functions[*]} " == *" $dev "* ]] || fail "selected endpoint disappeared"
  fi
}

rescan_until_endpoint_found() {
  local deadline attempt=0
  deadline=$(($(date +%s) + ready_timeout_s))

  while :; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "ERROR: endpoint $dev did not reappear within ${ready_timeout_s}s" \
        "of scoped PCI rescans" >&2
      return 1
    fi
    # A missed scan does not schedule rediscovery on a non-hotplug bus.
    # Revalidate the same reset domain before each bounded attempt.
    [[ "$(readlink -f "$pci_sysfs_root/devices/$port")" == "$bridge_path" ]] ||
      fail "bridge ancestry changed during rediscovery"
    [[ "$(read_cfg_word "$port" SECONDARY_BUS)" == "$secondary" &&
      "$(read_cfg_word "$port" SUBORDINATE_BUS)" == "$subordinate" ]] ||
      fail "bridge bus range changed during rediscovery"
    [[ "$(readlink -f "$bus_rescan")" == "$bridge_path/pci_bus/${dev:0:7}/rescan" ]] ||
      fail "subordinate bus ancestry changed during rediscovery"
    validate_reset_domain 0
    attempt=$((attempt + 1))
    echo "Scoped PCI discovery attempt $attempt for $dev"
    echo 1 | sudo tee "$bus_rescan" >/dev/null
    if [ -e "$pci_sysfs_root/devices/$dev" ]; then
      validate_reset_domain
      return 0
    fi

    sleep "$ready_poll_s"
  done
}

remove_and_rescan_endpoint() {
  local function_dev

  validate_reset_domain

  echo "Removing endpoint functions for $dev from the Linux PCI tree and rescanning..."

  if [ ! -e "$pci_sysfs_root/devices/$dev/remove" ]; then
    echo "ERROR: $pci_sysfs_root/devices/$dev/remove is not available" >&2
    return 1
  fi

  for function_dev in "${functions[@]}"; do
    if [ "$function_dev" != "$dev" ]; then
      echo "Removing sibling function $function_dev"
      echo 1 | sudo tee "$pci_sysfs_root/devices/$function_dev/remove" >/dev/null
    fi
  done

  echo 1 | sudo tee "$pci_sysfs_root/devices/$dev/remove" >/dev/null
  sleep 1
  rescan_until_endpoint_found
  wait_for_endpoint_ready "PCI rescan"
  sleep "$rescan_settle_s"
}

bdf_re='^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$'
[[ "$dev" =~ $bdf_re ]] || fail "invalid endpoint BDF"
[[ "$port" =~ $bdf_re ]] || fail "invalid bridge BDF"
[[ "$(readlink -f "$pci_sysfs_root/devices/$port")" == "$bridge_path" ]] ||
  fail "ambiguous bridge ancestry"
[[ "$(<"$bridge_path/class")" == 0x0604* ]] || fail "parent is not a PCI bridge"
primary="$(read_cfg_word "$port" PRIMARY_BUS)"
secondary="$(read_cfg_word "$port" SECONDARY_BUS)"
subordinate="$(read_cfg_word "$port" SUBORDINATE_BUS)"
for bus in "$primary" "$secondary" "$subordinate"; do
  [[ "$bus" =~ ^[[:xdigit:]]{2}$ ]] || fail "invalid bridge bus register"
done
[[ "${primary,,}" == "${port:5:2}" && "${secondary,,}" == "${dev:5:2}" &&
  "${dev:0:4}" == "${port:0:4}" ]] ||
  fail "bridge bus registers disagree with endpoint topology"
((16#$secondary > 16#$primary && 16#$subordinate >= 16#$secondary)) ||
  fail "invalid bridge bus range"
bus_rescan="$bridge_path/pci_bus/${dev:0:7}/rescan"
if pci_rescan_enabled; then
  [[ -e "$bus_rescan" ]] || fail "subordinate bus rescan is unavailable"
  [[ "$(readlink -f "$bus_rescan")" == "$bridge_path/pci_bus/${dev:0:7}/rescan" ]] ||
    fail "ambiguous subordinate bus ancestry"
fi

validate_reset_domain

orig_bridge_control="$(read_cfg_word "$port" BRIDGE_CONTROL)"
[[ "$orig_bridge_control" =~ ^[[:xdigit:]]{4}$ ]] ||
  fail "unexpected BRIDGE_CONTROL value for $port: ${orig_bridge_control:-<empty>}"

orig_bridge_control="${orig_bridge_control,,}"
((16#$orig_bridge_control != 65535 && (16#$orig_bridge_control & 64) == 0)) ||
  fail "invalid or already asserted BRIDGE_CONTROL"
asserted_bridge_control="$(printf '%04x' "$((0x$orig_bridge_control | 0x0040))")"
restore_pending=0

restore_bridge() {
  local current
  current="$(read_cfg_word "$port" BRIDGE_CONTROL)" || return 1
  current="${current,,}"
  if [[ "$current" == "$asserted_bridge_control" ]]; then
    sudo setpci -s "$port" BRIDGE_CONTROL="$orig_bridge_control" || return 1
    current="$(read_cfg_word "$port" BRIDGE_CONTROL)" || return 1
    current="${current,,}"
  fi
  if [[ "$current" != "$orig_bridge_control" ]]; then
    echo "ERROR: unexpected BRIDGE_CONTROL=$current; refusing to overwrite" \
      "concurrent changes" >&2
    return 1
  fi
  restore_pending=0
}

cleanup() {
  local rc=$?
  trap - EXIT
  trap '' HUP INT TERM
  if ((restore_pending)); then
    if ! restore_bridge; then
      echo "ERROR: BRIDGE_CONTROL restoration not verified for $port" >&2
      rc=1
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Secondary-bus hot reset via upstream bridge $port for endpoint $dev..."
echo "Hold=${reset_hold_s}s settle=${post_reset_settle_s}s" \
  "ready-timeout=${ready_timeout_s}s pci-rescan=${pci_rescan}"
[[ "$(read_cfg_word "$port" BRIDGE_CONTROL)" == "$orig_bridge_control" ]] ||
  fail "BRIDGE_CONTROL changed before assertion"
restore_pending=1
sudo setpci -s "$port" BRIDGE_CONTROL="$asserted_bridge_control"
[[ "$(read_cfg_word "$port" BRIDGE_CONTROL)" == "$asserted_bridge_control" ]] ||
  fail "reset assertion readback failed"
sleep "$reset_hold_s"
restore_bridge || fail "BRIDGE_CONTROL restoration failed"

echo "Restored BRIDGE_CONTROL=$orig_bridge_control on $port"
wait_for_endpoint_ready "hot reset"

if pci_rescan_enabled; then
  remove_and_rescan_endpoint
fi

echo "Endpoint $dev is config-space-ready again"
