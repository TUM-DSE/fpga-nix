# One measured FPGA build stage: run caller-provided commands with vendor
# tools, check the expected artifacts and install them with logs and metadata.
#
# The builder knows nothing about a particular project layout or flow. Coyote,
# for example, adds its CMake configuration and timing checks on top of it.
{
  pkgs,
  pname,
  version ? "0.1.0",
  src,
  # Shell commands that produce the stage's artifacts, run from the source root.
  buildCommands,
  # Paths, relative to the source root, that must exist after the build.
  expectedPaths ? [ ],
  # Paths that are copied to $out. Defaults to the expected paths.
  installPaths ? expectedPaths,
  # Shell commands run after the build, for example to reject failed timing.
  checkCommands ? [ ],
  # Shell code sourced before the measured commands; exports reach them.
  preBuild ? "",
  # Vendor installation roots outside the store that must be visible in the
  # build sandbox, for example the Xilinx share root.
  toolRoots ? [ ],
  # Tool wrappers, such as the vivado package from mkXilinxTools.
  tools ? [ ],
  nativeBuildInputs ? [ ],
  # Environment variables for the build, for example the Xilinx version.
  env ? { },
  cores ? 8,
  executionKind ? "fpga-stage-execution",
  extraInstall ? "",
  description ? "FPGA build stage ${pname}",
  platforms ? pkgs.lib.platforms.linux,
  extraAttrs ? { },
}:
let
  inherit (pkgs) lib;

  lines = name: values: pkgs.writeText name (lib.concatMapStrings (value: value + "\n") values);
  script = name: commands: pkgs.writeText name (lib.concatStringsSep "\n" commands);

  stringEnv = lib.mapAttrs (_: toString) env;
in
pkgs.stdenvNoCC.mkDerivation (
  stringEnv
  // {
    inherit pname version src;

    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.jq
      pkgs.time
    ]
    ++ tools
    ++ nativeBuildInputs;

    FPGA_NIX_TIME = "${pkgs.time}/bin/time";
    FPGA_NIX_STAGE_CORES = toString cores;
    FPGA_NIX_STAGE_KIND = executionKind;

    dontConfigure = true;
    dontFixup = true;

    buildPhase = ''
      runHook preBuild
      bash ${../tools/stage}/run-stage.sh \
        ${lines "tool-roots" (map toString toolRoots)} \
        ${pkgs.writeText "pre-build.sh" preBuild} \
        ${script "build-commands.sh" buildCommands} \
        ${script "check-commands.sh" checkCommands} \
        ${lines "expected-paths" expectedPaths}
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/logs" "$out/metadata"
      cp -r .fpga-nix/logs/. "$out/logs/"
      cp -r .fpga-nix/metadata/. "$out/metadata/"
      while IFS= read -r path; do
        [ -n "$path" ] || continue
        mkdir -p "$out/$(dirname "$path")"
        cp -r "$path" "$out/$path"
      done < ${lines "install-paths" installPaths}
      ${extraInstall}
      runHook postInstall
    '';

    meta = {
      inherit description platforms;
    };
  }
  // extraAttrs
)
