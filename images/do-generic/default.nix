# Generic DigitalOcean-bootable NixOS profile.
#
# Scope: hardware/boot/network only. No users, tooling, or roles — those come
# from other modules (e.g. users/o__ni, common/server.nix). Importing this
# module exposes `system.build.digitalOceanImage` (a qcow2 builder) and wires
# the runtime bits a droplet needs: virtio drivers, growpart on the root
# partition, and cloud-init for networking from DO metadata.
#
# Constraint: root filesystem must be ext4 (autoResize uses online ext4 resize).

{ modulesPath, lib, ... }:

{
  imports = [
    "${modulesPath}/virtualisation/digital-ocean-image.nix"
  ];

  boot = {
    growPartition = true;

    initrd.availableKernelModules = [
      "virtio_pci"
      "virtio_scsi"
      "virtio_blk"
      "sd_mod"
    ];
  };

  networking = {
    useDHCP = false;
    hostName = lib.mkDefault "";
    # cloud-init's DigitalOcean datasource hardcodes "eth0"/"eth1" for
    # public/private interfaces (NIC_MAP). The networkd renderer emits
    # [Match] Name=eth0 MACAddress=..., which requires both to match.
    # Predictable names (ens3, enp0s...) break that match → no IP assigned.
    usePredictableInterfaceNames = false;
  };

  services.cloud-init = {
    enable = true;
    network.enable = true;
    settings = {
      datasource_list = [
        "DigitalOcean"
        "None"
      ];

      # Re-apply network config on every boot so the persisted
      # /etc/systemd/network/10-cloud-init-eth0.network is always current.
      # Default is boot-new-instance only, which is not enough for a droplet
      # that can be migrated or rebuilt with a new IP.
      updates.network.when = [ "boot" ];

      # NixOS only creates /etc/cloud/cloud.cfg — it does not install the
      # cloud.cfg.d/ drop-ins that ship inside the Python package, including
      # 05_logging.cfg. Without log_cfgs, cloud-init emits "no logging
      # configured" and records a recoverable error that can inflate the
      # cloud-final exit code.
      log_cfgs = [
        [
          ''
            [loggers]
            keys=root,cloudinit

            [handlers]
            keys=consoleHandler,cloudLogHandler

            [formatters]
            keys=simpleFormatter,arg0Formatter

            [logger_root]
            level=DEBUG
            handlers=consoleHandler,cloudLogHandler

            [logger_cloudinit]
            level=DEBUG
            qualname=cloudinit
            handlers=
            propagate=1

            [handler_consoleHandler]
            class=StreamHandler
            level=WARNING
            formatter=arg0Formatter
            args=(sys.stderr,)

            [formatter_arg0Formatter]
            format=%(asctime)s - %(filename)s[%(levelname)s]: %(message)s

            [formatter_simpleFormatter]
            format=[CLOUDINIT] %(filename)s[%(levelname)s]: %(message)s
          ''
          ''
            [handler_cloudLogHandler]
            class=FileHandler
            level=DEBUG
            formatter=arg0Formatter
            args=('/var/log/cloud-init.log', 'a', 'UTF-8')
          ''
        ]
      ];

      # rightscale_userdata was removed in cloud-init 24.1; keep the list
      # identical to the NixOS module default minus that entry.
      cloud_final_modules = [
        "scripts-vendor"
        "scripts-per-once"
        "scripts-per-boot"
        "scripts-per-instance"
        "scripts-user"
        "ssh-authkey-fingerprints"
        "keys-to-console"
        "phone-home"
        "final-message"
        "power-state-change"
      ];
    };
  };
}
