# Device-free checks. Vendor tools are replaced by small fixtures, so the
# checks run on any Linux builder without a Xilinx installation or an FPGA.
{
  pkgs,
  fpgaNixLib,
  src,
}:
let
  inherit (pkgs) lib;

  # Prints what a wrapper passed through, one key=value pair per line.
  fixtureTool = pkgs.writeShellScript "fixture-tool" ''
    echo "tool=$(basename "$0")"
    echo "args=$*"
    echo "settings=''${FIXTURE_SETTINGS:-}"
    echo "vivado=''${XILINX_VIVADO:-}"
    echo "hls=''${XILINX_HLS:-}"
    echo "license=''${XILINXD_LICENSE_FILE:-}"
    echo "user_data=''${XILINX_LOCAL_USER_DATA:-}"
    echo "gmake=$(command -v gmake || true)"
  '';

  # A fake installation with both supported layouts:
  # <root>/<version>/<component> and <root>/<component>/<version>.
  xilinxFixture = pkgs.runCommand "fpga-nix-xilinx-fixture" { } ''
    tool() {
      mkdir -p "$(dirname "$1")"
      cp ${fixtureTool} "$1"
    }
    tool "$out/2025.1/Vivado/bin/vivado"
    tool "$out/2025.1/Vivado/bin/xelab"
    tool "$out/2025.1/Vivado/bin/hw_server"
    tool "$out/2025.1/Vitis/bin/vitis-run"
    tool "$out/2025.1/Vitis/bin/bootgen"
    tool "$out/2025.1/Vitis/gnu/armr5/lin/gcc-arm-none-eabi/bin/armr5-none-eabi-gcc"
    tool "$out/Vivado/2023.2/bin/vivado"
    tool "$out/Vitis_HLS/2023.2/bin/vitis_hls"
    echo "export FIXTURE_SETTINGS=2025.1 XILINX_VIVADO=$out/2025.1/Vivado" \
      > "$out/2025.1/Vivado/.settings64-Vivado.sh"
  '';

  # Stands in for the site's xilinx-shell: runs the command it is given.
  fakeXilinxShell = pkgs.writeShellScript "fake-xilinx-shell" ''
    test "$1" = -c
    command="$2"
    shift 2
    test "$1" = --
    shift
    exec ${pkgs.bash}/bin/bash -c "$command" -- "$@"
  '';

  xilinxTools = fpgaNixLib.mkXilinxTools {
    inherit pkgs;
    xilinxShareRoot = xilinxFixture;
  };

  hostTools = fpgaNixLib.mkHostTools { inherit pkgs; };

  allTools = pkgs.symlinkJoin {
    name = "fpga-nix-all-tools";
    paths = xilinxTools.all ++ hostTools.all;
  };

  # Raw scripts for tests that replace commands such as sudo or sleep through
  # PATH. The packaged tools put their own runtime inputs first in PATH.
  hotResetScript = pkgs.writeText "hot-reset-under-test.sh" (
    "set -euo pipefail\n"
    + builtins.readFile ../tools/common.sh
    + builtins.replaceStrings [ "@FPGA_PCI_VENDORS@" ] [ "0x10ee" ] (
      builtins.readFile ../tools/host/hot-reset.sh
    )
  );

  programScript = pkgs.runCommand "program-fpga-under-test.sh" { } ''
    {
      cat ${xilinxTools.wrapperLib}
      sed "s|@PROGRAM_TCL@|${../tools/xilinx/program.tcl}|" ${../tools/xilinx/program-fpga.sh}
    } > "$out"
  '';

  stageSource = pkgs.runCommand "fpga-nix-stage-source" { } ''
    mkdir -p "$out"
    echo input > "$out/input.txt"
  '';

  mkStage =
    args:
    fpgaNixLib.mkStagePackage (
      {
        inherit pkgs;
        pname = "fpga-nix-stage-fixture";
        src = stageSource;
        toolRoots = [ xilinxFixture ];
        buildCommands = [
          "mkdir -p out"
          "echo built > out/result.txt"
        ];
        expectedPaths = [ "out/result.txt" ];
      }
      // args
    );

  stage = mkStage {
    env.FIXTURE_VALUE = 42;
    preBuild = "export FROM_PRE_BUILD=yes";
    buildCommands = [
      "mkdir -p out"
      ''test "$FROM_PRE_BUILD" = yes''
      ''echo "$FIXTURE_VALUE" > out/result.txt''
      "echo to-stdout"
      "echo to-stderr >&2"
    ];
    checkCommands = [ "grep -qx 42 out/result.txt" ];
    cores = 4;
  };

  # A fake Quartus installation whose tools are all intel-fixture-tool.sh.
  intelFixture = pkgs.runCommand "fpga-nix-intel-fixture" { } ''
    tool() {
      mkdir -p "$(dirname "$1")"
      install -m755 ${./intel-fixture-tool.sh} "$1"
    }
    for name in quartus_sh quartus_syn quartus_sta quartus_pgm quartus_pfg jtagconfig; do
      tool "$out/24.1/quartus/bin/$name"
    done
    tool "$out/24.1/qsys/bin/qsys-generate"
    patchShebangs "$out"
  '';

  fakeQuartusShell = pkgs.writeShellScriptBin "quartus-shell" ''
    test "$1" = -c
    command="$2"
    shift 2
    test "$1" = --
    shift
    exec ${pkgs.bash}/bin/bash -c "$command" -- "$@"
  '';

  intelTools = fpgaNixLib.mkIntelTools {
    inherit pkgs;
    quartusShareRoot = intelFixture;
    quartusShell = fakeQuartusShell;
  };

  quartusSource =
    qsfExtra:
    pkgs.runCommand "fpga-nix-quartus-source" { } ''
      mkdir -p "$out"
      echo 'PROJECT_REVISION = "counter"' > "$out/counter.qpf"
      {
        echo 'set_global_assignment -name FAMILY "Agilex 7"'
        echo 'set_global_assignment -name TOP_LEVEL_ENTITY top'
        echo ${lib.escapeShellArg qsfExtra}
      } > "$out/counter.qsf"
    '';

  mkQuartusStage =
    args:
    fpgaNixLib.mkQuartusStagePackage (
      {
        inherit pkgs intelTools;
        quartusShareRoot = intelFixture;
        quartusVersion = "24.1";
        pname = "fpga-nix-quartus-fixture";
        src = quartusSource "";
        project = "counter";
      }
      // args
    );

  quartusStage = mkQuartusStage { };

  expectQuartusFailure =
    name: message: args:
    let
      failure = pkgs.testers.testBuildFailure (mkQuartusStage args);
    in
    pkgs.runCommand "fpga-nix-quartus-${name}" { } ''
      grep -qF ${lib.escapeShellArg message} ${failure}/testBuildFailure.log
      touch "$out"
    '';

  # Each failing stage must fail with the given message in its build log.
  expectStageFailure =
    name: message: args:
    let
      failure = pkgs.testers.testBuildFailure (mkStage args);
    in
    pkgs.runCommand "fpga-nix-stage-${name}" { } ''
      grep -qF ${lib.escapeShellArg message} ${failure}/testBuildFailure.log
      touch "$out"
    '';
