#!/usr/bin/env bash
# Proxy VPS provisioning entry point (nixos-anywhere wrapper).
#
# Invoked via `make provision HOST=<host> IP=<target-ipv4>`, which runs
# `nix develop .#provision -c ./provision/install.sh`. HOST and IP are read
# from the environment (make exports command-line variables); they are never
# interpolated into the Makefile recipe. Recovery mode is run directly:
#   HOST=<host> IP=<ip> nix develop .#provision -c ./provision/install.sh --resume-install
#
# Orchestration (guarded, fail-fast before any destructive action):
#   1. Local preflight: secrets/secrets.json present and JSON-shaped,
#      secrets/unlocked/spec.txt present, every required unlocked file
#      present, non-empty filtered Xray user list, and the Disko target disk
#      evaluated from the flake.
#   2. ISO trust gate: the operator supplies the live ISO's ED25519 host-key
#      fingerprint (EXPECTED_FINGERPRINT or interactive prompt) as read via
#      the provider console; the scanned key must match exactly and is pinned
#      into a temporary known_hosts used with StrictHostKeyChecking=yes by
#      every direct SSH call below.
#   3. Live-ISO hardware preflight: BIOS boot (UEFI refuses), whole disk,
#      minimum size (16 GiB buyan, 8 GiB veles/stribog; both leave room for
#      the 2 GiB swapfile).
#   4. Typed hostname and disk-path confirmations immediately before Disko.
#   5. Secrets staged via stage_secrets into a dedicated mktemp dir; one
#      temporary ED25519 installer key bootstrapped to root on the ISO
#      (password-typed append to authorized_keys, then key verification).
#   6. Phase A: nixos-anywhere --phases disko; then /mnt verification and a
#      2 GiB /mnt/.swapfile (0600, mkswap, swapon) over SSH.
#   7. Phase B: nixos-anywhere --phases install,reboot --extra-files
#      <staged dir>. A phase B failure never re-runs Disko; recovery prints
#      provider-console and --resume-install instructions.
#   8. Informational post-reboot SSH check as o__ni (never fails the run; a
#      changed host key is reported for manual verification).
#
# Host-key-checking limitation (documented in
# docs/superpowers/specs/2026-10-03-proxy-vps-provisioning-design.md):
# nixos-anywhere itself sets StrictHostKeyChecking=no and
# UserKnownHostsFile=/dev/null for its own SSH connections. The wrapper
# cannot enforce per-connection checking inside nixos-anywhere; the
# fingerprint gate above protects the operator's decision before any
# destructive work.
#
# Secrets are never printed and tracing (set -x) is never enabled.
#
# Test seams (used only by provision/tests/test-install.sh):
#   PROVISION_REPO_ROOT  overrides the repo root anchor
#   EXPECTED_FINGERPRINT supplies the expected ISO host-key fingerprint
#   (an empty EXPECTED_FINGERPRINT forces the interactive prompt)

set -euo pipefail

# Repo root, resolved from this script's location (not $PWD) so secret paths
# work both via `make provision` and when the script is invoked directly from
# any directory. Tests point PROVISION_REPO_ROOT at a fixture tree so the
# suite never reads the real secrets/ directory.
REPO_ROOT="${PROVISION_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

SUPPORTED_HOSTS=(buyan veles stribog)

# Orchestrator state, populated by run_provision and cleaned up by
# provision_cleanup (EXIT trap). INSTALLER_KEY_DIR holds the one temporary
# ED25519 installer key, its public half, and the pinned known_hosts file.
INSTALLER_KEY_DIR=""
STAGE_DIR=""
KEY_PATH=""
KNOWN_HOSTS_FILE=""
TARGET_DISK=""
MIN_DISK_BYTES=0
SSH_OPTS=()

usage() {
	echo "usage: make provision HOST=<buyan|veles|stribog> IP=<target-ipv4>" >&2
	echo "       HOST=<host> IP=<ip> nix develop .#provision -c ./provision/install.sh --resume-install" >&2
}

is_supported_host() {
	local candidate="$1"
	local allowed
	for allowed in "${SUPPORTED_HOSTS[@]}"; do
		if [[ "$candidate" == "$allowed" ]]; then
			return 0
		fi
	done
	return 1
}

