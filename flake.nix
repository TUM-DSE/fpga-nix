{
  description = "Vendor-neutral Nix tooling for FPGA development";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
    fpgahog = {
      url = "github:taugoust/fpgahog/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      fpgahog,
      ...
    }:
    let
      baseLib = import ./lib;
      fpgahogFor = pkgs: fpgahog.packages.${pkgs.stdenv.hostPlatform.system}.default;
      fpgaNixLib = baseLib // {
        mkDevShell = args: baseLib.mkDevShell ({ fpgahogPackage = fpgahogFor args.pkgs; } // args);
      };
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        checks = import ./tests {
          inherit pkgs fpgaNixLib;
          src = self;
        };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.nixfmt
            pkgs.shellcheck
          ];
        };

        formatter = pkgs.nixfmt-tree;
      }
    )
    // {
      lib = fpgaNixLib;
    };
}
