# Run hw_server from the selected Vivado installation. Unless the caller
# passes them, a writable log (-L) and the configured port (-s) are added.

case "${1:-}" in
  -h | --help) set -- -help "${@:2}" ;;
esac

version="$(fpga_nix_xilinx_version)" || exit 1
hw_server_bin="$(fpga_nix_xilinx_tool Vivado /bin/hw_server)" || exit 1

umask 000

port="$(fpga_nix_hw_server_port)"
fallback_log="${TMPDIR:-/tmp}/hw_server-$(id -u)-$port.log"
has_log_file=0
has_server_url=0
extra_args=()
user_args=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -L)
      has_log_file=1
      user_args+=("$1")
      shift
      if [ "$#" -eq 0 ]; then
        echo "ERROR: -L requires a log path" >&2
        exit 1
      fi
      if [ "$1" = "-" ]; then
        user_args+=("$1")
      else
        log="$(fpga_nix_prepare_hw_server_log "$1" "$fallback_log")"
        user_args+=("$log")
      fi
      ;;
    -L*)
      has_log_file=1
      log="${1#-L}"
      if [ "$log" = "-" ]; then
        user_args+=("$1")
      else
        log="$(fpga_nix_prepare_hw_server_log "$log" "$fallback_log")"
        user_args+=("-L$log")
      fi
      ;;
    -s)
      has_server_url=1
      user_args+=("$1")
      shift
      if [ "$#" -eq 0 ]; then
        echo "ERROR: -s requires a server URL" >&2
        exit 1
      fi
      user_args+=("$1")
      ;;
    -s*)
      has_server_url=1
      user_args+=("$1")
      ;;
    *)
      user_args+=("$1")
      ;;
  esac
  shift
done

if [ "$has_log_file" -eq 0 ]; then
  if [ -n "${HW_SERVER_LOG:-}" ]; then
    log="$HW_SERVER_LOG"
  elif [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] &&
    [ -w "$XDG_RUNTIME_DIR" ]; then
    log="$XDG_RUNTIME_DIR/hw_server-$port.log"
  else
    log="$fallback_log"
  fi
  log="$(fpga_nix_prepare_hw_server_log "$log" "$fallback_log")"
  extra_args+=("-L$log")
fi

if [ "$has_server_url" -eq 0 ]; then
  extra_args+=("-s" "tcp::$port")
fi

fpga_nix_xilinx_exec_tool "$version" "$hw_server_bin" "${extra_args[@]}" "${user_args[@]}"
