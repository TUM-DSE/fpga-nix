# Plain library functions. The flake wraps some of them to supply defaults
# from its own inputs, such as the fpgahog package.
{
  mkHostTools = import ./mkHostTools.nix;
  mkXilinxTools = import ./mkXilinxTools.nix;
  mkStagePackage = import ./mkStagePackage.nix;
  mkDevShell = import ./mkDevShell.nix;
  mkQuartusShell = import ./mkQuartusShell.nix;
  mkIntelTools = import ./mkIntelTools.nix;
  mkQuartusStagePackage = import ./mkQuartusStagePackage.nix;

  # Shell library with the stage runtime, for frameworks with their own runner.
  stageLib = ../tools/stage/stage-lib.sh;
}
