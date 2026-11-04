---
name: converting-with-nixos-infect
description: Use when converting an existing Linux server to NixOS with nixos-infect, including preflight, first boot, and recovery.
---

# Converting with nixos-infect

`nixos-infect` replaces the existing root filesystem and can leave the machine unbootable or unreachable. Treat the first NixOS boot as an irreversible migration, not a routine reboot.

## Preflight

1. Confirm the intended host, authorization to replace its OS, acceptable data loss, and a working provider console **and** rescue or reinstall path. Back up anything needed; a VNC console alone does not repair every boot failure.
2. Inspect the current upstream README, script, and relevant issues; pin and review a specific script revision rather than executing a moving URL. Check its provider detection and actual behavior. Record the revision without publishing host-specific secrets.
3. Inventory the boot mode, boot disk and partition table, root and separate filesystems, free disk and RAM, `/tmp` capacity, swap, SSH port and authorized root key, host keys, interface names and MACs, addresses and prefixes, routes including gateway reachability, DNS, and IPv6. Preserve these facts privately. Check the target kernel and filesystem tools support the existing filesystem features.
4. Select an available NixOS release and inspect its installation documentation. For 26.05, lustration requires `boot.initrd.systemd.enable = false`; it is deprecated and scheduled for removal with `NIXOS_LUSTRATE` in 26.11. Do not assume that workaround applies to later releases or future script revisions. See [upstream issue 276](https://github.com/elitak/nixos-infect/issues/276) and the [NixOS manual](https://nixos.org/manual/nixos/stable/#sec-installing-from-other-distro).
5. Design the initial configuration from the observed host, not from another provider. Preserve working SSH access and the boot disk. Explicitly handle interface naming, IPv4 and IPv6 addresses, routes and DNS; for an off-subnet `/32` gateway, verify its host route and an interface-qualified default gateway. `doNetConf=y` is a generator, not proof: inspect its output for missing gateways, unsuitable DNS, link-local addresses and naming assumptions. See [upstream issue 271](https://github.com/elitak/nixos-infect/issues/271).

## Stage and inspect

1. Ensure the installer has sufficient disk-backed temporary space and swap. The script may create a 1 GiB swapfile under `/tmp` and call `swapoff -a`; a smaller tmpfs can fill before installation starts. If providing swap yourself, understand and explicitly control the script's `NO_SWAP` behavior and avoid disrupting unrelated swap.
2. Run the reviewed revision in a durable session, with the selected channel and host-specific configuration. Disable automatic reboot with `NO_REBOOT=1`. Protect logs and configuration; do not use shell tracing when it could expose credentials, keys or network secrets.
3. Wait for a successful exit; on failure inspect the error and actual disk, swap, configuration and bootloader state before any retry. The script is not necessarily safe to rerun after partial installation. Never reboot simply because a system profile exists.
4. Before reboot, verify the evaluated NixOS configuration against the live machine: root filesystem, GRUB/EFI target, SSH service and authorized key, interface naming, addresses, gateway routes and DNS. Verify the staged initrd itself contains the required lustration logic, not just that the configuration sets an option. Check the lustration marker, staged system profile and bootloader entry. Resolve discrepancies before proceeding.

## First boot and recovery

Reboot only after the checks pass. Reconnect using the preserved host key and verify `/etc/os-release`, the running system generation and kernel, consumed lustration marker, SSH service, failed systemd units, root filesystem, default routes, DNS and external connectivity for each intended address family. An installer exit code or SSH alone is not proof that migration succeeded.

If boot or connectivity fails, stop retries and use the provider console and rescue procedure to inspect the disk and journal. Do not delete `/old-root`, credentials, swap, or recovery artifacts until the operator has verified the new system and explicitly approved cleanup. Report the actual state and any unverified checks.
