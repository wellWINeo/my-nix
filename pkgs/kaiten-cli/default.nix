{
  lib,
  python3Packages,
  src,
  gitMinimal,
  bash,
  zsh,
}:

python3Packages.buildPythonApplication {
  pname = "kaiten-cli";
  version = "0.3.3";
  pyproject = true;
  inherit src;
  patches = [ ./click-locales.patch ];

  build-system = [ python3Packages.hatchling ];

  postPatch = ''
    substituteInPlace tests/test_shell_completion.py \
      --replace-fail \
        "shlex.quote(str(root / 'src'))" \
        "shlex.quote(str(root / 'src') + os.pathsep + os.pathsep.join(sys.path))"
  '';

  dependencies = with python3Packages; [
    click
    httpx
    platformdirs
  ];

  nativeCheckInputs = with python3Packages; [
    pytestCheckHook
    pytest-asyncio
    pytest-cov
    pytest-timeout
    pytest-socket
    pyyaml
    respx
    gitMinimal
    bash
    zsh
  ];

  pythonImportsCheck = [ "kaiten_cli" ];

  doInstallCheck = true;
  installCheckPhase = ''
        runHook preInstallCheck
        export HOME="$TMPDIR/home"
        export XDG_CONFIG_HOME="$TMPDIR/config"
        mkdir -p "$HOME" "$XDG_CONFIG_HOME"
        unset KAITEN_DOMAIN KAITEN_TOKEN KAITEN_LIVE

        pytest -m 'not live'
        "$out/bin/kaiten" --locale en --version | grep -F '0.3.3'
        "$out/bin/kaiten" --locale en --help >/dev/null
        "$out/bin/kaiten" --locale ru --help >/dev/null
        "$out/bin/kaiten" --locale en agent-help >/dev/null
        "$out/bin/kaiten" --locale en search-tools cards >/dev/null
        "$out/bin/kaiten-agent-gateway" --help >/dev/null

        set +e
        "$out/bin/kaiten" --locale en --json --read-only cards list > "$TMPDIR/missing-config.json"
        status=$?
        set -e
        test "$status" -eq 3
        ${python3Packages.python.interpreter} - "$TMPDIR/missing-config.json" <<'PY'
    import json
    import sys

    with open(sys.argv[1], encoding="utf-8") as stream:
        payload = json.load(stream)
    assert payload["success"] is False
    assert payload["error"]["type"] == "config_error"
    PY
        runHook postInstallCheck
  '';

  meta = {
    description = "LLM-oriented CLI for Kaiten";
    mainProgram = "kaiten";
    platforms = lib.platforms.unix;
  };
}
