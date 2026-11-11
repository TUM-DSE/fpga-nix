# fpga-nix

Vendor-neutral Nix tooling for FPGA development. It is the base layer under
[coyote-nix](https://github.com/TUM-DSE/coyote-nix) and works without Coyote.

A project flake usually combines three layers:

1. fpga-nix for tool wrappers, host tools, build stages and dev shells,
2. a site flake such as doctor-cluster-xilinx for installation paths, tool
   versions, licenses and the FPGA inventory,
3. the project's own sources and build graph, optionally through a framework
   layer like coyote-nix.

fpga-nix contains no site policy. Installation paths, tool versions, PCI
addresses and JTAG targets are passed in by the site flake.

## Status

The Xilinx backend is ported from coyote-nix. The Intel backend runs Quartus
Prime Pro and compiles, checks timing and programs regular Quartus projects.

## Library

```nix
fpga-nix.lib.mkXilinxTools
fpga-nix.lib.mkHostTools
fpga-nix.lib.mkStagePackage
fpga-nix.lib.mkDevShell
fpga-nix.lib.mkQuartusShell
fpga-nix.lib.mkIntelTools
fpga-nix.lib.mkQuartusStagePackage
```

### mkXilinxTools

```nix
xilinx = fpga-nix.lib.mkXilinxTools {
  inherit pkgs;
  xilinxShareRoot = "/share/xilinx";
};
```

Returns wrappers that run the tools from the installation inside the site's
`xilinx-shell`:

- `vivado`, including `xsc`, `xvlog`, `xvhdl`, `xelab` and `xsim`
- `hw_server`, with a writable log and the configured port by default
- `vitis_hls`, which falls back to `vitis-run --mode hls` on newer releases
- `embedded`: `bootgen`, `xsdb` and the Arm R5 toolchain from Vitis
- `program-fpga`, which programs a `.bit` or `.pdi` file over JTAG
- `all`, a list of the packages above

The wrappers support both `<root>/<version>/Vivado` and
`<root>/Vivado/<version>` layouts. They clear `XILINX_*` variables from other
versions before sourcing the selected version's settings, and never pick a
version on their own. `FPGA_NIX_XILINX_VERSION` must be set.

`program-fpga` starts its own `hw_server` in a separate session and stops
only that session afterwards. It refuses to run when another `hw_server`
already uses the port, and takes a lock so two invocations don't interfere.
It needs exactly one device whose part contains `FPGA_PART_HINT`.

### mkHostTools

```nix
host = fpga-nix.lib.mkHostTools {
  inherit pkgs;
  fpgaPciVendors = [ "0x10ee" ]; # the default
};
```

- `hot-reset [bdf]` resets the FPGA's upstream PCIe bridge and rediscovers
  the endpoint. It only acts on a directly attached slot where every function
  in the reset domain is unbound and belongs to one of `fpgaPciVendors`.
- `set-hugepages [count]` sets `vm.nr_hugepages`.

### mkStagePackage

```nix
fpga-nix.lib.mkStagePackage {
  inherit pkgs;
  pname = "my-design-bitstream";
  src = ./hw;
  tools = [ xilinx.vivado ];
  toolRoots = [ "/share/xilinx" ];
  env.FPGA_NIX_XILINX_VERSION = "2025.1";
  buildCommands = [ "vivado -mode batch -source build.tcl" ];
  expectedPaths = [ "out/top.pdi" ];
  checkCommands = [
    "if grep -q 'Timing constraints are not met' vivado.log; then exit 1; fi"
  ];
}
```

The stage runs the commands from the source root and records wall time, CPU
time, peak memory and scratch size in `metadata/execution.json`. Logs go to
`logs/`. The expected paths are checked and copied to the output.

### mkDevShell

```nix
fpga-nix.lib.mkDevShell {
  inherit pkgs;
  tools = xilinx.all ++ host.all;
  env.FPGA_NIX_XILINX_VERSION = "2025.1";
  shellHook = site.hostFpgaEnvShellFragment;
}
```

Adds common build utilities and, through the flake, the pinned
[fpgahog](https://github.com/taugoust/fpgahog) for FPGA reservations.

### mkIntelTools

```nix
intel = fpga-nix.lib.mkIntelTools {
  inherit pkgs;
  quartusShareRoot = "/share/intel-fpga/tools"; # one directory per version
};
```

Returns wrappers that run Quartus Prime Pro from the installation inside an
FHS environment built by `mkQuartusShell`, so no host-provided shell is
needed:

- `quartus`: `quartus_sh`, `quartus_syn`, `quartus_fit`, `quartus_sta`,
  `quartus_asm`, `quartus_pgm`, `quartus_cpf`, `quartus_eda`,
  `quartus_ipgenerate`, `quartus_pow`, `jtagconfig`, `jtagd`,
  `qsys-generate` and `qsys-script`
- `program-fpga`, which programs a `.sof` over JTAG with `quartus_pgm`
- `all`, a list of the packages above

As for Xilinx, `FPGA_NIX_QUARTUS_VERSION` must be set and selects the
installation. `FPGA_NIX_QUARTUS_LICENSE_FILE` sets `LM_LICENSE_FILE`.

`program-fpga` takes the same inputs as the Xilinx one. It reads the JTAG
chains from `jtagconfig`, needs exactly one device whose name contains
`FPGA_PART_HINT` (for example `AGIB027`) on the cables matching the optional
`FPGA_JTAG_TARGET`, and takes a lock per cable. A dev shell should include one
vendor's tool set, since both provide `program-fpga`.

For FPGA designs with PCIe, pass the Intel vendor IDs to `mkHostTools`, for
example `fpgaPciVendors = [ "0x1172" ]` (`0x1172` is the default vendor ID of
Intel's PCIe IP).

### mkQuartusStagePackage

```nix
fpga-nix.lib.mkQuartusStagePackage {
  inherit pkgs;
  intelTools = intel;
  quartusShareRoot = "/share/intel-fpga/tools";
  quartusVersion = "24.1";
  pname = "my-design";
  src = ./hw; # contains my_design.qpf and my_design.qsf
  project = "my_design";
}
```

Runs `quartus_sh --flow compile` and installs `output_files/` with the `.sof`
and all reports. Quartus only writes there when the project sets
`PROJECT_OUTPUT_DIRECTORY`, so the stage adds it to the revision's `.qsf` when
it is missing and fails when the project uses another directory than
`outputDirectory`. Afterwards the Timing Analyzer reports the worst slack per
analysis, clock and operating condition into
`output_files/<revision>.slack.txt`. The stage fails on negative slack or when
no clock is constrained, unless `checkTiming = false`.

Quartus Prime Pro needs a license for most device families. Without one,
synthesis fails with "No license for family ...". Cyclone 10 GX needs no
license and is useful for testing the flow.

## Vendor tools and the build sandbox

Vendor tools are installed outside the Nix store. On Linux, a build only sees
them when their root is in `extra-sandbox-paths`, for example:

```nix
nixConfig.extra-sandbox-paths = [ "/share/xilinx" ];
```

Nix only applies a flake's `nixConfig` for trusted users who accept it.
Otherwise the path has to be in the host's Nix configuration. Every root in a
stage's `toolRoots` is checked before the build, so a missing path fails with
an explanation instead of a tool error.

## Environment variables

| Variable | Used by | Meaning |
| --- | --- | --- |
| `FPGA_NIX_XILINX_VERSION` | Xilinx wrappers | Tool version, required |
| `FPGA_NIX_XILINX_SHELL` | Xilinx wrappers | Path of `xilinx-shell` |
| `FPGA_NIX_XILINX_LICENSE_FILE` | Xilinx wrappers | License file |
| `FPGA_NIX_HW_SERVER_PORT` | `hw_server`, `program-fpga` | Port, default 3121 |
| `FPGA_PART_HINT` | `program-fpga` | Substring of the device part |
| `FPGA_JTAG_TARGET` | `program-fpga` | Substring of the JTAG target |
| `FPGA_BDF` | `hot-reset` | PCI address of the FPGA |
| `FPGA_NIX_PCI_VENDORS` | `hot-reset` | Accepted PCI vendor IDs |
| `FPGA_NIX_BUILD_ROOT` | `program-fpga` | Log directory root |
| `FPGA_NIX_QUARTUS_VERSION` | Quartus wrappers | Quartus version, required |
| `FPGA_NIX_QUARTUS_LICENSE_FILE` | Quartus wrappers | License file |
| `FPGA_NIX_QUARTUS_SHELL` | Quartus wrappers | Overrides the FHS shell |

Each `FPGA_NIX_*` variable also accepts the older `COYOTE_NIX_*` name, so
existing site flakes keep working while they move to the new names.

## Checks

`nix flake check` runs device-free tests with fake vendor tools, a fake
`xilinx-shell` and a fake PCI sysfs tree. It also checks formatting and a
100-character line limit.
