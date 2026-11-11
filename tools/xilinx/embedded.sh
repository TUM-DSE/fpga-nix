# Run an embedded tool (Bootgen, XSDB, Arm R5 toolchain) from the selected
# Vitis installation. The tool is chosen by the command name.

tool="$(basename "$0")"
case "$tool" in
  armr5-none-eabi-*) relpath="/gnu/armr5/lin/gcc-arm-none-eabi/bin/$tool" ;;
  bootgen | xsdb) relpath="/bin/$tool" ;;
  *)
    echo "ERROR: unsupported embedded tool wrapper: $tool" >&2
    exit 1
    ;;
esac

version="$(fpga_nix_xilinx_version)" || exit 1
tool_bin="$(fpga_nix_xilinx_tool Vitis "$relpath")" || exit 1
fpga_nix_xilinx_exec_tool "$version" "$tool_bin" "$@"
