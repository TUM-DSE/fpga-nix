#!/usr/bin/env bash
# Forward 127.0.0.1 ports to fake license daemons on Unix sockets.
# Usage: license-relay.sh <license-relay.sh under test>
set -euo pipefail

relay_lib="$1"
work="$(mktemp -d)"
dir="$work/relay"
mkdir -p "$dir"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Each fake daemon answers every connection with its name.
daemons=()
for entry in 27010:lmgrd 27011:alterad; do
  socat "UNIX-LISTEN:$dir/${entry%%:*}.sock,fork" "SYSTEM:echo ${entry#*:}" &
  daemons+=("$!")
done
trap 'kill "${daemons[@]}" 2>/dev/null || true; rm -rf "$work"' EXIT
for port in 27010 27011; do
  until [ -S "$dir/$port.sock" ]; do sleep 0.1; done
done

# The relay runs in a subshell, which stops it on exit.
(
  # shellcheck disable=SC1090
  . "$relay_lib"
  fpga_nix_license_relay_start "$dir" 27010 27011
  [ "$(socat -u TCP:127.0.0.1:27010 -)" = lmgrd ] || fail "27010 did not reach lmgrd"
  [ "$(socat -u TCP:127.0.0.1:27011 -)" = alterad ] || fail "27011 did not reach alterad"
  # Every connection is forwarded, not just the first.
  [ "$(socat -u TCP:127.0.0.1:27010 -)" = lmgrd ] || fail "second connection to 27010 failed"
  # The stage runner waits for its own jobs with a bare wait; the listeners
  # must not be among them.
  wait
)

# The listeners are gone once the shell that started them has exited.
if socat -u TCP:127.0.0.1:27010 - 2>/dev/null; then
  fail "relay still listens after its shell exited"
fi

# A missing socket fails before anything listens.
if (
  # shellcheck disable=SC1090
  . "$relay_lib"
  fpga_nix_license_relay_start "$dir" 27010 27099
) 2>"$work/err"; then
  fail "missing socket accepted"
fi
grep -qF "$dir/27099.sock does not exist" "$work/err" || fail "unexpected error: $(cat "$work/err")"
grep -qF "extra-sandbox-paths" "$work/err" || fail "error does not mention extra-sandbox-paths"

echo "license relay: ok"
