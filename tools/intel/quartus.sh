# Run a Quartus tool (quartus_sh, quartus_syn, quartus_pgm, jtagconfig,
# qsys-generate, ...) from the selected installation. The tool is chosen by
# the command name.

tool="$(basename "$0")"
tool_bin="$(fpga_nix_quartus_tool "$tool")" || exit 1
fpga_nix_quartus_exec "exec $(fpga_nix_shell_quote "$tool_bin") \"\$@\"" "$@"
