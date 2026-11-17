# Reach a FlexNet license server from inside the Nix build sandbox.
#
# A sandboxed build has no network, so FlexNet clients cannot connect to a
# floating license server. The build host instead exposes each server port as
# a Unix socket <dir>/<port>.sock and adds <dir> to extra-sandbox-paths. This
# file listens on 127.0.0.1:<port> inside the build and forwards every
# connection to that socket, so the tools can use <lmgrd port>@localhost.
# Clients connect to the vendor daemon on the host they reached lmgrd on, so
# its port has to be forwarded as well.
#
# Source this file; it needs socat on PATH. It replaces the shell's EXIT trap
# to stop the listeners. The listeners are not jobs of the sourcing shell, so a
# later bare `wait`, such as the stage runner's, does not wait for them.

# Usage: fpga_nix_license_relay_start <socket dir> <port>...
fpga_nix_license_relay_start() {
  local dir="$1" port missing=0 tries
  shift

  for port in "$@"; do
    if [ ! -S "$dir/$port.sock" ]; then
      echo "ERROR: license relay socket $dir/$port.sock does not exist." >&2
      missing=1
    fi
  done
  if [ "$missing" = 1 ]; then
    echo "The build host must run a relay to the license server that listens" \
      "on these sockets, and have $dir in extra-sandbox-paths." >&2
    return 1
  fi

  fpga_nix_license_relay_pid_file="$(mktemp "${TMPDIR:-/tmp}/fpga-nix-license-relay.XXXXXX")"
  for port in "$@"; do
    # Started from a subshell, so that they are not jobs of this shell, and
    # not attached to the build's output, which Nix waits on.
    (
      socat "TCP-LISTEN:$port,bind=127.0.0.1,fork,reuseaddr" "UNIX-CONNECT:$dir/$port.sock" \
        </dev/null >>"${TMPDIR:-/tmp}/fpga-nix-license-relay.log" 2>&1 &
      echo "$!" >>"$fpga_nix_license_relay_pid_file"
    )
  done
  trap fpga_nix_license_relay_stop EXIT

  # Wait until every port listens. Probing with a connection would reach the
  # license server, so read the kernel's socket table instead.
  for port in "$@"; do
    tries=0
    until fpga_nix_license_relay_listening "$port"; do
      tries=$((tries + 1))
      if [ "$tries" -gt 100 ]; then
        echo "ERROR: license relay did not start listening on 127.0.0.1:$port:" >&2
        cat "${TMPDIR:-/tmp}/fpga-nix-license-relay.log" >&2 || true
        return 1
      fi
      sleep 0.1
    done
  done
}

# Usage: fpga_nix_license_relay_listening <port>
fpga_nix_license_relay_listening() {
  local address
  # 127.0.0.1:<port> as it appears in /proc/net/tcp; state 0A is LISTEN.
  address="0100007F:$(printf '%04X' "$1")"
  awk -v address="$address" '$2 == address && $4 == "0A" { found = 1 } END { exit !found }' \
    /proc/net/tcp
}

fpga_nix_license_relay_stop() {
  local pid
  if [ -f "${fpga_nix_license_relay_pid_file:-}" ]; then
    while read -r pid; do
      kill "$pid" 2>/dev/null || true
    done <"$fpga_nix_license_relay_pid_file"
    rm -f "$fpga_nix_license_relay_pid_file"
  fi
}
