# Run Vitis HLS. Newer releases removed the vitis_hls binary in favor of
# "vitis-run --mode hls", so classic arguments are translated when needed.

normalize_args_for_vitis_run() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -version) printf '%s\n' --version ;;
      -help | -h | --help) printf '%s\n' --help ;;
      -f)
        shift
        if [ "$#" -eq 0 ]; then
          echo "ERROR: vitis_hls -f requires a Tcl file argument" >&2
          return 2
        fi
        printf '%s\n' --tcl "$1"
        ;;
      *.tcl) printf '%s\n' --tcl "$1" ;;
      *) printf '%s\n' "$1" ;;
    esac
    shift
  done
}

version="$(fpga_nix_xilinx_version)" || exit 1

if hls_bin="$(fpga_nix_xilinx_find -x Vitis_HLS "$version" /bin/vitis_hls)"; then
  fpga_nix_xilinx_exec_tool "$version" "$hls_bin" "$@"
fi

if ! run_bin="$(fpga_nix_xilinx_find -x Vitis "$version" /bin/vitis-run)"; then
  echo "ERROR: neither vitis_hls nor vitis-run found for Xilinx $version under" \
    "$(fpga_nix_xilinx_share_root)" >&2
  exit 1
fi

normalized="$(normalize_args_for_vitis_run "$@")" || exit "$?"
mapped_args=()
if [ -n "$normalized" ]; then
  mapfile -t mapped_args <<<"$normalized"
fi

q_run_bin="$(fpga_nix_shell_quote "$run_bin")"
fpga_nix_xilinx_exec "$version" "exec $q_run_bin --mode hls \"\$@\"" "${mapped_args[@]}"
