# Wrappers that run Xilinx tools from a site installation inside its
# xilinx-shell, plus a JTAG programming command.
#
# The installation path is site policy and must be passed in. The tool
# version is chosen at run time through FPGA_NIX_XILINX_VERSION, which the
# site's dev shell or stage derivation sets for the selected board.
{
  pkgs,
  xilinxShareRoot,
  platforms ? pkgs.lib.platforms.linux,
}:
let
  inherit (pkgs) lib;

  wrapperLib = pkgs.writeText "fpga-nix-xilinx-wrapper-lib.sh" (
    builtins.readFile ../tools/common.sh
    + "\n"
    +
      builtins.replaceStrings
        [ "@NCURSES6_LIB@" "@XILINX_SHARE_ROOT@" ]
        [ "${pkgs.ncurses6}/lib/libtinfo.so.6" (toString xilinxShareRoot) ]
        (builtins.readFile ../tools/xilinx/wrapper-lib.sh)
  );

  mkWrapper =
    {
      name,
      script,
      description,
      runtimeInputs ? [ ],
    }:
    pkgs.writeShellApplication {
      inherit name;
      # Wrappers re-exec into xilinx-shell, which needs the caller's PATH.
      inheritPath = true;
      # fpga-nix lints its scripts in its own shellcheck check. Consumers
      # only syntax-check them, so a different shellcheck version in their
      # nixpkgs cannot break the build.
      checkPhase = "${pkgs.stdenv.shellDryRun} \"$target\"";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.gawk
      ]
      ++ runtimeInputs;
      text = ''
        # shellcheck source=/dev/null
        source ${wrapperLib}
      ''
      + builtins.readFile script;
      meta = {
        inherit description platforms;
        mainProgram = name;
      };
    };

  # One wrapper script serves several tools; it dispatches on its own name.
  mkMultiWrapper =
    {
      name,
      tools,
      script,
      description,
    }:
    pkgs.symlinkJoin {
      inherit name;
      paths = map (
        tool:
        mkWrapper {
          name = tool;
          inherit script;
          description = "Run ${tool} from the selected Xilinx installation.";
        }
      ) tools;
      meta = {
        inherit description platforms;
        mainProgram = builtins.head tools;
      };
    };
in
rec {
  inherit wrapperLib;

  vivado = mkMultiWrapper {
    name = "vivado";
    tools = [
      "vivado"
      "xsc"
      "xvlog"
      "xvhdl"
      "xelab"
      "xsim"
    ];
    script = ../tools/xilinx/vivado.sh;
    description = "Vivado and its simulation tools from the selected installation.";
  };

  hw_server = mkWrapper {
    name = "hw_server";
    script = ../tools/xilinx/hw_server.sh;
    description = "Run hw_server from the selected Vivado installation.";
  };

  vitis_hls = mkWrapper {
    name = "vitis_hls";
    script = ../tools/xilinx/vitis_hls.sh;
    description = "Run Vitis HLS from the selected installation.";
  };

  embedded = mkMultiWrapper {
    name = "xilinx-embedded-tools";
    tools = [
      "bootgen"
      "xsdb"
    ]
    ++ map (tool: "armr5-none-eabi-${tool}") [
      "addr2line"
      "ar"
      "as"
      "c++filt"
      "gcc"
      "gcc-ar"
      "gcc-nm"
      "gcc-ranlib"
      "ld"
      "nm"
      "objcopy"
      "objdump"
      "ranlib"
      "readelf"
      "size"
      "strings"
      "strip"
    ];
    script = ../tools/xilinx/embedded.sh;
    description = "Bootgen, XSDB and the Arm R5 toolchain from the selected Vitis.";
  };

  program-fpga = pkgs.writeShellApplication {
    name = "program-fpga";
    runtimeInputs = [
      vivado
      hw_server
      pkgs.coreutils
      pkgs.gnused
      pkgs.git
      pkgs.procps
      pkgs.util-linux
    ];
    # vivado and hw_server re-exec into xilinx-shell, which needs PATH.
    inheritPath = true;
    checkPhase = "${pkgs.stdenv.shellDryRun} \"$target\"";
    text = ''
      # shellcheck source=/dev/null
      source ${wrapperLib}
    ''
    + builtins.replaceStrings [ "@PROGRAM_TCL@" ] [ "${../tools/xilinx/program.tcl}" ] (
      builtins.readFile ../tools/xilinx/program-fpga.sh
    );
    meta = {
      description = "Program a Xilinx FPGA image over JTAG with Vivado.";
      mainProgram = "program-fpga";
      inherit platforms;
    };
  };

  all = [
    vivado
    hw_server
    vitis_hls
    embedded
    program-fpga
  ];

  # Dev shell hook that warns when the installation root is not mounted.
  shellHook = ''
    if [ ! -d ${lib.escapeShellArg (toString xilinxShareRoot)} ]; then
      echo "warning: Xilinx installation ${toString xilinxShareRoot} is not available" >&2
    fi
  '';
}
