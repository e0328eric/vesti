# shell.nix
let
  # Pin the overlay to a commit for reproducibility — bump this hash when you
  # want a newer toolchain. Using a tag/commit instead of `master` keeps the
  # shell deterministic.
  rustOverlay = import (
    builtins.fetchTarball {
      url = "https://github.com/oxalica/rust-overlay/archive/master.tar.gz";
    }
  );

  pkgs = import <nixpkgs> { overlays = [ rustOverlay ]; };

  # Rust toolchain that bundles the macOS std, so `cargo zigbuild
  # --target aarch64-apple-darwin` can find `core`/`std`.
  rustToolchain = pkgs.rust-bin.stable.latest.default.override {
    targets = [
      "x86_64-unknown-linux-gnu"
      "aarch64-apple-darwin"
    ];
  };
in
(pkgs.buildFHSEnv {
  name = "vesti-dev";

  targetPkgs =
    pkgs: with pkgs; [
      # rust + build orchestration
      rustToolchain # replaces cargo + rustc (incl. macOS rust-std)
      cargo-zigbuild
      pkg-config
      cmake
      ninja
      gnumake
      gcc

      # autotools / meson stack — needed to build the vcpkg ports
      autoconf
      autoconf-archive
      automake
      libtool
      m4
      meson
      bison
      flex
      gperf
      gettext
      texinfo
      perl
      python3

      # archive tools vcpkg uses to unpack downloads
      gnutar
      zip
      unzip
      gzip
      xz

      # tectonic / vcpkg port dependencies
      graphite2
      libpng
      openssl
      icu
      freetype
      fontconfig
      harfbuzz
      zlib

      # misc
      upx
      curl
      git
      cacert
      file
      which
    ];

  runScript = "fish";

  # Environment for the macOS cross build. `zig build rust` also sets most of
  # these via build.zig, but exporting them here keeps a direct `cargo vcpkg`
  # invocation working too. Adjust the two paths to match your machine.
  profile = ''
    export PATH="$HOME/.local/zig:$PATH"
    export ZIG="$HOME/.local/zig/zig"
    export ZIG_LIBC_INCLUDE="$HOME/.local/zig/lib/libc/include"
    export MACOSX_SDK="$HOME/.local/MacOSX13.sdk"
    export SDKROOT="$MACOSX_SDK"
    export MACOSX_DEPLOYMENT_TARGET=13.0
    export ACLOCAL_PATH=/usr/share/aclocal
  '';
}).env
