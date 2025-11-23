{
  lib,
  python3,
  pkgs,
  fetchFromGitHub,
}:

let
  version = "0.9.1";
  python = pkgs.python311;

  minifluxPythonClient = python.pkgs.buildPythonPackage rec {
    pname = "miniflux";
    version = "1.1.4";
    format = "pyproject";

    src = pkgs.fetchPypi {
      inherit pname version;
      extension = "tar.gz";
      hash = "sha256-VFcddb3rU6NHF2aRuWFNpqLrtI94fChQ+DWhh0WHhN4=";
    };

    propagatedBuildInputs = with python.pkgs; [ requests ];

    nativeBuildInputs = with python.pkgs; [
      setuptools # Explicitly add setuptools to resolve backend availability
    ];

    # No tests in the package
    doCheck = false;

    meta = with pkgs.lib; {
      description = "Python client library for Miniflux";
      homepage = "https://github.com/miniflux/python-client";
      license = licenses.mit;
    };
  };
in
python3.pkgs.buildPythonApplication {
  pname = "miniflux-ai";
  inherit version;

  src = fetchFromGitHub {
    owner = "Qetesh";
    repo = "miniflux-ai";
    tag = "v${version}";
    hash = "sha256-JNOoJW4g90PlGwoj6WJ3DPZ13dhF+QgoZavdqrZU/bo=";
  };

  format = "other";

  propogateBuildInputs = with python.pkgs; [
    # miniflux
    minifluxPythonClient
    openai
    markdownify
    markdown
    pyyaml
    flask
    feedgen
    schedule
    flasgger
    ratelimit
  ];

  installPhase = ''
    mkdir -p $out/${python.sitePackages}
    cp -r . $out/${python.sitePackages}/miniflux_ai
    mkdir -p $out/bin
    makeWrapper "${python.interpreter}" $out/bin/miniflux-ai \
      --add-flags "-u $out/${python.sitePackages}/miniflux_ai/main.py" \
      --prefix PYTHONPATH : "$out/${python.sitePackages}"
  '';

  meta = with lib; {
    description = "Miniflux with AI. Add AI summaries, translations, and AI news based on RSS content";
    homepage = "https://github.com/Qetesh/miniflux-ai";
    license = licenses.mit;
    maintainers = [ ];
  };
}
