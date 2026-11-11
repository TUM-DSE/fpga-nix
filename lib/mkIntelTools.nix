# Wrappers that run Intel Quartus Prime Pro tools from a site installation
# inside a Quartus FHS shell, plus a JTAG programming command.
#
# The installation root is site policy and must be passed in. It contains one
# directory per version, for example /share/intel-fpga/tools/24.1. The version
# is chosen at run time through FPGA_NIX_QUARTUS_VERSION.
{
  pkgs,
  quartusShareRoot,
  # The FHS environment Quartus runs in. Defaults to fpga-nix's own.
  quartusShell ? import ./mkQuartusShell.nix { inherit pkgs; },
  platforms ? [ "x86_64-linux" ],
}:
let
  wrapperLib = pkgs.writeText "fpga-nix-intel-wrapper-lib.sh" (
    builtins.readFile ../tools/common.sh
    + "\n"
    +
      builtins.replaceStrings
        [ "@QUARTUS_SHARE_ROOT@" "@QUARTUS_SHELL@" ]
        [ (toString quartusShareRoot) "${quartusShell}/bin/${quartusShell.name}" ]
        (builtins.readFile ../tools/intel/wrapper-lib.sh)
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
      inheritPath = true;
      runtimeInputs = [ pkgs.coreutils ] ++ runtimeInputs;
      # Linted by this flake's shellcheck check; see mkXilinxTools.nix.
      checkPhase = "${pkgs.stdenv.shellDryRun} \"$target\"";
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

  quartusTools = [
    "quartus_sh"
    "quartus_syn"
    "quartus_fit"
    "quartus_sta"
    "quartus_asm"
    "quartus_pgm"
    "quartus_cpf"
    "quartus_pfg"
    "quartus_eda"
    "quartus_ipgenerate"
    "quartus_pow"
    "jtagconfig"
    "jtagd"
    "qsys-generate"
    "qsys-script"
  ];
in
rec {
  inherit wrapperLib quartusShell;

  quartus = pkgs.symlinkJoin {
    name = "quartus";
    paths = map (
      tool:
      mkWrapper {
        name = tool;
        script = ../tools/intel/quartus.sh;
        description = "Run ${tool} from the selected Quartus installation.";
      }
    ) quartusTools;
    meta = {
      description = "Quartus Prime Pro command-line tools from the selected installation.";
      mainProgram = "quartus_sh";
      inherit platforms;
    };
  };

  program-fpga = pkgs.writeShellApplication {
    name = "program-fpga";
    runtimeInputs = [
      quartus
      pkgs.coreutils
      pkgs.gnused
    ];
    inheritPath = true;
    checkPhase = "${pkgs.stdenv.shellDryRun} \"$target\"";
    text = builtins.concatStringsSep "\n" [
      (builtins.readFile ../tools/common.sh)
      (builtins.readFile ../tools/intel/program-fpga.sh)
    ];
    meta = {
      description = "Program an Intel FPGA image over JTAG with quartus_pgm.";
      mainProgram = "program-fpga";
      inherit platforms;
    };
  };

  all = [
    quartus
    program-fpga
  ];
}
