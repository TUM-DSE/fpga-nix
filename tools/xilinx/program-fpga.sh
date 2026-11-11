usage() {
  echo "Usage: program-fpga image.bit|image.pdi" >&2
  echo "Program a Xilinx FPGA image with Vivado. Pass the image path explicitly" >&2
  echo "or set FPGA_BITSTREAM. FPGA_PART_HINT selects the device and the" >&2
  echo "optional FPGA_JTAG_TARGET restricts the JTAG targets that are searched." >&2
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

if [ -z "$image" ]; then
  echo "ERROR: program-fpga requires an image path or FPGA_BITSTREAM." >&2
  usage
  exit 1
fi

if [ -z "$part_hint" ]; then
  echo "ERROR: FPGA_PART_HINT is required (a substring of the device part)." >&2
  exit 1
fi

case "$image" in
  *.bit | *.pdi) ;;
  *)
    echo "ERROR: image must be a .bit or .pdi file: $image" >&2
    exit 1
    ;;
esac

if [ ! -f "$image" ]; then
  echo "ERROR: image not found: $image" >&2
  exit 1
fi

fpga_nix_require_cmd vivado
fpga_nix_require_cmd hw_server
fpga_nix_require_cmd setsid

umask 000

hw_server_pid=""
hw_server_pgid=""
vivado_pid=""
hw_server_port="$(fpga_nix_hw_server_port)"
hw_server_url="localhost:$hw_server_port"
lock_dir="$(fpga_nix_env_or PROGRAM_LOCK_DIR "/tmp/fpga-nix-program-$hw_server_port.lock")"
lock_acquired=0

# Called through the EXIT trap below. Older shellcheck reports this as SC2317.
# shellcheck disable=SC2317,SC2329
cleanup() {
  if [ -n "$vivado_pid" ] && kill -0 "$vivado_pid" 2>/dev/null; then
    kill "$vivado_pid" 2>/dev/null || true
    wait "$vivado_pid" 2>/dev/null || true
  fi

  if [ -n "$hw_server_pgid" ]; then
    kill -- "-$hw_server_pgid" 2>/dev/null || true
  elif [ -n "$hw_server_pid" ]; then
    kill "$hw_server_pid" 2>/dev/null || true
  fi
  if [ -n "$hw_server_pid" ]; then
    wait "$hw_server_pid" 2>/dev/null || true
  fi

  if [ "$lock_acquired" = 1 ] && [ -d "$lock_dir" ]; then
    rm -rf "$lock_dir" 2>/dev/null || true
  fi
}

trap cleanup EXIT
trap 'exit 130' INT TERM

acquire_lock() {
  if mkdir "$lock_dir" 2>/dev/null; then
    lock_acquired=1
    {
      printf 'user=%s\n' "$(id -un 2>/dev/null || id -u)"
      printf 'uid=%s\n' "$(id -u)"
      printf 'pid=%s\n' "$$"
      printf 'started=%s\n' "$(date -Is 2>/dev/null || date)"
      printf 'cwd=%s\n' "$PWD"
      printf 'hw_server_port=%s\n' "$hw_server_port"
    } >"$lock_dir/info" 2>/dev/null || true
    return 0
  fi

  echo "ERROR: another program-fpga invocation appears to be using hw_server" \
    "port $hw_server_port. Refusing to interfere with its hw_server." >&2
  echo "Lock: $lock_dir" >&2
  if [ -r "$lock_dir/info" ]; then
    echo "Lock owner:" >&2
    sed 's/^/  /' "$lock_dir/info" >&2 || true
  fi
  echo "If the lock is stale, remove it after checking that no programming job" \
    "is active." >&2
  exit 1
}

