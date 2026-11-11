#!/usr/bin/env bash
# Run the Xilinx wrappers against a fake installation and a fake xilinx-shell.
# Usage: xilinx-wrappers.sh <wrapper-bin-dir> <fake-xilinx-shell>
set -euo pipefail

bin="$1"
export FPGA_NIX_XILINX_SHELL="$2"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export TMPDIR="$work/tmp"
mkdir -p "$TMPDIR"
unset XDG_RUNTIME_DIR HW_SERVER_LOG HW_SERVER_PORT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Run a wrapper; save stdout, stderr and the exit status.
run() {
  set +e
  "$@" >"$work/out" 2>"$work/err"
  status=$?
  set -e
}

expect_ok() {
  run "$@"
  [ "$status" = 0 ] || fail "$* exited $status: $(cat "$work/err")"
}

expect_fail() {
  local message="$1"
  shift
  run "$@"
  [ "$status" != 0 ] || fail "$* unexpectedly succeeded"
  grep -qF -- "$message" "$work/err" || fail "$* did not report '$message': $(cat "$work/err")"
}

expect_out() {
  grep -qxF -- "$1" "$work/out" || fail "missing '$1' in output: $(cat "$work/out")"
}

# A version is required. Nothing is guessed from the installation.
unset FPGA_NIX_XILINX_VERSION COYOTE_NIX_XILINX_VERSION
expect_fail "FPGA_NIX_XILINX_VERSION is not set" "$bin/vivado" -version

# The <root>/<version>/Vivado layout, with component settings and a license.
export FPGA_NIX_XILINX_VERSION=2025.1
export FPGA_NIX_XILINX_LICENSE_FILE=/licenses/site.lic
export XILINX_VIVADO=/stale/vivado XILINX_HLS=/stale/hls
expect_ok "$bin/vivado" -h -mode batch
expect_out "tool=vivado"
expect_out "args=-help -mode batch"
expect_out "settings=2025.1"
expect_out "hls="
expect_out "license=/licenses/site.lic"
expect_out "user_data=no"
echo "PASS vivado with settings, license and stale variables"

# Companion tools dispatch on their command name.
expect_ok "$bin/xelab" top
expect_out "tool=xelab"
expect_out "args=top"
echo "PASS companion tool"

# The <root>/Vivado/<version> layout through the older variable name.
unset FPGA_NIX_XILINX_VERSION FPGA_NIX_XILINX_LICENSE_FILE
export COYOTE_NIX_XILINX_VERSION=2023.2
expect_ok "$bin/vivado" -version
expect_out "tool=vivado"
expect_out "settings="
expect_out "vivado="
echo "PASS alternative layout and COYOTE_NIX_ fallback"

expect_fail "Vivado 2023.2/bin/xelab not found" "$bin/xelab"
echo "PASS missing tool"

# hw_server gets a log and the configured port unless the caller sets them.
unset COYOTE_NIX_XILINX_VERSION
export FPGA_NIX_XILINX_VERSION=2025.1
expect_ok "$bin/hw_server"
expect_out "args=-L$TMPDIR/hw_server-$(id -u)-3121.log -s tcp::3121"
FPGA_NIX_HW_SERVER_PORT=3122 expect_ok "$bin/hw_server" -d
expect_out "args=-L$TMPDIR/hw_server-$(id -u)-3122.log -s tcp::3122 -d"
expect_ok "$bin/hw_server" -s tcp::4000 -L-
expect_out "args=-s tcp::4000 -L-"
echo "PASS hw_server defaults"

# Without a vitis_hls binary, classic arguments are mapped to vitis-run.
expect_ok "$bin/vitis_hls" -f run.tcl -version
expect_out "tool=vitis-run"
expect_out "args=--mode hls --tcl run.tcl --version"
expect_fail "requires a Tcl file" "$bin/vitis_hls" -f
FPGA_NIX_XILINX_VERSION=2023.2 expect_ok "$bin/vitis_hls" -f run.tcl
expect_out "tool=vitis_hls"
expect_out "args=-f run.tcl"
echo "PASS vitis_hls and vitis-run"

expect_ok "$bin/bootgen" -arch versal
expect_out "tool=bootgen"
expect_ok "$bin/armr5-none-eabi-gcc" --version
expect_out "tool=armr5-none-eabi-gcc"
echo "PASS embedded tools"

# Older environments without gmake get an ephemeral shim outside $HOME.
mkdir -p "$work/make-bin"
ln -s "$(command -v true)" "$work/make-bin/make"
PATH="$work/make-bin:$PATH" expect_ok "$bin/vivado"
expect_out "gmake=$TMPDIR/fpga-nix-gmake-${UID:-0}/bin/gmake"
echo "PASS gmake shim"

FPGA_NIX_XILINX_SHELL=/nonexistent expect_fail "xilinx-shell not found" "$bin/vivado"
echo "PASS missing xilinx-shell"
