{
  lib,
  stdenv,
  fetchurl,
}:

let
  version = "2.0.0";
  release = {
    "x86_64-linux" = {
      url = "https://github.com/AllDmeat/kaiten-mcp/releases/download/${version}/kaiten-mcp_${version}_linux_x86_64.tar.gz";
      hash = "sha256-REXFNlQ1BY6Khooo2kK+UaAG/abUHEsBHjW/unYnHMo=";
    };
    "aarch64-linux" = {
      url = "https://github.com/AllDmeat/kaiten-mcp/releases/download/${version}/kaiten-mcp_${version}_linux_arm64.tar.gz";
      hash = "sha256-pbB8kakbkr/ESvSRSl7M6I8GKe0Q9tPSzS8lFURu1lA=";
    };
  };
  platform = stdenv.hostPlatform.system;
  srcInfo = release.${platform};
in
stdenv.mkDerivation {
  pname = "kaiten-mcp";
  inherit version;

  src = fetchurl srcInfo;

  dontBuild = true;

  installPhase = ''
    install -Dm755 kaiten-mcp $out/bin/kaiten-mcp
  '';

  meta = {
    description = "MCP server for Kaiten boards, cards, and properties";
    homepage = "https://github.com/AllDmeat/kaiten-mcp";
    license = lib.licenses.mit;
    mainProgram = "kaiten-mcp";
    platforms = builtins.attrNames release;
  };
}
