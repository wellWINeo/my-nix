# roles/network/xray/relay.nix
#
# Defines roles.xray.relay options and exports _relayConfig fragment.
# Relay adds forwarding inbounds (suffixed -fwd/Fwd) that route traffic
# to another xray server via a leastPing balancer.
#
# Inbound enablement is gated on the server's transport being enabled
# (relay inbounds reuse server's gRPC serviceName / xHTTP path / Reality shortIds).
# Outbound enablement is gated on cfg.target.<transport>.enable independently,
# allowing the balancer to pick any enabled outbound regardless of how the
# client connected.
{
  config,
  lib,
  ...
}:

with lib;

let
  cfg = config.roles.xray.relay;
  serverCfg = config.roles.xray.server;
  secrets = import ../../../secrets;
  opts = import ./options.nix { inherit lib; };

  relayTcpPort = 9010;
  relayGrpcPort = 9011;
  relayXhttpPort = 9012;

  # Clients with Vision flow (TCP only)
  vlessTcpClients = map (u: {
    id = u.uuid;
    flow = "xtls-rprx-vision";
    email = "${u.name}@xray";
  }) secrets.singBoxUsers;

  # Clients without flow (gRPC, xHTTP)
  vlessClients = map (u: {
    id = u.uuid;
    email = "${u.name}@xray";
  }) secrets.singBoxUsers;

  mkRealitySettings = sni: {
    target = "${sni}:443";
    serverNames = [ sni ];
    shortIds = secrets.xray.reality.shortIds or [ ];
  };

  # Build outbound streamSettings for connecting to the target server.
  mkTargetStreamSettings =
    {
      network,
      serverName,
      extra ? { },
    }:
    let
      sni = if serverName != "" then serverName else cfg.target.reality.serverName;
    in
    {
      network = network;
      security = "reality";
      realitySettings = {
        publicKey = cfg.target.reality.publicKey;
        shortId = cfg.target.reality.shortId;
        serverName = sni;
        fingerprint = cfg.target.reality.fingerprint;
      };
    }
    // extra;

  # Inbound enablement: gated on server transport being configured
  # (relay inbounds reuse server's serviceName/path/shortIds)
  tcpInEnabled = serverCfg.vlessTcp.enable;
  grpcInEnabled = serverCfg.vlessGrpc.enable;
  xhttpInEnabled = serverCfg.vlessXhttp.enable;

  # Outbound enablement: independently controlled via target transport options
  # The balancer picks among all enabled outbounds regardless of inbound transport
  tcpOutEnabled = cfg.target.vlessTcp.enable;
  grpcOutEnabled = cfg.target.vlessGrpc.enable;
  xhttpOutEnabled = cfg.target.vlessXhttp.enable;

  relayConfig = {
    inbounds =
      lib.optionals tcpInEnabled [
        {
          listen = "127.0.0.1";
          port = relayTcpPort;
          protocol = "vless";
          tag = "vless-tcp-fwd-in";
          settings = {
            clients = vlessTcpClients;
            decryption = "none";
          };
          streamSettings = {
            network = "tcp";
            security = "reality";
            realitySettings = mkRealitySettings cfg.vlessTcp.sni;
            sockopt.acceptProxyProtocol = true;
          };
        }
      ]
      ++ lib.optionals grpcInEnabled [
        {
          listen = "127.0.0.1";
          port = relayGrpcPort;
          protocol = "vless";
          tag = "vless-grpcFwd-in";
          settings = {
            clients = vlessClients;
            decryption = "none";
          };
          streamSettings = {
            network = "grpc";
            security = "reality";
            realitySettings = (mkRealitySettings cfg.vlessGrpc.sni) // {
              alpn = [ "h2" ];
            };
            grpcSettings = {
              serviceName = serverCfg.vlessGrpc.serviceName;
            };
            sockopt.acceptProxyProtocol = true;
          };
        }
      ]
      ++ lib.optionals xhttpInEnabled [
        {
          listen = "127.0.0.1";
          port = relayXhttpPort;
          protocol = "vless";
          tag = "vless-xhttp-fwd-in";
          settings = {
            clients = vlessClients;
            decryption = "none";
          };
          streamSettings = {
            network = "xhttp";
            security = "reality";
            realitySettings = mkRealitySettings cfg.vlessXhttp.sni;
            xhttpSettings = {
              path = serverCfg.vlessXhttp.path;
            };
            sockopt.acceptProxyProtocol = true;
          };
        }
      ];

    outbounds =
      lib.optionals tcpOutEnabled [
        {
          protocol = "vless";
          tag = "relay-tcp-out";
          settings = {
            vnext = [
              {
                address = cfg.target.server;
                port = 443;
                users = [
                  {
                    id = cfg.user.uuid;
                    flow = "xtls-rprx-vision";
                    encryption = "none";
                  }
                ];
              }
            ];
          };
          streamSettings = mkTargetStreamSettings {
            network = "tcp";
            serverName = cfg.target.vlessTcp.serverName;
          };
        }
      ]
      ++ lib.optionals grpcOutEnabled [
        {
          protocol = "vless";
          tag = "relay-grpc-out";
          settings = {
            vnext = [
              {
                address = cfg.target.server;
                port = 443;
                users = [
                  {
                    id = cfg.user.uuid;
                    encryption = "none";
                  }
                ];
              }
            ];
          };
          streamSettings = mkTargetStreamSettings {
            network = "grpc";
            serverName = cfg.target.vlessGrpc.serverName;
            extra = {
              grpcSettings = {
                serviceName = cfg.target.vlessGrpc.serviceName;
              };
            };
          };
        }
      ]
      ++ lib.optionals xhttpOutEnabled [
        {
          protocol = "vless";
          tag = "relay-xhttp-out";
          settings = {
            vnext = [
              {
                address = cfg.target.server;
                port = 443;
                users = [
                  {
                    id = cfg.user.uuid;
                    encryption = "none";
                  }
                ];
              }
            ];
          };
          streamSettings = mkTargetStreamSettings {
            network = "xhttp";
            serverName = cfg.target.vlessXhttp.serverName;
            extra = {
              xhttpSettings = {
                path = cfg.target.vlessXhttp.path;
              };
            };
          };
        }
      ];

    routing = {
      rules = lib.optionals (tcpInEnabled || grpcInEnabled || xhttpInEnabled) [
        {
          type = "field";
          inboundTag =
            lib.optionals tcpInEnabled [ "vless-tcp-fwd-in" ]
            ++ lib.optionals grpcInEnabled [ "vless-grpcFwd-in" ]
            ++ lib.optionals xhttpInEnabled [ "vless-xhttp-fwd-in" ];
          balancerTag = "relay-balancer";
        }
      ];
      balancers = lib.optionals (tcpOutEnabled || grpcOutEnabled || xhttpOutEnabled) [
        {
          tag = "relay-balancer";
          selector =
            lib.optionals tcpOutEnabled [ "relay-tcp-out" ]
            ++ lib.optionals grpcOutEnabled [ "relay-grpc-out" ]
            ++ lib.optionals xhttpOutEnabled [ "relay-xhttp-out" ];
          strategy = {
            type = "leastPing";
          };
        }
      ];
    };

  };