is_valid_ipv4() {
	local candidate="$1"
	if [[ ! "$candidate" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
		return 1
	fi
	local octet
	local IFS=.
	for octet in $candidate; do
		if ((10#$octet > 255)); then
			return 1
		fi
	done
	return 0
}

# Validate HOST/IP before any remote or Nix action. Fails with a usage
# message and nonzero exit when either variable is missing or malformed.
require_env() {
	local host="${HOST:-}"
	local ip="${IP:-}"

	if [[ -z "$host" ]]; then
		echo "provision: HOST is required" >&2
		usage
		return 1
	fi
	if ! is_supported_host "$host"; then
		echo "provision: unsupported HOST '$host' (supported: ${SUPPORTED_HOSTS[*]})" >&2
		usage
		return 1
	fi
	if [[ -z "$ip" ]]; then
		echo "provision: IP is required for HOST '$host'" >&2
		usage
		return 1
	fi
	if ! is_valid_ipv4 "$ip"; then
		echo "provision: IP '$ip' is not a valid IPv4 address" >&2
		usage
		return 1
	fi
}

# Print the space-separated list of secret file names host requires.
# Returns 1 for hosts with no known secret set.
required_secrets() {
	local host="$1"
	case "$host" in
	buyan | stribog)
		echo "xray-reality-private-key tailscale-auth-key"
		;;
	veles)
		echo "xray-reality-private-key tailscale-auth-key hysteria-veles-key hysteria-veles-cert"
		;;
	*)
		return 1
		;;
	esac
}

# Stage exactly the secrets host requires from source_dir into
# target_dir/etc/nixos/secrets, honoring spec_path rows of the form
# "host:filename:perm:owner:group" (exact host row preferred over "*").
#
# Check-then-copy: every check below runs before anything is created under
# target_dir, so a rejected spec can never leave a partial staging tree:
#   - exactly one matching row per required name (conflicting duplicates fail)
#   - no path traversal in selected filenames (no "/" or "..")
#   - every selected row owned exactly root:root (proxy hosts run as root;
#     nixos-anywhere's root-owned copy would silently drop other ownership)
#   - each required source file exists under source_dir
# Modes come from the spec via `install -m`; the tree is created with umask
# 077. File contents are never printed and tracing (set -x) is never used.
# A failure during the copy phase removes the partially created tree.
stage_secrets() {
	local host="$1"
	local source_dir="$2"
	local spec_path="$3"
	local target_dir="$4"

	local required_raw
	if ! required_raw=$(required_secrets "$host"); then
		echo "provision: no known secret set for host '$host'" >&2
		return 1
	fi
	local -a required
	read -r -a required <<< "$required_raw"

	if [[ ! -f "$spec_path" ]]; then
		echo "provision: spec file not found: $spec_path" >&2
		return 1
	fi

	local name row row_host
	local -a fields exact wild pool sel chosen_file=() chosen_perm=()

	# Pass 1: select and validate rows for the required names.
	# Nothing is created under target_dir in this phase.
	for name in "${required[@]}"; do
		exact=()
		wild=()
		while IFS= read -r row || [[ -n "$row" ]]; do
			[[ -z "$row" || "$row" == \#* ]] && continue
			row_host="${row%%:*}"
			if [[ "$row_host" != "$host" && "$row_host" != "*" ]]; then
				continue
			fi
			IFS=: read -r -a fields <<< "$row"
			if ((${#fields[@]} != 5)); then
				echo "provision: malformed spec row for '$row_host': $row" >&2
				return 1
			fi
			if [[ "${fields[1]}" != "$name" ]]; then
				continue
			fi
			if [[ "$row_host" == "$host" ]]; then
				exact+=("$row")
			else
				wild+=("$row")
			fi
		done < "$spec_path"

		# Exact host row preferred over the wildcard when both exist. The
		# ${arr[@]+...} guards keep the empty-pool expansion from aborting with
		# "unbound variable" under set -u on bash <= 4.3 (e.g. /bin/bash 3.2).
		pool=()
		if ((${#exact[@]} > 0)); then
			pool=("${exact[@]+"${exact[@]}"}")
		else
			pool=("${wild[@]+"${wild[@]}"}")
		fi
		if ((${#pool[@]} == 0)); then
			echo "provision: no spec entry for required secret '$name' (host '$host' or '*')" >&2
			return 1
		fi

		# Conflicting duplicate rows for the same (host, filename) are fatal;
		# byte-identical rows are deduplicated.
		local first="${pool[0]}" other
		for other in "${pool[@]:1}"; do
			if [[ "$other" != "$first" ]]; then
				echo "provision: conflicting duplicate spec rows for $host:$name" >&2
				return 1
			fi
		done

		IFS=: read -r -a sel <<< "$first"
		local sel_file="${sel[1]}" sel_perm="${sel[2]}" sel_owner="${sel[3]}" sel_group="${sel[4]}"

		if [[ "$sel_file" == */* || "$sel_file" == *..* ]]; then
			echo "provision: path traversal in spec filename '$sel_file' rejected" >&2
			return 1
		fi
		if [[ "$sel_owner" != "root" || "$sel_group" != "root" ]]; then
			echo "provision: refusing to stage '$name' owned '$sel_owner:$sel_group' (must be root:root)" >&2
			return 1
		fi
		if [[ ! -f "$source_dir/$sel_file" ]]; then
			echo "provision: required secret file missing: $source_dir/$sel_file" >&2
			return 1
		fi

		chosen_file+=("$sel_file")
		chosen_perm+=("$sel_perm")
	done

	# Pass 2: all checks passed; create the staging tree and copy.
	local staged_dir="$target_dir/etc/nixos/secrets"
	if ! (
		umask 077
		mkdir -p "$staged_dir" || exit 1
		i=0
		f=''
		while ((i < ${#chosen_file[@]})); do
			f="${chosen_file[$i]}"
			echo "provision: staging $f (mode ${chosen_perm[$i]})" >&2
			install -m "${chosen_perm[$i]}" "$source_dir/$f" "$staged_dir/$f" || exit 1
			i=$((i + 1))
		done
	); then
		rm -rf "$target_dir/etc"
		echo "provision: staging failed; removed partial tree under $target_dir/etc" >&2
		return 1
	fi

	echo "provision: staged ${#chosen_file[@]} secret file(s) for '$host' into $staged_dir" >&2
}

# ---------------------------------------------------------------------------
# Task 5: guarded orchestration.
# ---------------------------------------------------------------------------

# Minimal pure-bash JSON sanity check for secrets/secrets.json (jq and
# python3 are not guaranteed in the provision shell): non-empty, starts and
# ends with an object brace, and braces and brackets balanced outside string
# literals. Deliberately NOT a full JSON parser — the flake evaluation itself
# is the authoritative parse; this check only catches gross corruption before
# any destructive work.
json_sanity_ok() {
	local file="$1"
	[[ -f "$file" && -s "$file" ]] || return 1
	local data
	data="$(cat "$file")" || return 1
	data="${data#"${data%%[![:space:]]*}"}"
	data="${data%"${data##*[![:space:]]}"}"
	[[ "$data" == \{* ]] || return 1
	[[ "$data" == *\} ]] || return 1
	local i=0 len in_str=0 depth=0 c
	len=${#data}
	while [[ "$i" -lt "$len" ]]; do
		c="${data:$i:1}"
		if [[ "$in_str" == 1 ]]; then
			if [[ "$c" == "\\" ]]; then
				i=$((i + 1))
			elif [[ "$c" == '"' ]]; then
				in_str=0
			fi
		else
			if [[ "$c" == '"' ]]; then
				in_str=1
			elif [[ "$c" == "{" || "$c" == "[" ]]; then
				depth=$((depth + 1))
			elif [[ "$c" == "}" || "$c" == "]" ]]; then
				depth=$((depth - 1))
				if [[ "$depth" -lt 0 ]]; then
					return 1
				fi
			fi
		fi
		i=$((i + 1))
	done
	[[ "$in_str" == 0 && "$depth" == 0 ]]
}

# Evaluate the Disko target disk device for a host from the local flake.
# Pure local evaluation; no network, no builds.
nix_eval_target_disk() {
	local host="$1"
	nix eval --raw "path:$REPO_ROOT#nixosConfigurations.$host.config.disko.devices.disk.main.device" 2>/dev/null
}

# Evaluate the number of filtered Xray server users for a host. Installing a
# proxy host whose hostname filter leaves zero users would produce an
# unreachable machine, so run_provision refuses to continue on 0 (all hosts).
nix_eval_xray_user_count() {
	local host="$1"
	nix eval --json "path:$REPO_ROOT#nixosConfigurations.$host.config.roles.xray.server.users" --apply 'builtins.length' 2>/dev/null
}

# Local, non-remote preflight. Fails fast (before fingerprint scan, SSH, or
# any destructive action) unless every local precondition holds. Sets
# TARGET_DISK and MIN_DISK_BYTES.
preflight_local() {
	local host="$1"
	local secrets_json="$REPO_ROOT/secrets/secrets.json"
	local unlocked="$REPO_ROOT/secrets/unlocked"

	if [[ ! -f "$secrets_json" ]]; then
		echo "provision: $secrets_json not found; decrypt secrets first (make unlock) — flake evaluation needs it" >&2
		return 1
	fi
	if ! json_sanity_ok "$secrets_json"; then
		echo "provision: $secrets_json does not look like a JSON object; refusing to continue" >&2
		return 1
	fi
	if [[ ! -f "$unlocked/spec.txt" ]]; then
		echo "provision: $unlocked/spec.txt not found; it is required for staging" >&2
		return 1
	fi
	local raw f
	if ! raw="$(required_secrets "$host")"; then
		echo "provision: no known secret set for host '$host'" >&2
		return 1
	fi
	for f in $raw; do
		if [[ ! -f "$unlocked/$f" ]]; then
			echo "provision: required secret file missing: $unlocked/$f (decrypt secrets first: make unlock)" >&2
			return 1
		fi
	done

	local users
	if ! users="$(nix_eval_xray_user_count "$host")"; then
		echo "provision: could not evaluate roles.xray.server.users for '$host' (flake error?)" >&2
		return 1
	fi
	if [[ ! "$users" =~ ^[0-9]+$ ]] || [[ "$users" -eq 0 ]]; then
		echo "provision: '$host' has no Xray server users after hostname filtering; refusing to install an unreachable host" >&2
		return 1
	fi

	if ! TARGET_DISK="$(nix_eval_target_disk "$host")"; then
		echo "provision: could not evaluate config.disko.devices.disk.main.device for '$host' (flake error?)" >&2
		return 1
	fi
	if [[ -z "$TARGET_DISK" ]]; then
		echo "provision: evaluated target disk for '$host' is empty" >&2
		return 1
	fi
	# 16 GiB for buyan (8 GiB root + /nix remainder + 2 GiB swapfile),
	# 8 GiB for veles/stribog (root remainder + 2 GiB swapfile).
	if [[ "$host" == "buyan" ]]; then
		MIN_DISK_BYTES=17179869184
	else
		MIN_DISK_BYTES=8589934592
	fi
	echo "provision: local preflight OK for '$host' (target disk $TARGET_DISK)" >&2
}

# ISO trust gate. Scan the live ISO's ED25519 host key, compare its SHA256
# fingerprint with the operator-supplied value (EXPECTED_FINGERPRINT or an
# interactive prompt fed from the provider console), and refuse on any
# mismatch. On success the scanned key is pinned into KNOWN_HOSTS_FILE so
# every subsequent direct SSH call can use StrictHostKeyChecking=yes.
# nixos-anywhere's own SSH connections still bypass host-key checking (see
# header comment); this gate protects the operator's decision, not every
# connection.
verify_iso_fingerprint() {
	local ip="$1"
	local scan_raw scan_fpr actual expected
	if ! scan_raw="$(ssh-keyscan -t ed25519 -T 10 "$ip" 2>/dev/null)" || [[ -z "$scan_raw" ]]; then
		echo "provision: could not scan the SSH host key of $ip (ISO unreachable?)" >&2
		return 1
	fi
	scan_fpr="$(printf '%s\n' "$scan_raw" | ssh-keygen -lf - 2>/dev/null | awk 'NR==1{print $2}')"
	if [[ ! "$scan_fpr" == SHA256:* ]]; then
		echo "provision: could not derive the ED25519 fingerprint of $ip from the scan" >&2
		return 1
	fi
	actual="$scan_fpr"
	if [[ -z "${EXPECTED_FINGERPRINT:-}" ]]; then
		local typed
		printf 'provision: type the ISO ED25519 host-key fingerprint from the provider console (SHA256:...): ' >&2
		if ! read -r typed; then
			echo >&2
			echo "provision: no fingerprint entered; aborting" >&2
			return 1
		fi
		EXPECTED_FINGERPRINT="$typed"
	fi
	expected="${EXPECTED_FINGERPRINT%"${EXPECTED_FINGERPRINT##*[![:space:]]}"}"
	expected="${expected#"${expected%%[![:space:]]*}"}"
	if [[ "$actual" != "$expected" ]]; then
		echo "provision: FINGERPRINT MISMATCH for $ip" >&2
		echo "  scanned:  $actual" >&2
		echo "  expected: $expected" >&2
		echo "  refusing to continue: verify the key in the provider console." >&2
		return 1
	fi
	printf '%s\n' "$scan_raw" >"$KNOWN_HOSTS_FILE" || return 1
	echo "provision: ISO host-key fingerprint verified and pinned: $actual" >&2
}

# Live-ISO hardware preflight over the pinned SSH connection: must be booted
# in BIOS mode (UEFI refuses; all three hosts install BIOS/GRUB), and the
# evaluated Disko device must exist as a whole disk with enough capacity for
# the layout plus the 2 GiB swapfile. Displays path, size, and partition
# table before the operator confirms the wipe.
remote_hardware_preflight() {
	local host="$1" ip="$2" disk="$3" min_bytes="$4"
	local out firmware tree first name dtype size
	if ! out="$(ssh "${SSH_OPTS[@]}" "nixos@$ip" "if [ -d /sys/firmware/efi ]; then echo FIRMWARE=UEFI; else echo FIRMWARE=BIOS; fi; lsblk -b -n -o NAME,TYPE,SIZE \"$disk\"" 2>&1)"; then
		echo "provision: cannot reach the live ISO as nixos@$ip (network up? password set?)" >&2
		echo "  ssh said: $out" >&2
		return 1
	fi
	firmware="$(printf '%s\n' "$out" | sed -n 's/^FIRMWARE=//p' | head -n 1)"
	tree="$(printf '%s\n' "$out" | grep -v '^FIRMWARE=' || true)"
	if [[ "$firmware" == "UEFI" ]]; then
		echo "provision: live ISO is booted in UEFI mode; this installer only supports BIOS/GRUB hosts." >&2
		echo "  Boot the ISO in BIOS/Legacy mode and start over." >&2
		return 1
	fi
	if [[ "$firmware" != "BIOS" ]]; then
		echo "provision: could not determine BIOS/UEFI mode on the live ISO" >&2
		return 1
	fi
	first="$(printf '%s\n' "$tree" | head -n 1)"
	name=""
	dtype=""
	size=""
	read -r name dtype size _ <<<"$first" || true
	if [[ -z "$first" || -z "$dtype" ]]; then
		echo "provision: lsblk returned no information for $disk on the live ISO; the target disk does not exist" >&2
		return 1
	fi
	if [[ "$dtype" != "disk" ]]; then
		echo "provision: $disk is not a whole disk (lsblk type '$dtype'); refusing to continue" >&2
		return 1
	fi
	if [[ ! "$size" =~ ^[0-9]+$ ]]; then
		echo "provision: could not parse the size of $disk from lsblk output" >&2
		return 1
	fi
	if [[ "$size" -lt "$min_bytes" ]]; then
		echo "provision: $disk is only $((size / 1073741824)) GiB; minimum for '$host' is $((min_bytes / 1073741824)) GiB (layout + 2 GiB swapfile)." >&2
		echo "  Refusing to install rather than guessing partition sizes." >&2
		return 1
	fi
	echo "provision: live ISO check OK: BIOS boot, $disk is a whole $((size / 1073741824)) GiB disk:" >&2
	printf '%s\n' "$tree" | sed 's/^/    /' >&2
}

# Typed confirmation: the operator must retype the exact value (hostname or
# disk path). Any mismatch aborts before destructive work.
confirm_typed() {
	local label="$1" expected="$2" typed
	printf 'provision: type the exact %s to continue (%s): ' "$label" "$expected" >&2
	if ! read -r typed; then
		echo >&2
		echo "provision: no confirmation typed; aborting" >&2
		return 1
	fi
	if [[ "$typed" != "$expected" ]]; then
		echo "provision: confirmation mismatch for $label: typed '$typed', expected '$expected'; aborting" >&2
		return 1
	fi
}

# Stage the host's secrets via stage_secrets into a DEDICATED mktemp dir
# (never shared: a staging failure rm -rf's the target's etc/ subtree).
# Removed by the EXIT trap. Contents are never printed.
stage_install_secrets() {
	local host="$1"
	STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/provision-stage.XXXXXX")" || return 1
	stage_secrets "$host" "$REPO_ROOT/secrets/unlocked" "$REPO_ROOT/secrets/unlocked/spec.txt" "$STAGE_DIR" || return 1
}

# Generate the ONE temporary ED25519 installer key (mode 0600 via umask 077)
# inside INSTALLER_KEY_DIR, append its public half to root's authorized_keys
# on the live ISO via sudo tee -a (never overwriting existing keys), and
# verify root login with the new key. The ISO password is typed interactively
# at the SSH prompt. The installer is never invoked if verification fails.
bootstrap_installer_key() {
	local ip="$1"
	if ! (
		umask 077
		ssh-keygen -t ed25519 -N "" -f "$KEY_PATH" -q
	); then
		echo "provision: could not generate the temporary installer key" >&2
		return 1
	fi
	echo "provision: bootstrapping installer key on the ISO (type the 'nixos' SSH password when prompted)" >&2
	if ! ssh "${SSH_OPTS[@]}" "nixos@$ip" \
		"sudo mkdir -p /root/.ssh && sudo chmod 700 /root/.ssh && sudo tee -a /root/.ssh/authorized_keys > /dev/null && sudo chmod 600 /root/.ssh/authorized_keys" \
		<"$KEY_PATH.pub"; then
		echo "provision: could not install the installer public key on the ISO (wrong password?)" >&2
		return 1
	fi
	if ! ssh "${SSH_OPTS[@]}" -i "$KEY_PATH" -o IdentitiesOnly=yes "root@$ip" true; then
		echo "provision: root key verification failed on $ip; refusing to run the installer" >&2
		return 1
	fi
	echo "provision: root login with the installer key verified" >&2
}

# Phase A: Disko partitioning. Destructive; on failure do NOT retry, print
# inspection and recovery instructions instead.
run_disko_phase() {
	local host="$1" ip="$2" key="$3"
	echo "provision: PHASE A: Disko partitioning of $TARGET_DISK (DESTRUCTIVE)" >&2
	if ! nixos-anywhere -i "$key" --build-on remote --flake "path:$REPO_ROOT#$host" --target-host "root@$ip" --phases disko; then
		cat >&2 <<EOF
provision: Disko phase FAILED.
  The target disk may be partially partitioned. Do NOT blindly retry:
  - inspect the live ISO over SSH or the provider console (lsblk, mount,
    journalctl) before doing anything else
  - re-running normal provision will wipe the disk again (explicit decision)
  - if Disko actually completed, resume WITHOUT repartitioning:
      HOST=$host IP=$ip nix develop .#provision -c ./provision/install.sh --resume-install
EOF
		return 1
	fi
}

# Post-Disko check over SSH: disko only partitions, formats, and mounts the
# target — /etc/NIXOS and a populated /nix/store are products of the INSTALL
# phase, not of disko. The Disko-shaped state to require here is: /mnt is a
# mountpoint carrying the NIXROOT label, and for buyan (8 GiB root +
# NIXSTORE on /nix) additionally the /mnt/nix mount.
verify_mnt_root() {
	local host="$1" ip="$2" key="$3"
	local extra=""
	local cmd='mountpoint -q /mnt && [ "$(findmnt -n -o LABEL /mnt 2>/dev/null)" = "NIXROOT" ]'
	if [[ "$host" == "buyan" ]]; then
		cmd="$cmd && mountpoint -q /mnt/nix"
		extra=" (or /mnt/nix is not mounted)"
	fi
	if ! ssh "${SSH_OPTS[@]}" -i "$key" -o IdentitiesOnly=yes "root@$ip" "$cmd"; then
		echo "provision: post-Disko /mnt check failed: /mnt is not mounted, or its label is not NIXROOT$extra." >&2
		echo "  Inspect the ISO (mount, lsblk, findmnt) via the provider console before retrying." >&2
		return 1
	fi
}

# Create (or reuse) the 2 GiB /mnt/.swapfile on the mounted target root and
# activate it for the remote build. Already-active swap is tolerated.
activate_target_swap() {
	local ip="$1" key="$2"
	echo "provision: ensuring 2 GiB /mnt/.swapfile on the target root" >&2
	if ! ssh "${SSH_OPTS[@]}" -i "$key" -o IdentitiesOnly=yes "root@$ip" \
		"if [ ! -f /mnt/.swapfile ]; then fallocate -l 2G /mnt/.swapfile && chmod 0600 /mnt/.swapfile; fi; mkswap /mnt/.swapfile && { swapon /mnt/.swapfile || grep -q '/mnt/.swapfile' /proc/swaps; }"; then
		echo "provision: swapfile setup failed; fix it via the provider console, then resume with --resume-install" >&2
		return 1
	fi
}

# Phase B: install + reboot with the staged secret tree. NEVER re-runs
# Disko (already done in phase A); a failure prints recovery instructions.
run_install_phase() {
	local host="$1" ip="$2" key="$3" stage_dir="$4"
	echo "provision: PHASE B: install + reboot (--extra-files staging dir)" >&2
	if ! nixos-anywhere -i "$key" --build-on remote --flake "path:$REPO_ROOT#$host" --target-host "root@$ip" --phases install,reboot --extra-files "$stage_dir"; then
		cat >&2 <<EOF
provision: install phase FAILED.
  Disko was NOT re-run and will not be: the disk is already partitioned.
  Inspect the still-running ISO via the provider console or SSH (mounts,
  nix store paths, build logs); when the problem is fixed, resume WITHOUT
  repartitioning:
      HOST=$host IP=$ip nix develop .#provision -c ./provision/install.sh --resume-install
  If ISO SSH is lost, use the provider console to reach the machine.
EOF
		return 1
	fi
}

# Recovery-mode state check: the live ISO must still be booted (its root is
# a tmpfs), the evaluated Disko disk must exist as a block device, and the
# target root must already be mounted at /mnt with the NIXROOT label (buyan
# additionally requires /mnt/nix). Install-phase markers (/etc/NIXOS, a
# populated /nix/store) are probed separately and reported informationally:
# resume must accept both a clean post-Disko /mnt (resume after a failed
# install/build phase) and a partially or fully installed /mnt. No
# repartitioning happens in this mode.
verify_resume_state() {
	local host="$1" ip="$2" key="$3" disk="$4"
	local cmd="mountpoint -q /mnt && test -b \"$disk\" && [ \"\$(findmnt -n -o LABEL /mnt 2>/dev/null)\" = \"NIXROOT\" ] && findmnt -n -o FSTYPE / | grep -q tmpfs"
	if [[ "$host" == "buyan" ]]; then
		cmd="$cmd && mountpoint -q /mnt/nix"
	fi
	echo "provision: resume check: verifying ISO boot state and /mnt on $ip" >&2
	if ! ssh "${SSH_OPTS[@]}" -i "$key" -o IdentitiesOnly=yes "root@$ip" "$cmd"; then
		echo "provision: resume check failed: the live ISO is not booted, /mnt is not mounted, or the mounted label is not NIXROOT." >&2
		echo "  Use the provider console to reach the ISO, re-mount the root (e.g." >&2
		echo "  mount /dev/disk/by-label/NIXROOT /mnt), or re-run normal provision to wipe" >&2
		echo "  the disk and start over (explicit destructive decision)." >&2
		return 1
	fi
	local markers
	markers="$(ssh "${SSH_OPTS[@]}" -i "$key" -o IdentitiesOnly=yes "root@$ip" \
		"if [ -e /mnt/etc/NIXOS ] || [ -d /mnt/nix/store ]; then echo installed; else echo clean; fi" 2>/dev/null || true)"
	if [[ "$markers" == *"installed"* ]]; then
		echo "provision: resume state: /mnt contains install markers (partially or fully installed) — continuing without repartitioning" >&2
	else
		echo "provision: resume state: /mnt is a clean post-Disko root (not yet installed) — continuing" >&2
	fi
}

# Informational post-reboot connectivity check as the operator user. Uses the
# operator's own SSH identities (BatchMode, no password prompts): the
# temporary installer key is NOT installed into the target system's
# authorized_keys. Host-key checking is NOT disabled: accept-new trusts only
# previously unseen keys, and a changed key is refused and reported below for
# manual verification. This check is connectivity-only and informational:
# it does NOT verify service state and never fails the overall run.
post_reboot_check() {
	local ip="$1"
	local out
	echo "provision: post-reboot check: attempting SSH as o__ni@$ip (informational)" >&2
	if out="$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "o__ni@$ip" true 2>&1)"; then
		echo "provision: post-reboot SSH as o__ni@$ip: OK" >&2
		return 0
	fi
	if printf '%s\n' "$out" | grep -qi 'host key'; then
		echo "provision: WARNING: SSH host key for $ip was rejected or has changed." >&2
		echo "  Verify the new key via the provider console and update known_hosts manually;" >&2
		echo "  do not blindly delete the old entry." >&2
	else
		echo "provision: post-reboot SSH as o__ni@$ip failed (host may still be rebooting):" >&2
		printf '%s\n' "$out" | sed 's/^/    /' >&2
		echo "  Informational only; verify connectivity and services manually once up." >&2
	fi
	return 0
}

# EXIT trap for run_provision: remove both temporary directories (staged
# secrets and installer key). Guards make it safe when nothing was created.
provision_cleanup() {
	if [[ -n "$STAGE_DIR" && -d "$STAGE_DIR" ]]; then
		rm -rf "$STAGE_DIR"
	fi
	if [[ -n "$INSTALLER_KEY_DIR" && -d "$INSTALLER_KEY_DIR" ]]; then
		rm -rf "$INSTALLER_KEY_DIR"
	fi
}

# Orchestration entry point: run_provision HOST IP [--resume-install].
# Order matters: every fail-fast gate runs before the first destructive
# action, and the typed confirmations run immediately before Disko.
run_provision() {
	if [[ $# -lt 2 ]]; then
		usage
		return 1
	fi
	local host="$1" ip="$2"
	shift 2
	local resume=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--resume-install)
			resume=1
			shift
			;;
		*)
			echo "provision: unknown flag '$1'" >&2
			usage
			return 1
			;;
		esac
	done

	INSTALLER_KEY_DIR=""
	STAGE_DIR=""
	KEY_PATH=""
	KNOWN_HOSTS_FILE=""
	TARGET_DISK=""
	trap provision_cleanup EXIT

	# Dedicated temp dir for the installer key + pinned known_hosts; the
	# staged-secrets dir is created separately by stage_install_secrets.
	INSTALLER_KEY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/provision-installer.XXXXXX")" || return 1
	chmod 700 "$INSTALLER_KEY_DIR"
	KEY_PATH="$INSTALLER_KEY_DIR/installer_ed25519"
	KNOWN_HOSTS_FILE="$INSTALLER_KEY_DIR/known_hosts"
	# All direct SSH calls verify against the scanned-and-operator-confirmed
	# host key (StrictHostKeyChecking=yes); see verify_iso_fingerprint.
	SSH_OPTS=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KNOWN_HOSTS_FILE" -o ConnectTimeout=15)

	preflight_local "$host" || return 1
	verify_iso_fingerprint "$ip" || return 1
	if [[ "$resume" == 0 ]]; then
		remote_hardware_preflight "$host" "$ip" "$TARGET_DISK" "$MIN_DISK_BYTES" || return 1
	fi

	stage_install_secrets "$host" || return 1
	bootstrap_installer_key "$ip" || return 1

	if [[ "$resume" == 1 ]]; then
		verify_resume_state "$host" "$ip" "$KEY_PATH" "$TARGET_DISK" || return 1
	else
		confirm_typed hostname "$host" || return 1
		confirm_typed "disk path" "$TARGET_DISK" || return 1
		run_disko_phase "$host" "$ip" "$KEY_PATH" || return 1
		verify_mnt_root "$host" "$ip" "$KEY_PATH" || return 1
	fi
	activate_target_swap "$ip" "$KEY_PATH" || return 1
	run_install_phase "$host" "$ip" "$KEY_PATH" "$STAGE_DIR" || return 1

	post_reboot_check "$ip"
	echo "provision: '$host' installed; connect with: ssh o__ni@$ip" >&2
}

main() {
	local -a forward_args=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--resume-install)
			forward_args+=("$1")
			shift
			;;
		-h | --help)
			usage
			return 0
			;;
		*)
			echo "provision: unknown argument '$1'" >&2
			usage
			return 1
			;;
		esac
	done
	require_env
	echo "provision: HOST='$HOST' IP='$IP' validated" >&2
	run_provision "$HOST" "$IP" "${forward_args[@]+"${forward_args[@]}"}"
}

# Source guard: sourcing this file (e.g. from tests) must not execute main.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
