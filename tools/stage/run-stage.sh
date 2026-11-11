#!/usr/bin/env bash
# Run one measured FPGA build stage inside a Nix derivation.
#
# Usage: run-stage.sh <tool-roots> <pre-build> <build-commands> <check-commands>
#                     <expected-paths>
# Every argument is a file. Tool roots and expected paths hold one entry per
# line. The other files are shell scripts and may be empty.
#
# Environment: FPGA_NIX_TIME (GNU time), FPGA_NIX_STAGE_CORES and
# FPGA_NIX_STAGE_KIND. Logs and metadata go to .fpga-nix/ in the current
# directory, which is the stage's build directory.
set -euo pipefail

if [ "$#" -ne 5 ]; then
  sed -n '2,11p' "$0" >&2
  exit 2
fi

# shellcheck source=tools/stage/stage-lib.sh
source "$(dirname "$0")/stage-lib.sh"

tool_roots="$1"
pre_build="$2"
build_commands="$3"
check_commands="$4"
expected_paths="$5"

build_dir="$PWD"
state_dir="$build_dir/.fpga-nix"

mapfile -t roots <"$tool_roots"
fpga_nix_stage_check_tool_roots "${roots[@]}"

export HOME="${TMPDIR:-/tmp}/fpga-nix-home"
mkdir -p "$HOME"
export TERM="${TERM:-xterm-256color}"

if [ -s "$pre_build" ]; then
  # Sourced so that exported variables reach the build commands.
  # shellcheck disable=SC1090
  . "$pre_build"
fi
fpga_nix_stage_run_measured "$state_dir" "$build_commands" \
  "$FPGA_NIX_STAGE_KIND" "$FPGA_NIX_STAGE_CORES" "$build_dir"
if [ -s "$check_commands" ]; then
  bash -euo pipefail "$check_commands"
fi
fpga_nix_stage_check_expected_paths "$build_dir" "$expected_paths"