hw_server_uses_port() {
  local pid="$1" arg saw_s=0 url
  local args=()

  if ! mapfile -d "" -t args <"/proc/$pid/cmdline" 2>/dev/null; then
    return 0
  fi

  for arg in "${args[@]}"; do
    if [ "$saw_s" = 1 ]; then
      url="$arg"
    else
      case "$arg" in
        -s)
          saw_s=1
          continue
          ;;
        -s?*) url="${arg#-s}" ;;
        *) continue ;;
      esac
    fi
    case "$url" in
      *":$hw_server_port" | "$hw_server_port") return 0 ;;
      *) return 1 ;;
    esac
  done

  # hw_server listens on tcp::3121 when no -s option is given.
  [ "$hw_server_port" = 3121 ]
}

find_unowned_hw_servers() {
  local pid session info

  for pid in $(pgrep -x hw_server || true); do
    hw_server_uses_port "$pid" || continue
    # Only the session started below belongs to this invocation. Sharing a
    # UID or holding the lock is not ownership of an existing debug server.
    if [ -n "$hw_server_pgid" ]; then
      session="$(ps -o sid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
      [ "$session" != "$hw_server_pgid" ] || continue
    fi
    info="$(ps -o user= -o pid= -o args= -p "$pid" 2>/dev/null || true)"
    if [ -n "$info" ]; then
      printf '%s\n' "$info"
    else
      printf 'pid=%s hw_server port=%s\n' "$pid" "$hw_server_port"
    fi
  done
}

report_unowned_hw_servers() {
  echo "Existing hw_server process(es), not owned by this invocation:" >&2
  printf '%s\n' "$1" >&2
}

acquire_lock

unowned="$(find_unowned_hw_servers)"
if [ -n "$unowned" ]; then
  echo "ERROR: refusing to use or stop an existing hw_server on port" \
    "$hw_server_port. Ask its owner to stop it, or choose another" \
    "FPGA_NIX_HW_SERVER_PORT." >&2
  report_unowned_hw_servers "$unowned"
  exit 1
fi

fallback_log="${TMPDIR:-/tmp}/hw_server-$(id -u)-$hw_server_port.log"
hw_server_log="${HW_SERVER_LOG:-}"
if [ -z "$hw_server_log" ]; then
  if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] &&
    [ -w "$XDG_RUNTIME_DIR" ]; then
    hw_server_log="$XDG_RUNTIME_DIR/hw_server-$hw_server_port.log"
  else
    hw_server_log="$fallback_log"
  fi
fi
hw_server_log="$(fpga_nix_prepare_hw_server_log "$hw_server_log" "$fallback_log")"

# Start hw_server in its own session so cleanup only stops what we started.
setsid hw_server -L- -s "tcp::$hw_server_port" >"$hw_server_log" 2>&1 &
hw_server_pid="$!"
hw_server_pgid="$hw_server_pid"
sleep 2

if ! kill -0 "$hw_server_pid" 2>/dev/null; then
  echo "ERROR: hw_server exited before programming started." >&2
  echo "hw_server log: $hw_server_log" >&2
  sed 's/^/  /' "$hw_server_log" >&2 || true
  exit 1
fi

unowned="$(find_unowned_hw_servers)"
if [ -n "$unowned" ]; then
  echo "ERROR: an unowned hw_server appeared on port $hw_server_port after" \
    "starting ours; refusing to continue." >&2
  report_unowned_hw_servers "$unowned"
  exit 1
fi

log_dir="$(fpga_nix_build_root)/logs/program-fpga"
mkdir -p "$log_dir"
stamp="$(date +%Y%m%d-%H%M%S)"
vivado_log="$log_dir/program-$stamp.log"
vivado_jou="$log_dir/program-$stamp.jou"

echo "Vivado log: $vivado_log"
echo "Vivado journal: $vivado_jou"
vivado -mode batch -log "$vivado_log" -journal "$vivado_jou" \
  -source "@PROGRAM_TCL@" \
  -tclargs "$image" "$part_hint" "$hw_server_url" "${FPGA_JTAG_TARGET:-}" &
vivado_pid="$!"

set +e
wait "$vivado_pid"
vivado_rc=$?
set -e
vivado_pid=""

exit "$vivado_rc"
