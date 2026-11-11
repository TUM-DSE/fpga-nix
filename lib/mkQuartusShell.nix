# An FHS environment in which Intel Quartus Prime Pro runs. It provides the
# libraries Quartus expects, but no Quartus installation and no version: the
# Quartus wrappers select both when they start a tool.
#
# Based on the shell.nix files shipped next to the Quartus installations on
# the Doctor cluster, without <nixpkgs> and with fonts set up at build time.
{
  pkgs,
  name ? "quartus-shell",
  extraPkgs ? [ ],
}:
let
  # Quartus links against libncurses.so.5 and libtinfo.so.5, so build the
  # terminfo library separately and provide both the wide and narrow variants.
  # A function of the package set, so the 32-bit set gets 32-bit libraries.
  ncurses5For =
    p:
    p.ncurses5.overrideAttrs (old: {
      configureFlags = old.configureFlags ++ [ "--with-termlib" ];
      postFixup = "";
    });

  fontsConf = pkgs.makeFontsConf { fontDirectories = [ pkgs.freefont_ttf ]; };
in
pkgs.buildFHSEnv {
  inherit name;
  runScript = "bash";

  targetPkgs =
    p:
    with p;
    [
      alsa-lib
      bash
      brotli
      coreutils
      dbus
      expat
      glib
      gtk3
      libdrm
      libjpeg
      libpng
      libudev0-shim
      lsb-release
      python3
      util-linux
      xz
      zlib
    ]
    ++ extraPkgs;

  multiArch = true;
  multiPkgs =
    p:
    let
      ncurses5 = ncurses5For p;
    in
    with p;
    [
      bzip2
      fontconfig
      freetype
      gcc
      glibc
      libxcrypt-legacy
      libxml2
      ncurses5
      (ncurses5.override { unicodeSupport = false; })
      unixODBC
      xorg.libICE
      xorg.libSM
      xorg.libX11
      xorg.libXau
      xorg.libXdmcp
      xorg.libXext
      xorg.libXft
      xorg.libXi
      xorg.libXrender
      xorg.libXt
      xorg.libXtst
    ];

  profile = ''
    export FONTCONFIG_FILE=${fontsConf}
  '';

  meta = {
    description = "FHS environment for running Intel Quartus Prime Pro";
    platforms = [ "x86_64-linux" ];
  };
}
