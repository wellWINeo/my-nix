# Migrating mokosh to DigitalOcean via nixos-infect

## Prerequisites

- DigitalOcean account
- SSH key added to DO
- GPG key available to decrypt secrets
- Branch `feat/mokosh-do-image` checked out locally

---

## Step 1: Create the droplet

On DigitalOcean:
- **Image**: Ubuntu 22.04 x86_64
- **Size**: at least 1 CPU, 2 GB RAM (match current mokosh specs)
- **SSH key**: add your key so you can log in as root
- Note the droplet IP

---

## Step 2: Run nixos-infect

```bash
ssh root@<droplet-ip>

curl https://raw.githubusercontent.com/elitak/nixos-infect/master/nixos-infect | \
  NIX_CHANNEL=nixos-25.11 bash -x 2>&1 | tee /tmp/infect.log
```

Takes ~5–10 min. Reboots automatically into NixOS when done.

---

## Step 3: Fix disk layout after reboot

The mokosh config expects `/dev/disk/by-label/NIXOS` — relabel the root partition:

```bash
ssh root@<droplet-ip>

lsblk -f  # find root device, usually /dev/vda1

ROOT_DEV=$(findmnt -n -o SOURCE /)
e2label $ROOT_DEV NIXOS
```

DO droplets have no swap partition — create a swapfile:

```bash
fallocate -l 1G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
```

---

## Step 4: Update mokosh config for swapfile

On your Mac, edit `machines/mokosh/default.nix` on the branch.

Replace:
```nix
swapDevices = [ { device = "/dev/disk/by-label/SWAP"; } ];
```

With:
```nix
swapDevices = [ { device = "/swapfile"; } ];
```

Commit and push:
```bash
git add machines/mokosh/default.nix
git commit -m "fix(mokosh): use swapfile instead of swap partition for DO"
git push
```

---

## Step 5: Set up the flake on the droplet

```bash
ssh root@<droplet-ip>

nix-env -iA nixos.git
git clone https://github.com/wellWINeo/my-nix /root/my-nix
cd /root/my-nix
git checkout feat/mokosh-do-image
```

---

## Step 6: Transfer secrets

On your Mac — copy encrypted secrets to the droplet:
```bash
scp secrets/secrets.json.gpg secrets/locked.tar.gpg root@<droplet-ip>:/root/my-nix/secrets/
```

Transfer your GPG key:
```bash
gpg --export-secret-keys <key-id> | ssh root@<droplet-ip> 'gpg --import'
```

On the droplet, unlock secrets:
```bash
cd /root/my-nix && make unlock
```

---

## Step 7: Switch to mokosh config

```bash
cd /root/my-nix
hostnamectl set-hostname mokosh
nixos-rebuild switch --flake 'path:.#mokosh'
```

> **Networking note**: the switch sets `networking.useDHCP = false` and hands
> networking to the DO metadata services. If SSH drops during the switch, wait
> 60 seconds and reconnect — the DO metadata service should bring the interface
> back up. If it doesn't, use the DO web console to recover.

---

## Step 8: Verify services

```bash
systemctl status nginx postfix dovecot2 vaultwarden
```

---

## Step 9: Cutover and cleanup

1. Update DNS A records to point at the new droplet IP
2. Wait for TTL to propagate
3. Merge `feat/mokosh-do-image` to `main`
4. Decommission the old VPS
