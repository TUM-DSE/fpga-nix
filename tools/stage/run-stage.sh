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
  sed -n '2,10p' "$0" >&2
  exit 2
fi

tool_roots="$1"
pre_build="$2"
build_commands="$3"
check_commands="$4"
expected_paths="$5"

build_dir="$PWD"
state_dir="$build_dir/.fpga-nix"

# Vendor tools live outside the Nix store. On Linux the sandbox only sees them
# when the host or the consuming flake adds them to extra-sandbox-paths, so
# fail early with a clear message instead of a confusing tool error.
check_tool_roots() {
  local root missing=0

  while IFS= read -r root; do
    [ -n "$root" ] || continue
    if [ ! -d "$root" ]; then
      echo "ERROR: vendor tool root $root is not visible inside the build sandbox." >&2
      missing=1
    fi
  done <"$tool_roots"

  if [ "$missing" = 1 ]; then
    echo "Add it to extra-sandbox-paths in the Nix configuration, or set" \
      "nixConfig.extra-sandbox-paths in the consuming flake (this only takes" \
      "effect for trusted users who accept the flake configuration)." >&2
    exit 1
  fi
}

setup_build_environment() {
  export HOME="${TMPDIR:-/tmp}/fpga-nix-home"
  mkdir -p "$HOME"
  export TERM="${TERM:-xterm-256color}"
}

run_measured_build_commands() {
  local status scratch_bytes time_file

  mkdir -p "$state_dir/logs" "$state_dir/metadata"
  time_file="$state_dir/metadata/gnu-time.txt"

  set +e
  "$FPGA_NIX_TIME" \
    --output="$time_file" \
    --format='wallSeconds=%e\nuserCpuSeconds=%U\nsystemCpuSeconds=%S\nmaxRssKiB=%M' \
    bash -euo pipefail "$build_commands" \
    > >(tee "$state_dir/logs/command.stdout.log") \
    2> >(tee "$state_dir/logs/command.stderr.log" >&2)
  status=$?
  wait
  set -e

  scratch_bytes="$(du -sb "$build_dir" | cut -f1)"
  jq -n \
    --arg kind "$FPGA_NIX_STAGE_KIND" \
    --argjson requestedCores "$FPGA_NIX_STAGE_CORES" \
    --argjson scratchBytes "$scratch_bytes" \
    --argjson exitCode "$status" \
    --rawfile measured "$time_file" \
    '
      ($measured | split("\n") | map(select(test("^[A-Za-z]+=")) | split("=")
        | {(.[0]): .[1]}) | add) as $m
      | {
          schemaVersion: 1,
          kind: $kind,
          measurementScope: "build-commands",
          status: (if $exitCode == 0 then "completed" else "failed" end),
          exitCode: $exitCode,
          wallSeconds: $m.wallSeconds,
          userCpuSeconds: $m.userCpuSeconds,
          systemCpuSeconds: $m.systemCpuSeconds,
          maxRssKiB: ($m.maxRssKiB | tonumber),
          requestedCores: $requestedCores,
          scratchBytesAfterCommand: $scratchBytes
        }
    ' >"$state_dir/metadata/execution.json"

  return "$status"
}

check_expected_paths() {
  local relpath missing=0

  while IFS= read -r relpath; do
    [ -n "$relpath" ] || continue
    if [ ! -e "$build_dir/$relpath" ]; then
      echo "ERROR: missing expected build artifact: $relpath" >&2
      missing=1
    fi
  done <"$expected_paths"

  if [ "$missing" = 1 ]; then
    exit 1
  fi
}

check_tool_roots
setup_build_environment
if [ -s "$pre_build" ]; then
  # Sourced so that exported variables reach the build commands.
  # shellcheck disable=SC1090
  . "$pre_build"
fi
run_measured_build_commands
if [ -s "$check_commands" ]; then
  bash -euo pipefail "$check_commands"
fi
check_expected_paths
