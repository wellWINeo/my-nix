{
  config,
  lib,
  pkgs,
  ...
}:
with lib;

let
  cfg = config.roles.backup;
  stagingDir = "/var/lib/backup-staging";
  gpgHome = "/var/lib/duplicity/.gnupg";
  hasDatabases = cfg.databases != [ ];
  hasPaths = cfg.paths != [ ];

in
{
  options.roles.backup = {
    enable = mkEnableOption "duplicity backups";

    paths = mkOption {
      type = types.listOf types.str;
      default = [ ];
    };

    databases = mkOption {
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
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = hasPaths || hasDatabases;
        message = "roles.backup: at least one of paths or databases must be set";
      }
    ];

    system.activationScripts.backup-gnupg = ''
      mkdir -p ${gpgHome}
      chmod 700 ${gpgHome}
      if [ ! -f ${gpgHome}/pubring.kbx ] || ! ${pkgs.gnupg}/bin/gpg --homedir ${gpgHome} --list-keys "${cfg.gpgKeyId}" >/dev/null 2>&1; then
        ${pkgs.gnupg}/bin/gpg --homedir ${gpgHome} --import ${cfg.gpgPublicKey}
      fi
    '';

    systemd.services.backup-pgdump = mkIf hasDatabases {
      description = "Dump PostgreSQL databases for backup";
      path = [ pkgs.postgresql_16 ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "backup-pgdump" ''
          set -euo pipefail
          mkdir -p ${stagingDir}
          ${concatStringsSep "\n" (
            map (db: ''
              pg_dump ${db} | gzip > ${stagingDir}/${db}.sql.gz.tmp
              mv ${stagingDir}/${db}.sql.gz.tmp ${stagingDir}/${db}.sql.gz
            '') cfg.databases
          )}
        '';
        User = "postgres";
        Group = "postgres";
      };
    };

    services.duplicity =
      let
        allIncludes = cfg.paths ++ optionals hasDatabases [ stagingDir ];
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
        ] ++ cfg.extraFlags;
        cleanup.maxFull = cfg.maxFull;
      };

    systemd.services.duplicity =
      let
        needsPgDump = hasDatabases;
      in
      mkIf needsPgDump {
        after = [ "backup-pgdump.service" ];
        requires = [ "backup-pgdump.service" ];
      };

    systemd.timers.duplicity = mkIf (cfg.frequency != null) {
      timerConfig.Persistent = true;
    };
  };
}
