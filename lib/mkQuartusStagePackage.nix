# Compile a Quartus Prime Pro project to a .sof with mkStagePackage.
#
# The source must contain the project (<project>.qpf and <revision>.qsf). The
# default flow is a full compile; the stage fails on negative slack, or when
# no clock is constrained, unless checkTiming is false. The worst slack per
# clock is installed as output_files/<revision>.slack.txt.
{
  pkgs,
  # The result of mkIntelTools.
  intelTools,
  quartusShareRoot,
  quartusVersion,
  pname,
  version ? "0.1.0",
  src,
  project,
  revision ? project,
  # Where Quartus writes the .sof and reports. Added to <revision>.qsf when the
  # project does not set PROJECT_OUTPUT_DIRECTORY; a different value fails.
  outputDirectory ? "output_files",
  # Shell commands that produce <outputDirectory>/<revision>.sof.
  buildCommands ? [ "quartus_sh --flow compile ${project} -c ${revision}" ],
  checkTiming ? true,
  # Also write a flash image (<revision>.jic) for the board's configuration
  # flash, as { device, flashLoader, mode ? "ASX4" }: the flash part (for
  # example MT25QU02G), the FPGA part that acts as flash loader and the
  # configuration mode. The mode must match the project's
  # CONFIGURATION_SCHEME, or quartus_pfg rejects the .sof.
  flashImage ? null,
  licenseFile ? null,
  extraExpectedPaths ? [ ],
  cores ? 8,
  env ? { },
  extraAttrs ? { },
}:
let
  inherit (pkgs) lib;

  slackFile = "${outputDirectory}/${revision}.slack.txt";

  # Query the Timing Analyzer for the worst slack per analysis, clock and
  # operating condition, then reject negative slack or a design without clocks.
  timingCheck = ''
    quartus_sta -t ${../tools/intel/timing-slack.tcl} ${project} ${revision} "$PWD/${slackFile}"
    if [ ! -s ${slackFile} ]; then
      echo "ERROR: no constrained clocks found; add an SDC file or set checkTiming = false" >&2
      exit 1
    fi
    if awk '$NF + 0 < 0 { bad = 1 } END { exit !bad }' ${slackFile}; then
      echo "ERROR: timing constraints are not met (analysis, condition, clock, slack):" >&2
      awk '$NF + 0 < 0' ${slackFile} >&2
      exit 1
    fi
  '';

  # Without PROJECT_OUTPUT_DIRECTORY, Quartus writes into the project root.
  outputDirectoryCheck = ''
    qsf=${lib.escapeShellArg "${revision}.qsf"}
    if [ ! -f "$qsf" ]; then
      echo "ERROR: $qsf not found in the project source" >&2
      exit 1
    fi
    configured="$(awk '$1 == "set_global_assignment" && $3 == "PROJECT_OUTPUT_DIRECTORY" \
      { value = $4 } END { print value }' "$qsf" | tr -d '"{}')"
    if [ -z "$configured" ]; then
      printf '\nset_global_assignment -name PROJECT_OUTPUT_DIRECTORY %s\n' \
        ${lib.escapeShellArg outputDirectory} >> "$qsf"
    elif [ "$configured" != ${lib.escapeShellArg outputDirectory} ]; then
      echo "ERROR: $qsf sets PROJECT_OUTPUT_DIRECTORY to $configured; pass" \
        "outputDirectory = \"$configured\" to the stage" >&2
      exit 1
    fi
  '';

  flashImageCommand =
    let
      flash = {
        mode = "ASX4";
      }
      // flashImage;
    in
    lib.escapeShellArgs [
      "quartus_pfg"
      "-c"
      "-o"
      "device=${flash.device}"
      "-o"
      "flash_loader=${flash.flashLoader}"
      "-o"
      "mode=${flash.mode}"
      "${outputDirectory}/${revision}.sof"
      "${outputDirectory}/${revision}.jic"
    ];
in
import ./mkStagePackage.nix {
  inherit
    pkgs
    pname
    version
    src
    cores
    ;
  buildCommands = buildCommands ++ lib.optional (flashImage != null) flashImageCommand;
  tools = intelTools.all;
  nativeBuildInputs = [ pkgs.gawk ];
  toolRoots = [ quartusShareRoot ];
  env = {
    FPGA_NIX_QUARTUS_VERSION = quartusVersion;
  }
  // lib.optionalAttrs (licenseFile != null) {
    FPGA_NIX_QUARTUS_LICENSE_FILE = toString licenseFile;
  }
  // env;
  executionKind = "quartus-stage-execution";
  preBuild = outputDirectoryCheck;
  expectedPaths = [
    "${outputDirectory}/${revision}.sof"
  ]
  ++ lib.optional (flashImage != null) "${outputDirectory}/${revision}.jic"
  ++ extraExpectedPaths;
  installPaths = [ outputDirectory ];
  checkCommands = lib.optional checkTiming timingCheck;
  description = "Quartus compile of ${project} (${revision})";
  platforms = [ "x86_64-linux" ];
  inherit extraAttrs;
}
