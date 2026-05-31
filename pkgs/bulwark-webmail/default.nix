{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  nodejs_24,
}:

buildNpmPackage (finalAttrs: {
  pname = "bulwark-webmail";
  version = "1.7.2";

  src = fetchFromGitHub {
    owner = "bulwarkmail";
    repo = "webmail";
    tag = finalAttrs.version;
    hash = "sha256-M5EgANzzBAVqQ+XdOQnoXlD3CyYCRcO0PiC6INrnqq8=";
  };

  npmDepsHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

  nodejs = nodejs_24;

  buildPhase = ''
    runHook preBuild
    npm run build -- --webpack
    runHook postBuild
  '';

  env = {
    NEXT_TELEMETRY_DISABLED = "1";
    GIT_COMMIT = "unknown";
  };

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -r .next/standalone/. $out/
    cp -r .next/static $out/.next/static
    cp -r public $out/public

    runHook postInstall
  '';

  meta = {
    description = "Modern webmail client for Stalwart Mail Server, built with Next.js and JMAP";
    homepage = "https://github.com/bulwarkmail/webmail";
    license = lib.licenses.agpl3Only;
    mainProgram = "server";
  };
})
