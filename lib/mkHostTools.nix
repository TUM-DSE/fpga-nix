# Vendor-neutral host tools for machines with an FPGA in a PCIe slot.
{
  pkgs,
  # PCI vendor IDs that hot-reset accepts in the reset domain. The default
  # covers Xilinx/AMD. FPGA_NIX_PCI_VENDORS overrides it at run time.
  fpgaPciVendors ? [ "0x10ee" ],
  platforms ? pkgs.lib.platforms.linux,
}:
let
  mkTool =
    {
      name,
      script,
      description,
      runtimeInputs ? [ ],
      substitutions ? { },
    }:
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      # The tools call sudo, which must come from the host.
      inheritPath = true;
      text =
        let
          placeholders = builtins.attrNames substitutions;
          values = map (placeholder: substitutions.${placeholder}) placeholders;
        in
        builtins.readFile ../tools/common.sh
        + "\n"
        + builtins.replaceStrings placeholders values (builtins.readFile script);
      meta = {
        inherit description platforms;
        mainProgram = name;
      };
    };
in
rec {
  hot-reset = mkTool {
    name = "hot-reset";
    script = ../tools/host/hot-reset.sh;
    description = "PCIe secondary-bus hot reset of an FPGA's upstream bridge: hot-reset [bdf]";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.pciutils
    ];
    substitutions."@FPGA_PCI_VENDORS@" = builtins.concatStringsSep " " fpgaPciVendors;
  };

  set-hugepages = mkTool {
    name = "set-hugepages";
    script = ../tools/host/set-hugepages.sh;
    description = "Set vm.nr_hugepages (default 1024): set-hugepages [count]";
    runtimeInputs = [ pkgs.procps ];
  };

  all = [
    hot-reset
    set-hugepages
  ];
}
