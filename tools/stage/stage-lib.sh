# Shared runtime for measured FPGA build stages. Sourced by run-stage.sh and
# by framework runners such as coyote-nix's. Needs bash, coreutils and jq.
# GNU time comes from FPGA_NIX_TIME (or the older COYOTE_NIX_TIME).

# Fail when a vendor tool root is not visible inside the build sandbox.
# On Linux the sandbox only sees such roots when they are listed in
# extra-sandbox-paths, so explain that instead of failing in the tool.
# Usage: fpga_nix_stage_check_tool_roots <root>...
fpga_nix_stage_check_tool_roots() {
  local root missing=0

  for root in "$@"; do
    [ -n "$root" ] || continue
    if [ ! -d "$root" ]; then
      echo "ERROR: vendor tool root $root is not visible inside the build sandbox." >&2
      missing=1
    fi
  done

  if [ "$missing" = 1 ]; then
    echo "Add it to extra-sandbox-paths in the Nix configuration, or set" \
      "nixConfig.extra-sandbox-paths in the consuming flake (this only takes" \
      "effect for trusted users who accept the flake configuration)." >&2
    return 1
  fi
}

# Run a command script under GNU time with strict shell options. Writes
# <state>/logs/command.{stdout,stderr}.log, <state>/metadata/gnu-time.txt and
# <state>/metadata/execution.json, and returns the command's exit status.
# Usage: fpga_nix_stage_run_measured <state-dir> <commands> <kind> <cores> <scratch-dir>
fpga_nix_stage_run_measured() {
  local state_dir="$1" commands="$2" kind="$3" cores="$4" scratch_dir="$5"
  local time_bin status scratch_bytes time_file

  time_bin="${FPGA_NIX_TIME:-${COYOTE_NIX_TIME:-}}"
  if [ -z "$time_bin" ]; then
    echo "ERROR: FPGA_NIX_TIME must point to GNU time" >&2
    return 1
  fi

  mkdir -p "$state_dir/logs" "$state_dir/metadata"
  time_file="$state_dir/metadata/gnu-time.txt"
  : >"$state_dir/logs/command.stdout.log"
  : >"$state_dir/logs/command.stderr.log"

  set +e
  "$time_bin" \
    --output="$time_file" \
    --format='wallSeconds=%e\nuserCpuSeconds=%U\nsystemCpuSeconds=%S\nmaxRssKiB=%M\nexitCode=%x' \
    bash -euo pipefail "$commands" \
    > >(tee "$state_dir/logs/command.stdout.log") \
    2> >(tee "$state_dir/logs/command.stderr.log" >&2)
  status=$?
  wait
  set -e

  scratch_bytes="$(du -sb "$scratch_dir" | cut -f1)"
  # GNU time adds a "Command exited with non-zero status" line on failure,
  # so only key=value lines are read.
  jq -n \
    --arg kind "$kind" \
    --argjson requestedCores "$cores" \
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

# Fail when any path listed in <list-file> (one per line) is missing in <dir>.
# Usage: fpga_nix_stage_check_expected_paths <dir> <list-file>
fpga_nix_stage_check_expected_paths() {
  local dir="$1" list="$2" relpath missing=0

  while IFS= read -r relpath; do
    [ -n "$relpath" ] || continue
    if [ ! -e "$dir/$relpath" ]; then
      echo "ERROR: missing expected build artifact: $dir/$relpath" >&2
      missing=1
    fi
  done <"$list"

  [ "$missing" = 0 ]
}
