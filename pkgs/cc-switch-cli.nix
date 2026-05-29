{ lib, stdenv, fetchurl, autoPatchelfHook, gcc-unwrapped, openssl, zlib, xz }:

stdenv.mkDerivation {
  pname = "cc-switch-cli";
  version = "5.6.1";

  src = fetchurl {
    url = "https://github.com/SaladDay/cc-switch-cli/releases/download/v5.6.1/cc-switch-cli-linux-x64.tar.gz";
    hash = "sha256-6y1WUaJ+y+/QtzjVshbkYuI6Q/2laUFycRl9AItJcIM=";
  };

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ gcc-unwrapped.lib openssl zlib xz ];

  sourceRoot = ".";
  installPhase = ''
    mkdir -p $out/bin
    cp cc-switch $out/bin/
    chmod +x $out/bin/cc-switch
  '';

  meta = with lib; {
    description = "A cross-platform CLI All-in-One assistant tool for Claude Code, Codex & Gemini CLI";
    homepage = "https://github.com/SaladDay/cc-switch-cli";
    license = licenses.mit;
    mainProgram = "cc-switch";
    platforms = [ "x86_64-linux" ];
  };
}