in
{
  tools = allTools;

  xilinx-wrappers = pkgs.runCommand "fpga-nix-xilinx-wrappers" { } ''
    bash ${./xilinx-wrappers.sh} ${allTools}/bin ${fakeXilinxShell}
    touch "$out"
  '';

  hot-reset = pkgs.runCommand "fpga-nix-hot-reset" { } ''
    bash ${./hot-reset.sh} ${hotResetScript}
    touch "$out"
  '';

  program-fpga =
    pkgs.runCommand "fpga-nix-program-fpga"
      {
        nativeBuildInputs = [
          pkgs.procps
          pkgs.python3
          pkgs.util-linux
        ];
      }
      ''
        python3 ${./program-fpga.py} ${programScript}
        touch "$out"
      '';

  stage-package = pkgs.runCommand "fpga-nix-stage-package" { nativeBuildInputs = [ pkgs.jq ]; } ''
    test "$(cat ${stage}/out/result.txt)" = 42
    grep -qx to-stdout ${stage}/logs/command.stdout.log
    grep -qx to-stderr ${stage}/logs/command.stderr.log
    jq -e '
      .kind == "fpga-stage-execution" and .status == "completed"
      and .exitCode == 0 and .requestedCores == 4
      and (.maxRssKiB | type) == "number"
    ' ${stage}/metadata/execution.json
    touch "$out"
  '';

  stage-missing-tool-root =
    expectStageFailure "missing-tool-root" "not visible inside the build sandbox"
      {
        toolRoots = [ "/nonexistent/xilinx" ];
      };

  stage-missing-artifact = expectStageFailure "missing-artifact" "missing expected build artifact" {
    expectedPaths = [ "out/missing.bit" ];
  };

  stage-failed-check = expectStageFailure "failed-check" "timing not met" {
    checkCommands = [ "echo 'timing not met' >&2; exit 1" ];
  };

  stage-failed-command = expectStageFailure "failed-command" "boom" {
    buildCommands = [ "echo boom >&2; exit 3" ];
  };

  dev-shell = fpgaNixLib.mkDevShell {
    inherit pkgs;
    tools = xilinxTools.all ++ hostTools.all;
    env.FPGA_NIX_XILINX_VERSION = "2025.1";
  };

  shellcheck = pkgs.runCommand "fpga-nix-shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
    cd ${src}
    shellcheck --external-sources tools/stage/run-stage.sh tests/*.sh
    shellcheck --shell=bash --exclude=SC2148 tools/stage/stage-lib.sh
    # Tool scripts are fragments; check them as bash with their libraries.
    for script in tools/host/*.sh tools/xilinx/*.sh tools/intel/*.sh; do
      shellcheck --shell=bash --exclude=SC2148 tools/common.sh "$script"
    done
    touch "$out"
  '';

  # Formatting and the 100-character line limit for every tracked file.
  style = pkgs.runCommand "fpga-nix-style" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
    cd ${src}
    find . -name '*.nix' -exec nixfmt --check {} +
    long_lines="$(find . -type f ! -name flake.lock -exec awk \
      'length > 100 { print FILENAME ":" FNR ": " length " characters" }' {} +)"
    if [ -n "$long_lines" ]; then
      echo "Lines longer than 100 characters:" >&2
      echo "$long_lines" >&2
      exit 1
    fi
    touch "$out"
  '';
}
// lib.optionalAttrs pkgs.stdenv.hostPlatform.isx86_64 {
  # Quartus and its shell only exist for x86_64-linux.
  intel-wrappers = pkgs.runCommand "fpga-nix-intel-wrappers" { } ''
    bash ${./intel-wrappers.sh} ${
      pkgs.symlinkJoin {
        name = "fpga-nix-intel-tools";
        paths = intelTools.all;
      }
    }/bin ${intelFixture}
    touch "$out"
  '';

  quartus-stage = pkgs.runCommand "fpga-nix-quartus-stage" { nativeBuildInputs = [ pkgs.jq ]; } ''
    test -f ${quartusStage}/output_files/counter.sof
    test -f ${quartusStage}/output_files/counter.fit.rpt
    grep -qx 'setup slow clk 1.25' ${quartusStage}/output_files/counter.slack.txt
    jq -e '.kind == "quartus-stage-execution" and .status == "completed"' \
      ${quartusStage}/metadata/execution.json
    touch "$out"
  '';

  quartus-negative-slack = expectQuartusFailure "negative-slack" "timing constraints are not met" {
    env.FIXTURE_SLACK = "setup slow clk -0.2\n";
  };

  quartus-no-clocks = expectQuartusFailure "no-clocks" "no constrained clocks found" {
    env.FIXTURE_SLACK = "";
  };

  quartus-output-directory = expectQuartusFailure "output-directory" "pass outputDirectory" {
    src = quartusSource "set_global_assignment -name PROJECT_OUTPUT_DIRECTORY build";
  };

  quartus-unchecked-timing = mkQuartusStage {
    env.FIXTURE_SLACK = "";
    checkTiming = false;
  };

  quartus-flash-image =
    let
      stage = mkQuartusStage {
        flashImage = {
          device = "MT25QU02G";
          flashLoader = "AGIB027R29A1E2VR3";
        };
      };
    in
    pkgs.runCommand "fpga-nix-quartus-flash-image" { } ''
      test -f ${stage}/output_files/counter.sof
      diff - ${stage}/output_files/counter.jic <<'EOF'
      -o
      device=MT25QU02G
      -o
      flash_loader=AGIB027R29A1E2VR3
      -o
      mode=ASX4
      EOF
      touch "$out"
    '';

  quartus-shell = fpgaNixLib.mkQuartusShell { inherit pkgs; };
}
