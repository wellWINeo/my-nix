{
  config,
  lib,
  pkgs,
  ...
}:
with lib;

let
  cfg = config.roles.backup;
  gpgHome = "/var/lib/duplicity/.gnupg";

in
{
  options.roles.backup = {
    enable = mkEnableOption "duplicity backups";

    paths = mkOption {
      type = types.listOf types.str;
      default = [ ];
    };

    gpgPublicKey = mkOption {
      type = types.path;
    };

    gpgKeyId = mkOption {
      type = types.str;
    };

    targetUrl = mkOption {
      type = types.str;
      description = "Duplicity target URL (e.g. s3://endpoint/bucket/prefix)";
    };

    frequency = mkOption {
      type = types.nullOr types.str;
      default = "daily";
    };

    fullIfOlderThan = mkOption {
      type = types.str;
      default = "1M";
    };

    maxFull = mkOption {
      type = types.int;
      default = 3;
    };

    exclude = mkOption {
      type = types.listOf types.str;
      default = [ ];
    };

    extraFlags = mkOption {
      type = types.listOf types.str;
      default = [ ];
    };

    afterServices = mkOption {
      type = types.listOf types.str;
      default = [ ];
      internal = true;
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.paths != [ ];
        message = "roles.backup: at least one path must be set";
      }
    ];

    system.activationScripts.backup-gnupg = ''
      mkdir -p ${gpgHome}
      chmod 700 ${gpgHome}
      if [ ! -f ${gpgHome}/pubring.kbx ] || ! ${pkgs.gnupg}/bin/gpg --homedir ${gpgHome} --list-keys "${cfg.gpgKeyId}" >/dev/null 2>&1; then
        ${pkgs.gnupg}/bin/gpg --homedir ${gpgHome} --import ${cfg.gpgPublicKey}
      fi
    '';

    services.duplicity =
      let
        allIncludes = cfg.paths;
      in
      {
        enable = true;
        root = "/";
        include = allIncludes;
        exclude = cfg.exclude ++ [ "**" ];
        targetUrl = cfg.targetUrl;
        secretFile = "/etc/nixos/secrets/duplicity-env";
        frequency = cfg.frequency;
        fullIfOlderThan = cfg.fullIfOlderThan;
        extraFlags = [
          "--encrypt-key"
          cfg.gpgKeyId
          "--gpg-options=--homedir ${gpgHome}"
          "--verbosity"
          "notice"
          "--num-retries"
          "3"
          "--volsize"
          "100"
        ]
        ++ cfg.extraFlags;
        cleanup.maxFull = cfg.maxFull;
      };

    systemd.services.duplicity = mkIf (cfg.afterServices != [ ]) {
      after = cfg.afterServices;
      requires = cfg.afterServices;
    };

    systemd.timers.duplicity = mkIf (cfg.frequency != null) {
      timerConfig.Persistent = true;
    };
  };
}
