#!/usr/bin/env bash
# Stands in for every Quartus tool in the fake installation. It dispatches on
# its name and is controlled through FIXTURE_* variables.
set -euo pipefail

tool="$(basename "$0")"

case "$tool" in
  jtagconfig)
    printf '%s\n' "${FIXTURE_CHAIN:-}"
    exit "${FIXTURE_JTAGCONFIG_STATUS:-0}"
    ;;
  quartus_pgm)
    printf '%s\n' "$@" >"$FIXTURE_RECORD"
    exit 0
    ;;
  quartus_sh)
    if [ "${1:-}" = --flow ] && [ "${2:-}" = compile ]; then
      project="$3"
      revision="${5:-$project}"
      [ -f "$project.qpf" ] || exit 2
      # Follow PROJECT_OUTPUT_DIRECTORY like Quartus; default to the root.
      dir="$(awk '$3 == "PROJECT_OUTPUT_DIRECTORY" { value = $4 } END { print value }' \
        "$revision.qsf" | tr -d '"{}')"
      dir="${dir:-.}"
      mkdir -p "$dir"
      echo sof >"$dir/$revision.sof"
      echo report >"$dir/$revision.fit.rpt"
      exit "${FIXTURE_COMPILE_STATUS:-0}"
    fi
    ;;
  quartus_pfg)
    if [ "${1:-}" = -c ]; then
      # Record the options in the output file, the last argument.
      [ -f "${*: -2:1}" ] || exit 2
      printf '%s\n' "${@:2:$#-3}" >"${*: -1}"
      exit 0
    fi
    ;;
  quartus_sta)
    if [ "${1:-}" = -t ]; then
      # Arguments: -t <script> <project> <revision> <output>. The real
      # timing-slack.tcl writes one line per analysis, condition and clock.
      printf '%s' "${FIXTURE_SLACK-setup slow clk 1.25
hold slow clk 0.10
}" >"$5"
      exit 0
    fi
    ;;
esac

echo "tool=$tool"
echo "args=$*"
echo "rootdir=${QUARTUS_ROOTDIR:-}"
echo "qsys=${QSYS_ROOTDIR:-}"
echo "license=${LM_LICENSE_FILE:-}"
