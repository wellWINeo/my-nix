# roles/network/xray/default.nix
#
# Coordinator: imports the xray mode modules, enforces mutual exclusion,
# chooses the active mode's complete generated config as roles.xray._configTemplate,
# attaches metrics JSON when roles.xray.metrics is enabled, binds SNI-router
# entries from the active mode's enabled REALITY ingress inbounds, and owns
# the shared systemd runtime: credential rendering (REALITY private key and
# enabled Hysteria2 TLS material via LoadCredential), the jq dispatch that
# distinguishes the relay hy2-relay-in tag from the server hy2-in tag, and
# the xray -test guarded JSON startup.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.roles.xray;

  emptyConfig = {
    inbounds = [ ];
    outbounds = [ ];
    routing = {
      rules = [ ];
      balancers = [ ];
    };
  };

  serverCfg = cfg.server;
  relayCfg = cfg.relay;
  clientCfg = cfg.client;
  metricsCfg = cfg.metrics;

  enabledModeCount = length (
    filter id [
      serverCfg.enable
      relayCfg.enable
      clientCfg.enable
    ]
  );
  serverOrRelay = serverCfg.enable || relayCfg.enable;

  serverHysteriaEnabled = serverCfg.enable && serverCfg.ingress.hysteria2.enable;
  relayHysteriaEnabled = relayCfg.enable && relayCfg.ingress.hysteria2.enable;
  # Veles-only CDN VLESS ingress: enabled only on an active relay that turns
  # on ingress.vless.cdnXhttp; gates the credential load and the runtime JSON
  # injection for vless-cdn-xhttp-in.
  cdnEnabled = relayCfg.enable && relayCfg.ingress.vless.cdnXhttp.enable;

  # Exactly one active mode contributes its complete config template.
  activeTemplate =
    if serverCfg.enable then
      serverCfg._configTemplate
    else if relayCfg.enable then
      relayCfg._configTemplate
    else
      emptyConfig;

  # Metrics JSON is attached by the coordinator (no module fragment).
  xrayConfigTemplate =
    activeTemplate
    // (optionalAttrs metricsCfg.enable {
      metrics.listen = metricsCfg.listen;
      stats = { };
      policy.system = {
        statsInboundUplink = true;
        statsInboundDownlink = true;
        statsOutboundUplink = true;
        statsOutboundDownlink = true;
      };
    });

  # SNI-router entries bound from the active mode's enabled REALITY ingress
  # inbounds (server backends 9000-9002, relay backends 9010-9012). The CDN
  # inbound is VLESS without REALITY and has no realitySettings, so it produces
  # no entry here; when enabled, its explicit HTTPS-origin entry is appended
  # LAST so the first entry — the effective fallback in sni-router.nix while
  # defaultBackend stays null — remains the previous REALITY backend.
  sniEntries =
    map
      (inbound: {
        sni = head inbound.streamSettings.realitySettings.serverNames;
        backend = "127.0.0.1:${toString inbound.port}";
      })
      (
        filter (
          inbound: (inbound.protocol or "") == "vless" && (inbound.streamSettings.security or "") == "reality"
        ) activeTemplate.inbounds
      )
    ++ optional cdnEnabled {
      sni = relayCfg.ingress.vless.cdnXhttp.originDomain;
      backend = "127.0.0.1:9443";
    };

  privateKeyFile =
    if serverCfg.enable then
      serverCfg.ingress.reality.privateKeyFile
    else
      relayCfg.ingress.reality.privateKeyFile;

  configTemplateFile = pkgs.writeText "xray-config-template.json" (
    builtins.toJSON xrayConfigTemplate
  );
