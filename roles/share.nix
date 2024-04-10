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
        WORKGROUP = WORKGROUP
        server string = ${cfg.hostname}
        netbios name = ${cfg.hostname}
      '';

      shares = {
        TimeMachine = mkIf cfg.enableTimeMachine {
          "vfs objects" = "catia fruit streams_xattr";
          "fruit:time machine" = "yes";
          "fruit:time machine max size" = "1024G";
          comment = "Time Machine Backup";
          path = "/mnt/storage/TimeMachine";
          available = "yes";
          "valid users" = "o__ni";
          browseable = "yes";
          "guest ok" = "no";
          writable = "yes";
        };

        Public = {
          path = "/mnt/Shares/Public";
          browseable = "yes";
          "read only" = "no";
          "guest ok" = "yes";
          "create mask" = "0644";
          "directory mask" = "0755";
        };

        Homes = {
          comment = "Home directories";
          "valid users" = "%S";
          browseable = "yes";
          writable = "yes";
          "create mask" = "0644";
          "directory mask" = "0755";
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
      nssmdns4 = true;
      nssmdns6 = false;
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
              <txt-record>dk0=adVN=timemachine,adVF=0x82</txt-record>
              <txt-record>sys=waMa=0,adVF=0x100</txt-record>
            </service>
          </service-group>
        '';
      };
    };
  };
}