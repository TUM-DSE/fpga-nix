# A development shell for FPGA work: common build utilities, the given tool
# sets, optional fpgahog and environment variables for the selected board.
{
  pkgs,
  # Tool packages, for example (mkXilinxTools { ... }).all and mkHostTools.
  tools ? [ ],
  packages ? [ ],
  # Exported when the shell starts, so nested shells can override them.
  env ? { },
  fpgahogPackage ? null,
  shellHook ? "",
}:
let
  inherit (pkgs) lib;

  basePackages = [
    pkgs.bash
    pkgs.coreutils
    pkgs.findutils
    pkgs.gawk
    pkgs.git
    pkgs.gnugrep
    pkgs.gnumake
    pkgs.gnused
    pkgs.which
  ]
  ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    pkgs.kmod
    pkgs.pciutils
    pkgs.procps
  ];

  exports = lib.concatStrings (
    lib.mapAttrsToList (name: value: ''
      export ${name}=${lib.escapeShellArg (toString value)}
    '') env
  );
in
pkgs.mkShell {
  packages =
    basePackages ++ tools ++ packages ++ lib.optional (fpgahogPackage != null) fpgahogPackage;
  shellHook = exports + shellHook;
}
