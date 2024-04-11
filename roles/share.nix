{ config, pkgs, lib, ... }:
with lib;

let 
  cfg = config.roles.share;
in {

  options.roles.share = {
    hostname = mkOption { type = types.str; };
    enable = mkEnableOption "Enable SMB share"; 
    enableTimeMachine = mkEnableOption "Enable TimeMachine on SMB";
  };

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [ samba ];

    services.samba = {
      enable = true;
      securityType = "user";
      openFirewall = true;
      extraConfig = ''
        workgroup = WORKGROUP
        server string = ${cfg.hostname}
        netbios name = ${cfg.hostname}
        hosts allow = 192.168.0. 127.0.0.1 localhost
        hosts deny = 0.0.0.0/0
        client min protocol = NT1
        server min protocol = NT1
        guest account = nobody
      '';

      shares = {
        TimeMachine = mkIf cfg.enableTimeMachine {
          path = "/mnt/storage/TimeMachine";
          "valid users" = "o__ni";
          public = "no";
          writeable = "yes";
          "force user" = "o__ni";
          "fruit:aapl" = "yes";
          "fruit:time machine" = "yes";
          "vfs objects" = "catia fruit streams_xattr";
        };

        Public = {
          path = "/mnt/Shares/Public";
          browseable = "yes";
          "read only" = "no";
          "guest ok" = "yes";
          "create mask" = "0644";
          "directory mask" = "0755";
          "force user" = "nobody";
          "force group" = "nogroup";
        };

        Homes = {
          comment = "Home directories";
          path = "/mnt/storage/Homes";
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

    services.avahi = {
      enable = true;
      nssmdns = true; # deprecated, but new options doesn't work for me (wtf? idk)
      publish = {
        enable = true;
        userServices = true;
      };
      extraServiceFiles = {
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
    };

    networking.firewall.extraCommands = ''iptables -t raw -A OUTPUT -p udp -m udp --dport 137 -j CT --helper netbios-ns'';
  };
}