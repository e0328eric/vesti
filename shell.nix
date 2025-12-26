with import <nixpkgs> {};

# since I am using NixOS, any other compoments (e.g. zig) is already installed,
# so some packages are missing although there is no issue to compile
pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    zig
    zls
    cargo
    graphite2
    pkg-config
    libpng
    openssl
    icu
    freetype
    fontconfig
    harfbuzz
    upx
  ];
}

