# Run Vivado or one of its companion tools (xsc, xvlog, xvhdl, xelab, xsim)
# from the selected installation. The tool is chosen by the command name.

tool="$(basename "$0")"
case "${1:-}" in
  -h | --help) set -- -help "${@:2}" ;;
esac

version="$(fpga_nix_xilinx_version)" || exit 1
tool_bin="$(fpga_nix_xilinx_tool Vivado "/bin/$tool")" || exit 1
fpga_nix_xilinx_exec_tool "$version" "$tool_bin" "$@"
