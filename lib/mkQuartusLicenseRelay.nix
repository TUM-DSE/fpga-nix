# Check out Quartus floating licenses from inside the build sandbox, through
# Unix sockets that the build host relays to the license server (see
# tools/intel/license-relay.sh).
#
# Returns attributes for mkStagePackage: toolRoots, nativeBuildInputs, env and
# preBuild. mkQuartusStagePackage applies them with its licenseRelay argument.
{
  pkgs,
  # Holds <port>.sock for every port. Must be in extra-sandbox-paths.
  socketDir,
  # lmgrd's port first, then the vendor daemons' ports, such as alterad's.
  ports ? [
    27010
    27011
  ],
}:
let
  inherit (pkgs) lib;

  relayArgs = lib.escapeShellArgs ([ (toString socketDir) ] ++ map toString ports);
in
assert lib.assertMsg (ports != [ ]) "mkQuartusLicenseRelay: ports must not be empty";
{
  # Checked before the build, with an explanation when it is not visible.
  toolRoots = [ socketDir ];
  nativeBuildInputs = [
    pkgs.gawk
    pkgs.socat
  ];
  env.FPGA_NIX_QUARTUS_LICENSE_FILE = "${toString (builtins.head ports)}@localhost";
  preBuild = ''
    . ${../tools/intel/license-relay.sh}
    fpga_nix_license_relay_start ${relayArgs}
  '';
}
