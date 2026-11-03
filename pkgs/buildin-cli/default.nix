{ stdenv, fetchurl }:

stdenv.mkDerivation (finalAttrs: {
  pname = "buildin-cli";
  version = "0.3.15";

  src = fetchurl {
    url = "https://cdn.buildin.ai/buildin-cli/releases/v${finalAttrs.version}/buildin-darwin-arm64.tar.gz";
    hash = "sha256-7WVtZLNMprgptKN1zvbdPC/87rwxDoBAvUv29CZuIxo=";
  };

  sourceRoot = ".";
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 buildin "$out/bin/buildin"
    runHook postInstall
  '';

  meta = {
    description = "Buildin command-line interface";
    mainProgram = "buildin";
    platforms = [ "aarch64-darwin" ];
  };
})
