{ lib, stdenvNoCC, fetchzip }:

stdenvNoCC.mkDerivation {
  pname = "maple-mono-nf-cn";
  version = "7.9";

  src = fetchzip {
    url = "https://github.com/subframe7536/maple-font/releases/download/v7.9/MapleMono-NF-CN-Unhinted.zip";
    hash = "sha256-8v90s5TAolpbfoSwXdVmKCsFJ9AJ71DT/WRgBV2S94Y=";
    stripRoot = false;
  };

  installPhase = ''
    mkdir -p $out/share/fonts/truetype
    cp *.ttf $out/share/fonts/truetype/
  '';

  meta = with lib; {
    description = "Maple Mono NF CN font";
    homepage = "https://github.com/subframe7536/maple-font";
    license = licenses.ofl;
    platforms = platforms.all;
  };
}
