#!/usr/bin/env bash
# Run the Quartus wrappers and program-fpga against a fake installation.
# Usage: intel-wrappers.sh <tools-bin-dir> <fake-root>
set -euo pipefail

bin="$1"
root="$2"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export FIXTURE_RECORD="$work/record"
export FPGA_NIX_PROGRAM_LOCK_DIR="$work/lock"
unset FPGA_JTAG_TARGET FPGA_BITSTREAM QUARTUS_ROOTDIR LM_LICENSE_FILE

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

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

expect_record() {
  [ "$(paste -sd' ' "$FIXTURE_RECORD")" = "$1" ] ||
    fail "quartus_pgm got '$(paste -sd' ' "$FIXTURE_RECORD")', expected '$1'"
}

# A version is required, and it must be installed.
unset FPGA_NIX_QUARTUS_VERSION
expect_fail "FPGA_NIX_QUARTUS_VERSION is not set" "$bin/quartus_sh" --version
FPGA_NIX_QUARTUS_VERSION=99.9 expect_fail "Quartus 99.9 not found" "$bin/quartus_sh"
echo "PASS version selection"

export FPGA_NIX_QUARTUS_VERSION=24.1
QUARTUS_ROOTDIR=/stale FPGA_NIX_QUARTUS_LICENSE_FILE=/licenses/site.dat \
  expect_ok "$bin/quartus_syn" top -c rev
expect_out "tool=quartus_syn"
expect_out "args=top -c rev"
expect_out "rootdir=$root/24.1/quartus"
expect_out "qsys=$root/24.1/qsys/bin"
expect_out "license=/licenses/site.dat"
expect_ok "$bin/qsys-generate" system.qsys
expect_out "tool=qsys-generate"
echo "PASS tool wrappers"

image="$work/top.sof"
touch "$image"
chain='1) Agilex 7 FPGA I-Series Development Kit [1-14]
  4361C0DD   AGIB027R29A(.|R2|R3)/..
  020D10DD   VTAP10
2) USB-BlasterII [1-3]
  02E660DD   10AX115H1(.|E2|ES)/10AX115H2/..'
export FIXTURE_CHAIN="$chain"

FPGA_PART_HINT=agib027 expect_ok "$bin/program-fpga" "$image"
expect_record "-c Agilex 7 FPGA I-Series Development Kit [1-14] -m jtag -o p;$image@1"
[ ! -e "$work/lock" ] || fail "lock left behind"
echo "PASS program by part"

# Positions count per cable, so the Arria 10 is device 1 on the second cable.
FPGA_PART_HINT=10AX115 expect_ok "$bin/program-fpga" "$image"
expect_record "-c USB-BlasterII [1-3] -m jtag -o p;$image@1"
echo "PASS position per cable"

export FIXTURE_CHAIN="$chain
3) USB-BlasterII [1-4]
  4361C0DD   AGIB027R29A(.|R2|R3)/.."
FPGA_PART_HINT=AGIB027 expect_fail "found 2" "$bin/program-fpga" "$image"
FPGA_PART_HINT=AGIB027 FPGA_JTAG_TARGET=1-4 expect_ok "$bin/program-fpga" "$image"
expect_record "-c USB-BlasterII [1-4] -m jtag -o p;$image@1"
echo "PASS ambiguous parts and cable filter"

# The chain of the Agilex 7 dev kit as jtagconfig reports it on xavier.
export FIXTURE_CHAIN='1) AGI FPGA Development Kit [1-14]
  034BB0DD   AGIB027R29A(.|B|R0|R1|R3)/..
  020D10DD   VTAP10
'
FPGA_PART_HINT=AGIB027 expect_ok "$bin/program-fpga" "$image"
expect_record "-c AGI FPGA Development Kit [1-14] -m jtag -o p;$image@1"
echo "PASS xavier's chain"

FPGA_PART_HINT=XCU280 expect_fail "found 0" "$bin/program-fpga" "$image"
FPGA_PART_HINT=AGIB027 expect_fail "must be a .sof" "$bin/program-fpga" "$work/top.bit"
expect_fail "FPGA_PART_HINT is required" "$bin/program-fpga" "$image"
mkdir "$work/lock"
FPGA_PART_HINT=AGIB027 FPGA_JTAG_TARGET=1-14 expect_fail "Lock: $work/lock" \
  "$bin/program-fpga" "$image"
[ -d "$work/lock" ] || fail "foreign lock was removed"
echo "PASS program-fpga rejections"
