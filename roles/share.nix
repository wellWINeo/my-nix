# Samba share with wsdd and avahi

{
  config,
  pkgs,
  lib,
  ...
}:
with lib;

let
  cfg = config.roles.share;
in
{

  options.roles.share = {
    hostname = mkOption { type = types.str; };
    enable = mkEnableOption "Enable SMB share";
    enableTimeMachine = mkEnableOption "Enable TimeMachine on SMB";
  };

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      samba
      nssmdns
    ];

    services.samba = {
      enable = true;
      openFirewall = true;
      settings = {
        global = {
          workgroup = "WORKGROUP";
          security = "user";
          "server string" = cfg.hostname;
          "netbios name" = cfg.hostname;
          "hosts allow" = "10.20.0. 192.168.0. 127.0.0.1 localhost";
          "hosts deny" = "0.0.0.0/0";
          "client min protocol" = "NT1";
          "server min protocol" = "NT1";
          "map to guest" = "Bad User";
          "guest account" = "nobody";
        };

        Backups = mkIf cfg.enableTimeMachine {
          comment = "Backups share";
          path = "/mnt/storage/Backups";
          "valid users" = "o__ni";
          public = "no";
          writeable = "yes";
          "force user" = "o__ni";
          "fruit:aapl" = "yes";
          "fruit:time machine" = "yes";
          "vfs objects" = "catia fruit streams_xattr";
        };

        Public = {
          comment = "Public share";
          path = "/mnt/storage/Public";
          browseable = "yes";
          "read only" = "no";
          "guest ok" = "yes";
          "create mask" = "0666";
          "directory mask" = "0777";
          "force user" = "nobody";
          "force group" = "nogroup";
        };

        Homes = {
          comment = "Home directories";
          path = "/mnt/storage/Homes/%S";
          "valid users" = "%S";
          browseable = "yes";
          writable = "yes";
          "create mask" = "0644";
          "directory mask" = "0755";
          "fruit:aapl" = "yes";
          "fruit:time machine" = "yes";
          "vfs objects" = "catia fruit streams_xattr";
        };
      };
    };

    services.samba-wsdd = {
      enable = true;
      discovery = true;
      openFirewall = true;
    };

    services.avahi.extraServiceFiles = {
      smb = ''
        <?xml version="1.0" standalone='no'?>
        <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
        <service-group>
          <name replace-wildcards="yes">%h</name>
          <service>
            <type>_smb._tcp</type>
            <port>445</port>
          </service>
          <service>
            <type>_device-info._tcp</type>
            <port>0</port>
            <txt-record>model=TimeCapsule8,119</txt-record>
          </service>
          <service>
            <type>_adisk._tcp</type>
            <txt-record>dk0=adVN=TimeMachine,adVF=0x82</txt-record>
            <txt-record>sys=waMa=0,adVF=0x100</txt-record>
          </service>
        </service-group>
      '';
    };

    networking.firewall.extraCommands = ''
      iptables -t raw -A OUTPUT -p udp -m udp --dport 137 -j CT --helper netbios-ns
    '';
  };
}