in
{
  imports = [
    ./server.nix
    ./client.nix
    ./relay.nix
    ./metrics.nix
    ../sni-router.nix
  ];

  options.roles.xray = {
    fragmentClientHello = mkOption {
      type = types.bool;
      default = true;
      description = "Fragment ClientHello messages on outgoing VLESS connections (bridge and forward links)";
    };

    _configTemplate = mkOption {
      type = types.attrs;
      internal = true;
      default = { };
      description = "The exact config template JSON passed to pkgs.writeText (before runtime credential injection)";
    };
  };

  config = mkIf (enabledModeCount > 0) {
    assertions = [
      {
        assertion = enabledModeCount <= 1;
        message = "roles.xray: only one of server, relay and client modes may be enabled on a host";
      }
    ];

    # SNI routing (server/relay mode only); entries derive from the active
    # mode's enabled ingress inbounds.
    roles.sni-router = mkIf serverOrRelay {
      enable = true;
      entries = sniEntries;
    };

    # Eval-time view of the exact JSON handed to pkgs.writeText below.
    roles.xray._configTemplate = xrayConfigTemplate;

    # Xray systemd service (server/relay mode only; the client mode runs the
    # upstream services.xray module instead).
    systemd.services.xray = mkIf serverOrRelay {
      description = "Xray Reality Daemon";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.xray
        pkgs.jq
      ];
      serviceConfig = {
        PrivateTmp = true;
        LoadCredential = [
          "private-key:${privateKeyFile}"
        ]
        ++ optional serverHysteriaEnabled "hysteria-cert:${serverCfg.ingress.hysteria2.certFile}"
        ++ optional serverHysteriaEnabled "hysteria-key:${serverCfg.ingress.hysteria2.keyFile}"
        ++ optional relayHysteriaEnabled "hysteria-relay-cert:${relayCfg.ingress.hysteria2.certFile}"
        ++ optional relayHysteriaEnabled "hysteria-relay-key:${relayCfg.ingress.hysteria2.keyFile}"
        ++ optional cdnEnabled "cdn-decryption:${relayCfg.ingress.vless.cdnXhttp.decryptionFile}";
        DynamicUser = true;
        CapabilityBoundingSet = "CAP_NET_ADMIN CAP_NET_BIND_SERVICE";
        AmbientCapabilities = "CAP_NET_ADMIN CAP_NET_BIND_SERVICE";
        NoNewPrivileges = true;
      };
      script =
        let
          # Hysteria credentials are passed as CREDENTIALS_DIRECTORY paths,
          # not contents: the jq stage assigns them to certificateFile/keyFile.
          # Paths are emitted only when the corresponding inbound is enabled on
          # this host, mirroring the LoadCredential list; absent assignments
          # stay inert because no hysteria inbound exists to consume them.
          hysteriaCredentialPaths =
            optionalString serverHysteriaEnabled ''
              cert="$CREDENTIALS_DIRECTORY/hysteria-cert"
              certKey="$CREDENTIALS_DIRECTORY/hysteria-key"
            ''
            + optionalString relayHysteriaEnabled ''
              relayCert="$CREDENTIALS_DIRECTORY/hysteria-relay-cert"
              relayKey="$CREDENTIALS_DIRECTORY/hysteria-relay-key"
            '';
        in
        ''
          set -euo pipefail
          umask 077
          configFile="$(mktemp)"

          privateKey="$(cat "$CREDENTIALS_DIRECTORY/private-key")"
          cert="" certKey="" relayCert="" relayKey=""
          ${hysteriaCredentialPaths}
          ${optionalString cdnEnabled ''
            # Guard the CDN VLESS decryption credential BEFORE rendering: a
            # missing, blank, whitespace-only or literal-'none' file would
            # disable the inner VLESS encryption, so refuse startup. The value
            # only ever lives in a shell variable; it is never logged, printed
            # or passed on a command line. A valid vlessenc decryption value
            # contains no whitespace, so the whitespace-stripped comparison is
            # exact for both rejections.
            cdnDecryptionGuard() {
              local value
              value="$(tr -d '[:space:]' < "$CREDENTIALS_DIRECTORY/cdn-decryption")"
              if [ -z "$value" ] || [ "$value" = none ]; then
                echo "CDN VLESS decryption credential missing, blank, whitespace-only or the invalid 'none' sentinel" >&2
                return 1
              fi
            }
            cdnDecryptionGuard || exit 1
          ''}
          cat ${configTemplateFile} \
            | jq \
                --arg privateKey "$privateKey" \
                --arg cert "$cert" \
                --arg certKey "$certKey" \
                --arg relayCert "$relayCert" \
                --arg relayKey "$relayKey" \
                --rawfile decryption ${
                  if cdnEnabled then ''"$CREDENTIALS_DIRECTORY/cdn-decryption"'' else "/dev/null"
                } \
                '.inbounds[] |=
                  if .tag == "vless-cdn-xhttp-in" then
                    .settings.decryption = ($decryption | rtrimstr("\n"))
                  elif (.streamSettings.security // "") == "reality" then
                    .streamSettings.realitySettings.privateKey = $privateKey
                  elif .protocol != "hysteria" then .
                  elif .tag == "hy2-relay-in" then
                    .streamSettings.tlsSettings.certificates[0] = {certificateFile: $relayCert, keyFile: $relayKey}
                  else
                    .streamSettings.tlsSettings.certificates[0] = {certificateFile: $cert, keyFile: $certKey}
                  end' \
            > "$configFile"

          # Activation guard: refuse to launch an invalid rendered config.
          ${
            if cdnEnabled then
              ''
                # Xray validation errors may echo the decrypted VLESS
                # decryption value, so diagnostics are suppressed and
                # replaced with a static failure message.
                if ! xray run -test -format json -config "$configFile" >/dev/null 2>&1; then
                  echo "Xray configuration validation failed; diagnostics suppressed to protect VLESS credential" >&2
                  exit 1
                fi
              ''
            else
              ''
                xray run -test -format json -config "$configFile"
              ''
          }
          exec xray run -format json -config "$configFile"
        '';
    };
  };
}