in
{
  options.roles.xray.relay = {
    enable = mkEnableOption "relay traffic to another xray server";

    user = mkOption {
      type = types.attrs;
      description = "User credentials for authenticating to the target server ({ uuid, name, ... } from secrets.singBoxUsers)";
    };

    target = {
      server = mkOption {
        type = types.str;
        description = "Target xray server IP or hostname";
      };

      reality = opts.mkRealityClientOptions { };

      vlessTcp = opts.mkVlessTcpOptions { includeConnection = false; };
      vlessGrpc = opts.mkVlessGrpcOptions { includeConnection = false; };
      vlessXhttp = opts.mkVlessXhttpOptions { includeConnection = false; };
    };

    # Relay's own inbound SNIs (for nginx SNI routing on this server).
    # Each must differ from the server's SNI for the same transport.
    vlessTcp.sni = mkOption {
      type = types.str;
      description = "SNI for relay TCP inbound (must differ from server's TCP SNI)";
    };

    vlessGrpc.sni = mkOption {
      type = types.str;
      description = "SNI for relay gRPC inbound (must differ from server's gRPC SNI)";
    };

    vlessXhttp.sni = mkOption {
      type = types.str;
      description = "SNI for relay xHTTP inbound (must differ from server's xHTTP SNI)";
    };
  };

  config = mkIf (config.roles.xray.enable && cfg.enable) {
    assertions = [
      {
        assertion = config.roles.xray.server.enable;
        message = "roles.xray.relay requires roles.xray.server to be enabled";
      }
      {
        assertion = tcpOutEnabled || grpcOutEnabled || xhttpOutEnabled;
        message = "At least one relay target transport must be enabled (cfg.target.vless{Tcp,Grpc,Xhttp}.enable)";
      }
      {
        assertion = tcpInEnabled || grpcInEnabled || xhttpInEnabled;
        message = "At least one server transport must be enabled for relay inbounds to be created";
      }
    ];

    roles.xray._relayConfig = relayConfig;
  };
}
