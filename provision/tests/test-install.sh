#!/usr/bin/env bash
# Regression tests for provision/install.sh: pure staging functions (Task 4)
# and the guarded nixos-anywhere orchestration (Task 5).
#
# Portable to macOS bash 3.2 (no bash4-only features, no GNU-only stat).
# Fixtures use dummy placeholder values only — never real credentials — and
# live in a mktemp -d tree removed by an EXIT trap.
#
# Runs the script's own functions by sourcing ../install.sh relative to this
# file's location; the source guard in install.sh keeps main() from running.
#
# Orchestration tests run run_provision in a CHILD subshell whose PATH is
# prepended with a shim directory of fake ssh / ssh-keyscan / ssh-keygen /
# nix / nixos-anywhere scripts. The fakes log every invocation ("$*" per
# line) to FAKE_SHIM_LOG and emit canned outputs; FAKE_* env vars select the
# scenario. No real network, disk, or system-wide stubbing is involved — the
# real PATH of the parent test process is never modified.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../install.sh
source "$TEST_DIR/../install.sh"

FIXTURE_DIR=""
SRC=""
SPEC=""
TARGET=""

pass=0
fail=0

cleanup() {
	if [[ -n "$FIXTURE_DIR" && -d "$FIXTURE_DIR" ]]; then
		rm -rf "$FIXTURE_DIR"
	fi
}
trap cleanup EXIT

# perm_of FILE — print permission bits in octal, BSD stat first (macOS),
# then GNU stat (Linux).
perm_of() {
	local mode
	if mode=$(stat -f '%Lp' "$1" 2>/dev/null); then
		printf '%s\n' "$mode"
	else
		stat -c '%a' "$1"
	fi
}

# new_fixture NAME — fresh dummy source dir, spec.txt, and empty target dir.
new_fixture() {
	local d="$FIXTURE_DIR/case-$1"
	mkdir -p "$d/src"
	SRC="$d/src"
	SPEC="$d/spec.txt"
	TARGET="$(mktemp -d "$d/target.XXXXXX")"

	cat > "$SPEC" <<'EOF'
# host:filename:perm:owner:group
*:shadowsocksPassword:0400:root:root
*:tailscale-auth-key:0400:root:root
stribog:xray-reality-private-key:0400:root:root
veles:xray-reality-private-key:0400:root:root
veles:hysteria-veles-key:0400:root:root
veles:hysteria-veles-cert:0400:root:root
veles:cloudflare.ini:0400:acme:acme
EOF

	echo "dummy-reality-key" > "$SRC/xray-reality-private-key"
	echo "dummy-tailscale-auth-key" > "$SRC/tailscale-auth-key"
	echo "dummy-shadowsocks-password" > "$SRC/shadowsocksPassword"
	echo "dummy-hysteria-key" > "$SRC/hysteria-veles-key"
	echo "dummy-hysteria-cert" > "$SRC/hysteria-veles-cert"
	echo "dummy-cloudflare-token" > "$SRC/cloudflare.ini"
}

# (1) Stribog staging copies exactly the two required files with mode 0400
#     as declared, and not the wildcard decoy shadowsocksPassword.
test_stribog_stages_exactly_required() {
	new_fixture stribog
	local secrets="$TARGET/etc/nixos/secrets"
	if ! stage_secrets stribog "$SRC" "$SPEC" "$TARGET" >/dev/null 2>&1; then
		echo "  stage_secrets stribog exited nonzero" >&2
		return 1
	fi
	if [[ ! -d "$secrets" ]]; then
		echo "  $secrets was not created" >&2
		return 1
	fi
	local count
	count=$(ls -A "$secrets" | wc -l | tr -d '[:space:]')
	if [[ "$count" != "2" ]]; then
		echo "  expected 2 staged files, found $count: $(ls -A "$secrets" | tr '\n' ' ')" >&2
		return 1
	fi
	if [[ ! -f "$secrets/xray-reality-private-key" ]]; then
		echo "  xray-reality-private-key not staged" >&2
		return 1
	fi
	if [[ ! -f "$secrets/tailscale-auth-key" ]]; then
		echo "  tailscale-auth-key not staged" >&2
		return 1
	fi
	if [[ -e "$secrets/shadowsocksPassword" ]]; then
		echo "  wildcard decoy shadowsocksPassword was staged" >&2
		return 1
	fi
	local f
	for f in xray-reality-private-key tailscale-auth-key; do
		if [[ "$(perm_of "$secrets/$f")" != "400" ]]; then
			echo "  $f mode is $(perm_of "$secrets/$f"), expected 400" >&2
			return 1
		fi
	done
	if [[ "$(perm_of "$secrets")" != "700" ]]; then
		echo "  secrets dir mode is $(perm_of "$secrets"), expected 700 (umask 077)" >&2
		return 1
	fi
	return 0
}

# (2) Missing required source file → nonzero exit AND no target_dir/etc tree.
test_missing_source_fails_without_partial_tree() {
	new_fixture missing
	rm "$SRC/xray-reality-private-key"
	if stage_secrets stribog "$SRC" "$SPEC" "$TARGET" >/dev/null 2>&1; then
		echo "  staging succeeded despite missing required source file" >&2
		return 1
	fi
	if [[ -e "$TARGET/etc" ]]; then
		echo "  target_dir/etc tree exists after validation failure (partial tree)" >&2
		return 1
	fi
	return 0
}

# (3) Veles staging selects the two hysteria files in addition to the common
#     pair and does NOT select cloudflare.ini.
test_veles_stages_hysteria_not_cloudflare() {
	new_fixture veles
	local secrets="$TARGET/etc/nixos/secrets"
	if ! stage_secrets veles "$SRC" "$SPEC" "$TARGET" >/dev/null 2>&1; then
		echo "  stage_secrets veles exited nonzero" >&2
		return 1
	fi
	local f
	for f in xray-reality-private-key tailscale-auth-key hysteria-veles-key hysteria-veles-cert; do
		if [[ ! -f "$secrets/$f" ]]; then
			echo "  veles: $f not staged" >&2
			return 1
		fi
	done
	if [[ -e "$secrets/cloudflare.ini" ]]; then
		echo "  veles: cloudflare.ini was staged but veles has no acme account" >&2
		return 1
	fi
	local count
	count=$(ls -A "$secrets" | wc -l | tr -d '[:space:]')
	if [[ "$count" != "4" ]]; then
		echo "  veles: expected 4 staged files, found $count: $(ls -A "$secrets" | tr '\n' ' ')" >&2
		return 1
	fi
	return 0
}

# (4) Selected filename with `../` traversal in the spec → rejected.
test_traversal_filename_rejected() {
	new_fixture traversal
	grep -v '^stribog:xray-reality-private-key:' "$SPEC" > "$FIXTURE_DIR/case-traversal/spec-bad.txt"
	echo 'stribog:../xray-reality-private-key:0400:root:root' >> "$FIXTURE_DIR/case-traversal/spec-bad.txt"
	local badspec="$FIXTURE_DIR/case-traversal/spec-bad.txt"
	if stage_secrets stribog "$SRC" "$badspec" "$TARGET" >/dev/null 2>&1; then
		echo "  traversal filename ../xray-reality-private-key was accepted" >&2
		return 1
	fi
	if [[ -e "$TARGET/etc" ]]; then
		echo "  target_dir/etc tree created despite traversal rejection" >&2
		return 1
	fi
	return 0
}

# (5) Conflicting duplicate rows for the same (host, filename) → rejected.
test_conflicting_duplicates_rejected() {
	new_fixture dupes
	cp "$SPEC" "$FIXTURE_DIR/case-dupes/spec-dupes.txt"
	echo 'stribog:xray-reality-private-key:0600:root:root' >> "$FIXTURE_DIR/case-dupes/spec-dupes.txt"
	local badspec="$FIXTURE_DIR/case-dupes/spec-dupes.txt"
	if stage_secrets stribog "$SRC" "$badspec" "$TARGET" >/dev/null 2>&1; then
		echo "  conflicting duplicate rows for stribog:xray-reality-private-key were accepted" >&2
		return 1
	fi
	if [[ -e "$TARGET/etc" ]]; then
		echo "  target_dir/etc tree created despite duplicate conflict" >&2
		return 1
	fi
	return 0
}

# (6) Non-root:root owner row → rejected before anything is copied.
test_non_root_owner_rejected() {
	new_fixture owner
	grep -v '^stribog:xray-reality-private-key:' "$SPEC" > "$FIXTURE_DIR/case-owner/spec-owner.txt"
	echo 'stribog:xray-reality-private-key:0400:acme:acme' >> "$FIXTURE_DIR/case-owner/spec-owner.txt"
	local badspec="$FIXTURE_DIR/case-owner/spec-owner.txt"
	if stage_secrets stribog "$SRC" "$badspec" "$TARGET" >/dev/null 2>&1; then
		echo "  non-root:root owner row (acme:acme) was accepted" >&2
		return 1
	fi
	if [[ -e "$TARGET/etc" ]]; then
		echo "  target_dir/etc tree created despite owner rejection" >&2
		return 1
	fi
	return 0
}

# (7) required_secrets returns 1 for an unknown host; known hosts get the
#     exact declared sets.
test_required_secrets_unknown_host_fails() {
	if required_secrets nosuchhost >/dev/null 2>&1; then
		echo "  required_secrets accepted unknown host 'nosuchhost'" >&2
		return 1
	fi
	local got
	got=$(required_secrets buyan)
	if [[ "$got" != "xray-reality-private-key tailscale-auth-key" ]]; then
		echo "  required_secrets buyan returned '$got'" >&2
		return 1
	fi
	got=$(required_secrets veles)
	if [[ "$got" != "xray-reality-private-key tailscale-auth-key hysteria-veles-key hysteria-veles-cert" ]]; then
		echo "  required_secrets veles returned '$got'" >&2
		return 1
	fi
	return 0
}

# (8) Required secret with no spec row at all (no host row, no wildcard) →
#     rejected with the intended "no spec entry" diagnostic and no target
#     tree. Pins the set -u-safe empty-pool handling on bash <= 4.3, where
#     the pre-fix code aborted with "wild[@]: unbound variable" instead.
test_missing_spec_entry_rejected() {
	new_fixture nospec
	grep -v '^stribog:xray-reality-private-key:' "$SPEC" > "$FIXTURE_DIR/case-nospec/spec-nospec.txt"
	local badspec="$FIXTURE_DIR/case-nospec/spec-nospec.txt"
	local err="$FIXTURE_DIR/case-nospec/stderr.txt"
	if stage_secrets stribog "$SRC" "$badspec" "$TARGET" >/dev/null 2> "$err"; then
		echo "  staging succeeded although a required secret has no spec entry" >&2
		return 1
	fi
	if ! grep -q "no spec entry for required secret 'xray-reality-private-key'" "$err"; then
		echo "  expected 'no spec entry' diagnostic, got: $(cat "$err")" >&2
		return 1
	fi
	if [[ -e "$TARGET/etc" ]]; then
		echo "  target_dir/etc tree created despite missing spec entry" >&2
		return 1
	fi
	return 0
}

# (9) Exact host row preferred over the wildcard: with both
#     stribog:xray-reality-private-key (0400) and a wildcard decoy
#     *:xray-reality-private-key (0600) present, the staged file keeps mode
#     400 from the exact row, not 600 from the wildcard.
test_exact_row_preferred_over_wildcard() {
	new_fixture pref
	cp "$SPEC" "$FIXTURE_DIR/case-pref/spec-pref.txt"
	echo '*:xray-reality-private-key:0600:root:root' >> "$FIXTURE_DIR/case-pref/spec-pref.txt"
	local badspec="$FIXTURE_DIR/case-pref/spec-pref.txt"
	local secrets="$TARGET/etc/nixos/secrets"
	if ! stage_secrets stribog "$SRC" "$badspec" "$TARGET" >/dev/null 2>&1; then
		echo "  staging failed with both exact and wildcard rows present" >&2
		return 1
	fi
	local mode
	mode=$(perm_of "$secrets/xray-reality-private-key")
	if [[ "$mode" != "400" ]]; then
		echo "  xray-reality-private-key mode is $mode, expected 400 from exact host row (not wildcard 600)" >&2
		return 1
	fi
	return 0
}

# (10) Owner correct but group wrong (root:wheel) → rejected before copying,
#      with the ownership diagnostic and no target tree.
test_wrong_group_rejected() {
	new_fixture wheel
	grep -v '^stribog:xray-reality-private-key:' "$SPEC" > "$FIXTURE_DIR/case-wheel/spec-wheel.txt"
	echo 'stribog:xray-reality-private-key:0400:root:wheel' >> "$FIXTURE_DIR/case-wheel/spec-wheel.txt"
	local badspec="$FIXTURE_DIR/case-wheel/spec-wheel.txt"
	local err="$FIXTURE_DIR/case-wheel/stderr.txt"
	if stage_secrets stribog "$SRC" "$badspec" "$TARGET" >/dev/null 2> "$err"; then
		echo "  root:wheel owner row was accepted" >&2
		return 1
	fi
	if ! grep -q "must be root:root" "$err"; then
		echo "  expected root:root ownership diagnostic, got: $(cat "$err")" >&2
		return 1
	fi
	if [[ -e "$TARGET/etc" ]]; then
		echo "  target_dir/etc tree created despite group rejection" >&2
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Task 5: guarded orchestration — preflight, fingerprint gate, typed
# confirmations, installer key bootstrap, two-phase nixos-anywhere, and
# --resume-install recovery mode. Everything below runs against fake
# binaries in a child process; see the file header.
#
# Fake behavior knobs (prefix assignments on run_install_child calls):
#   FAKE_SSH_FIRMWARE          BIOS (default) | UEFI — remote firmware probe
#   FAKE_SSH_LSBLK             canned lsblk -b -n -o NAME,TYPE,SIZE output
#   FAKE_KEYGEN_FPR            fingerprint reported by ssh-keygen -lf
#   FAKE_NIX_DISK              evaluated disko.devices.disk.main.device
#   FAKE_NIX_USER_COUNT        evaluated roles.xray.server.users length
#   FAKE_SSH_BOOTSTRAP_STATUS  exit status of the authorized_keys append
#   FAKE_SSH_ROOTVERIFY_STATUS exit status of `ssh -i key root@IP true`
#   FAKE_SSH_MNT_STATE         emulated remote /mnt state for the
#                              mountpoint/findmnt probes (post-Disko check,
#                              resume check): ok (default, healthy NIXROOT
#                              mount) | notmounted | wronglabel (both fail)
#   FAKE_SSH_RESUME_STATE      emulated install-marker probe: clean
#                              (default, post-Disko only) | installed
#   FAKE_SSH_SWAP_STATUS       exit status of the swapfile command
#   FAKE_ANYWHERE_DISK_STATUS  exit status of `--phases disko`
#   FAKE_ANYWHERE_INSTALL_STATUS exit status of `--phases install,reboot`
#   FAKE_EXTRA_FILES_CAPTURE   dir the fake nixos-anywhere copies --extra-files to
# ---------------------------------------------------------------------------

SHIM_DIR=""
SHIM_LOG=""
REPO_FIX=""
SECRET_VALUE="dummy-reality-key"

new_shim() {
	SHIM_DIR="$FIXTURE_DIR/shim"
	mkdir -p "$SHIM_DIR"

	cat >"$SHIM_DIR/ssh" <<'SHIM'
#!/usr/bin/env bash
L="${FAKE_SHIM_LOG:?}"
printf 'ssh %s\n' "$*" >>"$L"
args="$*"
case "$args" in
*authorized_keys*) exit "${FAKE_SSH_BOOTSTRAP_STATUS:-0}" ;;
esac
case "$args" in
*"o__ni@"*)
	if [[ -n "${FAKE_SSH_ONI_STDERR:-}" ]]; then
		printf '%s\n' "$FAKE_SSH_ONI_STDERR" >&2
	fi
	exit "${FAKE_SSH_ONI_STATUS:-0}"
	;;
esac
case "$args" in
*FIRMWARE*)
	printf 'FIRMWARE=%s\n' "${FAKE_SSH_FIRMWARE:-BIOS}"
	printf '%s\n' "${FAKE_SSH_LSBLK:-sda disk 21474836480}"
	exit "${FAKE_SSH_PREFLIGHT_STATUS:-0}" ;;
*findmnt*)
	# Emulated remote /mnt state for the mountpoint/findmnt probes used by
	# the post-Disko check and the resume check. notmounted and wronglabel
	# fail the probe; anything else is a healthy NIXROOT mount.
	case "${FAKE_SSH_MNT_STATE:-ok}" in
	notmounted | wronglabel) exit 1 ;;
	esac
	exit 0 ;;
*"/mnt/etc/NIXOS"*)
	# Emulated install-marker probe of the resume check (the remote command
	# tests /mnt/etc/NIXOS || /mnt/nix/store and echoes installed|clean);
	# informational only, never fails.
	printf 'RESUME_STATE=%s\n' "${FAKE_SSH_RESUME_STATE:-clean}"
	exit 0 ;;
*fallocate* | *swapon*) exit "${FAKE_SSH_SWAP_STATUS:-0}" ;;
*" true") exit "${FAKE_SSH_ROOTVERIFY_STATUS:-0}" ;;
esac
exit 0
SHIM

	cat >"$SHIM_DIR/ssh-keyscan" <<'SHIM'
#!/usr/bin/env bash
L="${FAKE_SHIM_LOG:?}"
printf 'ssh-keyscan %s\n' "$*" >>"$L"
printf '%s\n' "${FAKE_KEYSCAN_LINE:-192.0.2.10 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeFakeFakeFakeFakeFakeFakeFakeFakeFake}"
exit "${FAKE_KEYSCAN_STATUS:-0}"
SHIM

	cat >"$SHIM_DIR/ssh-keygen" <<'SHIM'
#!/usr/bin/env bash
L="${FAKE_SHIM_LOG:?}"
printf 'ssh-keygen %s\n' "$*" >>"$L"
for a in "$@"; do
	if [[ "$a" == "-lf" ]]; then
		printf '%s\n' "${FAKE_KEYGEN_FPR:-256 SHA256:FAKEFPR provision-fake (ED25519)}"
		exit "${FAKE_KEYGEN_LF_STATUS:-0}"
	fi
done
prev=""
for a in "$@"; do
	if [[ "$prev" == "-f" && -n "$a" ]]; then
		: >"$a"
		: >"$a.pub"
		exit "${FAKE_KEYGEN_STATUS:-0}"
	fi
	prev="$a"
done
exit "${FAKE_KEYGEN_STATUS:-0}"
SHIM

	cat >"$SHIM_DIR/nix" <<'SHIM'
#!/usr/bin/env bash
L="${FAKE_SHIM_LOG:?}"
printf 'nix %s\n' "$*" >>"$L"
args="$*"
case "$args" in
*disko.devices.disk.main.device*)
	printf '%s' "${FAKE_NIX_DISK:-/dev/sda}"
	exit "${FAKE_NIX_DISK_STATUS:-0}" ;;
*roles.xray.server.users*)
	printf '%s' "${FAKE_NIX_USER_COUNT:-2}"
	exit "${FAKE_NIX_USERS_STATUS:-0}" ;;
esac
exit 0
SHIM

	cat >"$SHIM_DIR/nixos-anywhere" <<'SHIM'
#!/usr/bin/env bash
L="${FAKE_SHIM_LOG:?}"
printf 'nixos-anywhere %s\n' "$*" >>"$L"
if [[ -n "${FAKE_EXTRA_FILES_CAPTURE:-}" ]]; then
	prev=""
	for a in "$@"; do
		if [[ "$prev" == "--extra-files" && -d "$a" ]]; then
			rm -rf "$FAKE_EXTRA_FILES_CAPTURE"
			mkdir -p "$FAKE_EXTRA_FILES_CAPTURE"
			cp -R "$a/." "$FAKE_EXTRA_FILES_CAPTURE/"
		fi
		prev="$a"
	done
fi
args="$*"
case "$args" in
*"--phases disko"*) exit "${FAKE_ANYWHERE_DISK_STATUS:-0}" ;;
*"--phases install,reboot"*) exit "${FAKE_ANYWHERE_INSTALL_STATUS:-0}" ;;
esac
exit 0
SHIM

	local f
	for f in ssh ssh-keyscan ssh-keygen nix nixos-anywhere; do
		chmod +x "$SHIM_DIR/$f"
	done
}

# Fixture repo tree handed to install.sh via PROVISION_REPO_ROOT so the
# orchestration tests never read the real secrets/ directory.
new_repo_fixture() {
	local d="$FIXTURE_DIR/repo-$1"
	mkdir -p "$d/secrets/unlocked"
	REPO_FIX="$d"
	printf '{\n  "dummy": {"value": "not-a-real-secret"}\n}\n' >"$d/secrets/secrets.json"
	cat >"$d/secrets/unlocked/spec.txt" <<'EOF'
# host:filename:perm:owner:group
buyan:xray-reality-private-key:0400:root:root
buyan:tailscale-auth-key:0400:root:root
stribog:xray-reality-private-key:0400:root:root
stribog:tailscale-auth-key:0400:root:root
veles:xray-reality-private-key:0400:root:root
veles:tailscale-auth-key:0400:root:root
veles:hysteria-veles-key:0400:root:root
veles:hysteria-veles-cert:0400:root:root
EOF
	echo "dummy-reality-key" >"$d/secrets/unlocked/xray-reality-private-key"
	echo "dummy-tailscale-auth-key" >"$d/secrets/unlocked/tailscale-auth-key"
	echo "dummy-hysteria-key" >"$d/secrets/unlocked/hysteria-veles-key"
	echo "dummy-hysteria-cert" >"$d/secrets/unlocked/hysteria-veles-cert"
}

# run_install_child HOST IP [FLAG...] — run run_provision in a child subshell
# with the shim dir prepended to PATH (child process only). Behavior knobs
# come from FAKE_*/EXPECTED_FINGERPRINT prefix assignments on the call;
# stdin feeds the typed confirmations (and the fingerprint prompt when
# EXPECTED_FINGERPRINT is set to an empty string).
run_install_child() {
	local host="$1" ip="$2"
	shift 2
	if [[ -z "$REPO_FIX" || -z "$SHIM_DIR" ]]; then
		echo "  run_install_child: fixture/shim not initialized" >&2
		return 1
	fi
	(
		export PATH="$SHIM_DIR:$PATH"
		export HOST="$host" IP="$ip"
		export PROVISION_REPO_ROOT="$REPO_FIX"
		export FAKE_SHIM_LOG="${FAKE_SHIM_LOG:-$SHIM_LOG}"
		export EXPECTED_FINGERPRINT="${EXPECTED_FINGERPRINT-SHA256:FAKEFPR}"
		# shellcheck source=../install.sh
		. "$TEST_DIR/../install.sh"
		run_provision "$host" "$ip" "$@"
	)
}

assert_contains() {
	if ! grep -q -- "$2" "$1"; then
		echo "  expected stub log to contain: $2" >&2
		return 1
	fi
}

assert_not_contains() {
	if grep -q -- "$2" "$1"; then
		echo "  stub log must NOT contain: $2" >&2
		grep -n -- "$2" "$1" | head -3 >&2
		return 1
	fi
}

# Every destructive phase is invoked via the fake nixos-anywhere, so a log
# free of --phases proves nothing destructive ran.
assert_no_install_phases() {
	assert_not_contains "$1" "--phases"
}

# (11) secrets/secrets.json missing → abort before any remote/phase action.
test_orchestration_missing_secrets_json_aborts() {
	new_repo_fixture nojson
	rm "$REPO_FIX/secrets/secrets.json"
	SHIM_LOG="$FIXTURE_DIR/nojson.log"
	: >"$SHIM_LOG"
	local out
	if out="$(run_install_child buyan 192.0.2.10 2>&1)"; then
		echo "  run succeeded without secrets/secrets.json" >&2
		return 1
	fi
	assert_no_install_phases "$SHIM_LOG" || return 1
	case "$out" in
	*"secrets.json not found"*) return 0 ;;
	*)
		echo "  expected missing-secrets.json diagnostic, got: $out" >&2
		return 1
		;;
	esac
}

# (12) secrets/secrets.json present but not JSON → rejected by the pure-bash
#      sanity check before anything remote.
test_orchestration_malformed_secrets_json_aborts() {
	new_repo_fixture badjson
	printf 'this-is-not-json{"broken"\n' >"$REPO_FIX/secrets/secrets.json"
	SHIM_LOG="$FIXTURE_DIR/badjson.log"
	: >"$SHIM_LOG"
	local out
	if out="$(run_install_child buyan 192.0.2.10 2>&1)"; then
		echo "  run succeeded with malformed secrets.json" >&2
		return 1
	fi
	assert_no_install_phases "$SHIM_LOG" || return 1
	case "$out" in
	*"does not look like a JSON object"*) return 0 ;;
	*)
		echo "  expected malformed-JSON diagnostic, got: $out" >&2
		return 1
		;;
	esac
}

# (13) secrets/unlocked/spec.txt missing → abort.
test_orchestration_missing_spec_aborts() {
	new_repo_fixture nospec
	rm "$REPO_FIX/secrets/unlocked/spec.txt"
	SHIM_LOG="$FIXTURE_DIR/nospec.log"
	: >"$SHIM_LOG"
	local out
	if out="$(run_install_child buyan 192.0.2.10 2>&1)"; then
		echo "  run succeeded without spec.txt" >&2
		return 1
	fi
	assert_no_install_phases "$SHIM_LOG" || return 1
	case "$out" in
	*"spec.txt not found"*) return 0 ;;
	*)
		echo "  expected missing-spec diagnostic, got: $out" >&2
		return 1
		;;
	esac
}

# (14) A required unlocked secret file missing → abort.
test_orchestration_missing_required_secret_file_aborts() {
	new_repo_fixture nofile
	rm "$REPO_FIX/secrets/unlocked/xray-reality-private-key"
	SHIM_LOG="$FIXTURE_DIR/nofile.log"
	: >"$SHIM_LOG"
	local out
	if out="$(run_install_child buyan 192.0.2.10 2>&1)"; then
		echo "  run succeeded with a missing required secret file" >&2
		return 1
	fi
	assert_no_install_phases "$SHIM_LOG" || return 1
	case "$out" in
	*"required secret file missing"*) return 0 ;;
	*)
		echo "  expected missing-secret-file diagnostic, got: $out" >&2
		return 1
		;;
	esac
}

# (15) Zero filtered Xray server users → abort (unreachable proxy host).
test_orchestration_zero_xray_users_aborts() {
	new_repo_fixture nousers
	SHIM_LOG="$FIXTURE_DIR/nousers.log"
	: >"$SHIM_LOG"
	local out
	if out="$(FAKE_NIX_USER_COUNT=0 run_install_child stribog 192.0.2.10 2>&1)"; then
		echo "  run succeeded with zero xray users" >&2
		return 1
	fi
	assert_no_install_phases "$SHIM_LOG" || return 1
	case "$out" in
	*"no Xray server users"*) return 0 ;;
	*)
		echo "  expected zero-users diagnostic, got: $out" >&2
		return 1
		;;
	esac
}

# (16) Wrong expected ISO fingerprint → abort before any direct SSH call.
test_orchestration_fingerprint_mismatch_aborts() {
	new_repo_fixture fprbad
	SHIM_LOG="$FIXTURE_DIR/fprbad.log"
	: >"$SHIM_LOG"
	local out
	if out="$(EXPECTED_FINGERPRINT=SHA256:WRONG run_install_child buyan 192.0.2.10 2>&1)"; then
		echo "  run succeeded with a mismatched fingerprint" >&2
		return 1
	fi
	assert_no_install_phases "$SHIM_LOG" || return 1
	assert_not_contains "$SHIM_LOG" "^ssh " || return 1
	case "$out" in
	*"FINGERPRINT MISMATCH"*) return 0 ;;
	*)
		echo "  expected fingerprint mismatch diagnostic, got: $out" >&2
		return 1
		;;
	esac
}

# (17) Live ISO booted in UEFI mode → abort (BIOS/GRUB installs only).
test_orchestration_uefi_aborts() {
	new_repo_fixture uefi
	SHIM_LOG="$FIXTURE_DIR/uefi.log"
	: >"$SHIM_LOG"
	local out
	if out="$(FAKE_SSH_FIRMWARE=UEFI run_install_child buyan 192.0.2.10 2>&1)"; then
		echo "  run succeeded with a UEFI ISO" >&2
		return 1
	fi
	assert_no_install_phases "$SHIM_LOG" || return 1
	case "$out" in
	*"UEFI"*) return 0 ;;
	*)
		echo "  expected UEFI diagnostic, got: $out" >&2
		return 1
		;;
	esac
}

# (18) Target disk missing on the live ISO (empty lsblk) → abort.
test_orchestration_missing_target_disk_aborts() {
	new_repo_fixture nodisk
	SHIM_LOG="$FIXTURE_DIR/nodisk.log"
	: >"$SHIM_LOG"
	local out
	# Blank canned output: an empty FAKE_SSH_LSBLK would fall back to the
	# fake's default, so a single blank line simulates a missing disk.
	if out="$(FAKE_SSH_LSBLK=' ' run_install_child veles 192.0.2.10 2>&1)"; then
		echo "  run succeeded with a missing target disk" >&2
		return 1
	fi
	assert_no_install_phases "$SHIM_LOG" || return 1
	case "$out" in
	*"lsblk"*) return 0 ;;
	*)
		echo "  expected missing-disk diagnostic, got: $out" >&2
		return 1
		;;
	esac
}

# (19) Undersized disk (12 GiB for buyan, which needs 16 GiB) → abort.
test_orchestration_undersized_disk_aborts() {
	new_repo_fixture small
	SHIM_LOG="$FIXTURE_DIR/small.log"
	: >"$SHIM_LOG"
	local out
	if out="$(FAKE_NIX_DISK=/dev/vda FAKE_SSH_LSBLK='vda disk 12884901888' run_install_child buyan 192.0.2.10 2>&1)"; then
		echo "  run succeeded on a 12 GiB disk for buyan" >&2
		return 1
	fi
	assert_no_install_phases "$SHIM_LOG" || return 1
	case "$out" in
	*"minimum"*) return 0 ;;
	*)
		echo "  expected undersized-disk diagnostic, got: $out" >&2
		return 1
		;;
	esac
}

# (20) Partition path instead of a whole disk → abort.
test_orchestration_partition_not_whole_disk_aborts() {
	new_repo_fixture part
	SHIM_LOG="$FIXTURE_DIR/part.log"
	: >"$SHIM_LOG"
	local out
	if out="$(FAKE_NIX_DISK=/dev/vda1 FAKE_SSH_LSBLK='vda1 part 21474836480' run_install_child buyan 192.0.2.10 2>&1)"; then
		echo "  run succeeded with a partition as the Disko device" >&2
		return 1
	fi
	assert_no_install_phases "$SHIM_LOG" || return 1
	case "$out" in
	*"not a whole disk"*) return 0 ;;
	*)
		echo "  expected whole-disk diagnostic, got: $out" >&2
		return 1
		;;
	esac
}

# (21) Typed hostname confirmation mismatch → abort before Disko.
test_orchestration_hostname_confirm_mismatch_aborts() {
	new_repo_fixture badhost
	SHIM_LOG="$FIXTURE_DIR/badhost.log"
	: >"$SHIM_LOG"
	local out
	if out="$(printf 'wronghost\n' | run_install_child buyan 192.0.2.10 2>&1)"; then
		echo "  run succeeded despite hostname confirmation mismatch" >&2
		return 1
	fi
	assert_no_install_phases "$SHIM_LOG" || return 1
	case "$out" in
	*"confirmation mismatch for hostname"*) return 0 ;;
	*)
		echo "  expected hostname-mismatch diagnostic, got: $out" >&2
		return 1
		;;
	esac
}

# (22) Typed disk-path confirmation mismatch → abort before Disko.
test_orchestration_disk_confirm_mismatch_aborts() {
	new_repo_fixture baddisk
	SHIM_LOG="$FIXTURE_DIR/baddisk.log"
	: >"$SHIM_LOG"
	local out
	if out="$(printf 'buyan\n/dev/wrongdisk\n' | FAKE_NIX_DISK=/dev/vda run_install_child buyan 192.0.2.10 2>&1)"; then
		echo "  run succeeded despite disk-path confirmation mismatch" >&2
		return 1
	fi
	assert_no_install_phases "$SHIM_LOG" || return 1
	case "$out" in
	*"confirmation mismatch for disk path"*) return 0 ;;
	*)
		echo "  expected disk-path-mismatch diagnostic, got: $out" >&2
		return 1
		;;
	esac
}

# (23) `ssh -i key root@IP true` failing after the bootstrap → abort before
#      the installer is invoked.
test_orchestration_root_key_verify_failure_aborts() {
	new_repo_fixture nokey
	SHIM_LOG="$FIXTURE_DIR/nokey.log"
	: >"$SHIM_LOG"
	local out
	if out="$(printf 'buyan\n/dev/vda\n' | FAKE_NIX_DISK=/dev/vda FAKE_SSH_ROOTVERIFY_STATUS=1 run_install_child buyan 192.0.2.10 2>&1)"; then
		echo "  run succeeded despite failed root key verification" >&2
		return 1
	fi
	assert_no_install_phases "$SHIM_LOG" || return 1
	case "$out" in
	*"root key verification failed"*) return 0 ;;
	*)
		echo "  expected root-key-verification diagnostic, got: $out" >&2
		return 1
		;;
	esac
}

# (24) Happy path: both nixos-anywhere phases run in order disko →
#      install,reboot with the prescribed flags, the staged secret tree is
#      handed to --extra-files, swap commands go through SSH, the root key is
#      bootstrapped and verified, direct SSH pins the scanned host key, and
#      neither the log nor the output ever contains the secret's value.
test_orchestration_happy_path_two_phases() {
	new_repo_fixture happy
	SHIM_LOG="$FIXTURE_DIR/happy.log"
	: >"$SHIM_LOG"
	local out
	if ! out="$(printf 'buyan\n/dev/vda\n' | FAKE_NIX_DISK=/dev/vda FAKE_SSH_LSBLK=$'vda disk 21474836480\nvda1 part 1048576\nvda2 part 21473771520' FAKE_EXTRA_FILES_CAPTURE="$FIXTURE_DIR/happy-extra" run_install_child buyan 192.0.2.10 2>&1)"; then
		echo "  happy path run failed: $out" >&2
		return 1
	fi
	local dline iline
	dline="$(grep -n -- '--phases disko' "$SHIM_LOG" | head -1 | cut -d: -f1)"
	iline="$(grep -n -- '--phases install,reboot' "$SHIM_LOG" | head -1 | cut -d: -f1)"
	if [[ -z "$dline" || -z "$iline" ]] || ((dline >= iline)); then
		echo "  expected --phases disko (line $dline) before --phases install,reboot (line $iline)" >&2
		return 1
	fi
	assert_contains "$SHIM_LOG" "--build-on remote" || return 1
	assert_contains "$SHIM_LOG" "--extra-files" || return 1
	assert_contains "$SHIM_LOG" "path:$REPO_FIX#buyan" || return 1
	assert_contains "$SHIM_LOG" "root@192.0.2.10" || return 1
	assert_contains "$SHIM_LOG" "nixos-anywhere -i" || return 1
	local cap="$FIXTURE_DIR/happy-extra/etc/nixos/secrets"
	if [[ ! -f "$cap/xray-reality-private-key" || ! -f "$cap/tailscale-auth-key" ]]; then
		echo "  --extra-files capture lacks the staged secrets: $(ls -A "$cap" 2>/dev/null | tr '\n' ' ')" >&2
		return 1
	fi
	if [[ "$(perm_of "$cap/xray-reality-private-key")" != "400" ]]; then
		echo "  staged xray-reality-private-key mode is $(perm_of "$cap/xray-reality-private-key"), expected 400" >&2
		return 1
	fi
	assert_contains "$SHIM_LOG" "fallocate -l 2G /mnt/.swapfile" || return 1
	assert_contains "$SHIM_LOG" "chmod 0600 /mnt/.swapfile" || return 1
	assert_contains "$SHIM_LOG" "mkswap /mnt/.swapfile" || return 1
	assert_contains "$SHIM_LOG" "swapon /mnt/.swapfile" || return 1
	assert_contains "$SHIM_LOG" "StrictHostKeyChecking=yes" || return 1
	assert_contains "$SHIM_LOG" "authorized_keys" || return 1
	assert_contains "$SHIM_LOG" "root@192.0.2.10 true" || return 1
	assert_contains "$SHIM_LOG" "ssh-keygen" || return 1
	assert_not_contains "$SHIM_LOG" "sshpass" || return 1
	assert_not_contains "$SHIM_LOG" "$SECRET_VALUE" || return 1
	case "$out" in
	*"$SECRET_VALUE"*)
		echo "  secret value leaked into run output" >&2
		return 1
		;;
	esac
	return 0
}

# (25) Exactly 8 GiB passes the veles/stribog minimum (boundary pin).
test_orchestration_stribog_8gib_boundary_passes() {
	new_repo_fixture bound
	SHIM_LOG="$FIXTURE_DIR/bound.log"
	: >"$SHIM_LOG"
	local out
	if ! out="$(printf 'stribog\n/dev/sda\n' | FAKE_SSH_LSBLK='sda disk 8589934592' run_install_child stribog 192.0.2.10 2>&1)"; then
		echo "  8 GiB stribog disk was rejected: $out" >&2
		return 1
	fi
	assert_contains "$SHIM_LOG" "--phases disko" || return 1
	return 0
}

# (26) --resume-install: no Disko at all, install,reboot still runs, the
#      resume state check happens over SSH, and the fingerprint prompt is
#      still enforced (typed fingerprint path).
test_orchestration_resume_mode_skips_disko() {
	new_repo_fixture resume
	SHIM_LOG="$FIXTURE_DIR/resume.log"
	: >"$SHIM_LOG"
	local out
	if ! out="$(printf 'SHA256:FAKEFPR\n' | EXPECTED_FINGERPRINT= FAKE_EXTRA_FILES_CAPTURE="$FIXTURE_DIR/resume-extra" run_install_child stribog 192.0.2.10 --resume-install 2>&1)"; then
		echo "  resume run failed: $out" >&2
		return 1
	fi
	assert_not_contains "$SHIM_LOG" "--phases disko" || return 1
	assert_contains "$SHIM_LOG" "--phases install,reboot" || return 1
	assert_contains "$SHIM_LOG" "mountpoint -q /mnt" || return 1
	assert_contains "$SHIM_LOG" "authorized_keys" || return 1
	assert_contains "$SHIM_LOG" "swapon /mnt/.swapfile" || return 1
	assert_contains "$SHIM_LOG" "--extra-files" || return 1
	assert_contains "$SHIM_LOG" "StrictHostKeyChecking=yes" || return 1
	return 0
}

# (27) Disko phase failure → no install phase, recovery instructions.
test_orchestration_disko_failure_no_install_phase() {
	new_repo_fixture dfail
	SHIM_LOG="$FIXTURE_DIR/dfail.log"
	: >"$SHIM_LOG"
	local out
	if out="$(printf 'buyan\n/dev/vda\n' | FAKE_NIX_DISK=/dev/vda FAKE_ANYWHERE_DISK_STATUS=1 run_install_child buyan 192.0.2.10 2>&1)"; then
		echo "  run succeeded despite a failed Disko phase" >&2
		return 1
	fi
	assert_not_contains "$SHIM_LOG" "--phases install,reboot" || return 1
	local count
	count="$(grep -c -- '--phases disko' "$SHIM_LOG")"
	if [[ "$count" != "1" ]]; then
		echo "  expected exactly 1 disko invocation, found $count" >&2
		return 1
	fi
	case "$out" in
	*"Disko phase FAILED"*) ;;
	*)
		echo "  expected Disko failure diagnostic, got: $out" >&2
		return 1
		;;
	esac
	case "$out" in
	*"--resume-install"*) return 0 ;;
	*)
		echo "  expected recovery instructions mentioning --resume-install" >&2
		return 1
		;;
	esac
}

# (28) Install-phase failure → Disko is never re-run; recovery instructions
#      point at the provider console and --resume-install.
test_orchestration_install_failure_never_redisks() {
	new_repo_fixture ifail
	SHIM_LOG="$FIXTURE_DIR/ifail.log"
	: >"$SHIM_LOG"
	local out
	if out="$(printf 'buyan\n/dev/vda\n' | FAKE_NIX_DISK=/dev/vda FAKE_ANYWHERE_INSTALL_STATUS=1 run_install_child buyan 192.0.2.10 2>&1)"; then
		echo "  run succeeded despite a failed install phase" >&2
		return 1
	fi
	local count
	count="$(grep -c -- '--phases disko' "$SHIM_LOG")"
	if [[ "$count" != "1" ]]; then
		echo "  expected exactly 1 disko invocation after install failure, found $count" >&2
		return 1
	fi
	case "$out" in
	*"install phase FAILED"*) ;;
	*)
		echo "  expected install-failure diagnostic, got: $out" >&2
		return 1
		;;
	esac
	case "$out" in
	*"--resume-install"*) return 0 ;;
	*)
		echo "  expected recovery instructions mentioning --resume-install" >&2
		return 1
		;;
	esac
}

# (29) Static guard: no tracing (set -x) and no sshpass anywhere in
#      install.sh; the ISO password is typed interactively. The set -x check
#      ignores comment lines mentioning the flag.
test_install_sh_no_trace_no_sshpass() {
	if grep -qE '^[^#]*set -x' "$TEST_DIR/../install.sh"; then
		echo "  install.sh must not enable tracing (set -x)" >&2
		return 1
	fi
	if grep -q 'sshpass' "$TEST_DIR/../install.sh"; then
		echo "  install.sh must not use sshpass" >&2
		return 1
	fi
	return 0
}

# (30) main(): forwards --resume-install to run_provision through the same
#      shimmed child, and rejects unknown arguments with usage.
test_main_forwards_resume_and_rejects_unknown_args() {
	new_repo_fixture cli
	SHIM_LOG="$FIXTURE_DIR/cli.log"
	: >"$SHIM_LOG"
	local out
	if ! out="$(EXPECTED_FINGERPRINT=SHA256:FAKEFPR run_install_child stribog 192.0.2.10 --resume-install 2>&1)"; then
		echo "  resume run via run_provision failed: $out" >&2
		return 1
	fi
	assert_contains "$SHIM_LOG" "--phases install,reboot" || return 1
	(
		export PATH="$SHIM_DIR:$PATH"
		export HOST="stribog" IP="192.0.2.10"
		export PROVISION_REPO_ROOT="$REPO_FIX"
		export FAKE_SHIM_LOG="$SHIM_LOG"
		export EXPECTED_FINGERPRINT="SHA256:FAKEFPR"
		# shellcheck source=../install.sh
		. "$TEST_DIR/../install.sh"
		main --resume-install
	) || {
		echo "  main --resume-install failed" >&2
		return 1
	}
	assert_contains "$SHIM_LOG" "--phases install,reboot" || return 1
	assert_not_contains "$SHIM_LOG" "--phases disko" || return 1
	(
		export PATH="$SHIM_DIR:$PATH"
		export HOST="stribog" IP="192.0.2.10"
		export PROVISION_REPO_ROOT="$REPO_FIX"
		export FAKE_SHIM_LOG="$SHIM_LOG"
		. "$TEST_DIR/../install.sh"
		main --bogus-flag 2>/dev/null
	) && {
		echo "  main accepted an unknown argument" >&2
		return 1
	}
	return 0
}

# (31) C1 regression: the post-Disko check must accept the Disko-shaped /mnt
#      (mounted, NIXROOT label; buyan also /mnt/nix) WITHOUT any
#      install-phase markers — /etc/NIXOS and /nix/store are products of the
#      install phase, not of disko. Normal mode must not probe them at all.
test_orchestration_post_disko_check_accepts_disko_shaped_mnt() {
	new_repo_fixture pdisko
	SHIM_LOG="$FIXTURE_DIR/pdisko.log"
	: >"$SHIM_LOG"
	local out
	if ! out="$(printf 'buyan\n/dev/vda\n' | FAKE_NIX_DISK=/dev/vda run_install_child buyan 192.0.2.10 2>&1)"; then
		echo "  happy path failed on a Disko-shaped /mnt: $out" >&2
		return 1
	fi
	assert_contains "$SHIM_LOG" "mountpoint -q /mnt && " || return 1
	assert_contains "$SHIM_LOG" "findmnt -n -o LABEL /mnt" || return 1
	assert_contains "$SHIM_LOG" "mountpoint -q /mnt/nix" || return 1
	# The old wrong invariant probed install markers right after Disko;
	# normal mode must never reference /mnt/etc/NIXOS.
	assert_not_contains "$SHIM_LOG" "/mnt/etc/NIXOS" || return 1
	return 0
}

# (32) C1: the post-Disko check fails when findmnt reports a different label
#      or /mnt is not a mountpoint; no install phase may run.
test_orchestration_post_disko_check_rejects_bad_mnt() {
	new_repo_fixture pdbad
	SHIM_LOG="$FIXTURE_DIR/pdbad.log"
	: >"$SHIM_LOG"
	local out
	if out="$(printf 'buyan\n/dev/vda\n' | FAKE_NIX_DISK=/dev/vda FAKE_SSH_MNT_STATE=wronglabel run_install_child buyan 192.0.2.10 2>&1)"; then
		echo "  run succeeded although the /mnt label is wrong" >&2
		return 1
	fi
	assert_not_contains "$SHIM_LOG" "--phases install,reboot" || return 1
	case "$out" in
	*"post-Disko /mnt check failed"*) ;;
	*)
		echo "  expected post-Disko failure diagnostic, got: $out" >&2
		return 1
		;;
	esac
	: >"$SHIM_LOG"
	if out="$(printf 'veles\n/dev/sda\n' | FAKE_SSH_MNT_STATE=notmounted run_install_child veles 192.0.2.10 2>&1)"; then
		echo "  run succeeded although /mnt is not mounted" >&2
		return 1
	fi
	assert_not_contains "$SHIM_LOG" "--phases install,reboot" || return 1
	case "$out" in
	*"post-Disko /mnt check failed"*) return 0 ;;
	*)
		echo "  expected post-Disko failure diagnostic, got: $out" >&2
		return 1
		;;
	esac
}

# (33) C1: resume accepts BOTH a clean post-Disko /mnt (build-failure case,
#      no install markers) and a partially/fully installed one, and prints
#      which state it detected.
test_orchestration_resume_accepts_clean_and_installed_mnt() {
	new_repo_fixture resboth
	SHIM_LOG="$FIXTURE_DIR/resboth.log"
	: >"$SHIM_LOG"
	local out
	if ! out="$(EXPECTED_FINGERPRINT=SHA256:FAKEFPR run_install_child stribog 192.0.2.10 --resume-install 2>&1)"; then
		echo "  resume failed on a clean post-Disko /mnt: $out" >&2
		return 1
	fi
	assert_contains "$SHIM_LOG" "/mnt/etc/NIXOS" || return 1
	case "$out" in
	*"clean post-Disko"*) ;;
	*)
		echo "  expected clean-state message, got: $out" >&2
		return 1
		;;
	esac
	: >"$SHIM_LOG"
	if ! out="$(EXPECTED_FINGERPRINT=SHA256:FAKEFPR FAKE_SSH_RESUME_STATE=installed run_install_child stribog 192.0.2.10 --resume-install 2>&1)"; then
		echo "  resume failed on an installed /mnt: $out" >&2
		return 1
	fi
	case "$out" in
	*"install markers"*) return 0 ;;
	*)
		echo "  expected installed-state message, got: $out" >&2
		return 1
		;;
	esac
}

# (34) C1: resume fails when /mnt is not mounted or the label is wrong; no
#      install phase may run.
test_orchestration_resume_rejects_bad_mnt() {
	new_repo_fixture resbad
	SHIM_LOG="$FIXTURE_DIR/resbad.log"
	: >"$SHIM_LOG"
	local out
	if out="$(EXPECTED_FINGERPRINT=SHA256:FAKEFPR FAKE_SSH_MNT_STATE=notmounted run_install_child stribog 192.0.2.10 --resume-install 2>&1)"; then
		echo "  resume succeeded although /mnt is not mounted" >&2
		return 1
	fi
	assert_not_contains "$SHIM_LOG" "--phases install,reboot" || return 1
	case "$out" in
	*"resume check failed"*) ;;
	*)
		echo "  expected resume failure diagnostic, got: $out" >&2
		return 1
		;;
	esac
	: >"$SHIM_LOG"
	if out="$(EXPECTED_FINGERPRINT=SHA256:FAKEFPR FAKE_SSH_MNT_STATE=wronglabel run_install_child stribog 192.0.2.10 --resume-install 2>&1)"; then
		echo "  resume succeeded although the /mnt label is wrong" >&2
		return 1
	fi
	assert_not_contains "$SHIM_LOG" "--phases install,reboot" || return 1
	case "$out" in
	*"resume check failed"*) return 0 ;;
	*)
		echo "  expected resume failure diagnostic, got: $out" >&2
		return 1
		;;
	esac
}

run_case() {
	local name="$1"
	local fn="$2"
	echo "== $name"
	if "$fn"; then
		pass=$((pass + 1))
		echo "PASS: $name"
	else
		fail=$((fail + 1))
		echo "FAIL: $name"
	fi
	echo
}

FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/provision-test.XXXXXX")"
new_shim

run_case "stribog stages exactly the required files with mode 0400" test_stribog_stages_exactly_required
run_case "missing required source file fails with no partial target tree" test_missing_source_fails_without_partial_tree
run_case "veles stages hysteria files but not cloudflare.ini" test_veles_stages_hysteria_not_cloudflare
run_case "path traversal filename in spec is rejected" test_traversal_filename_rejected
run_case "conflicting duplicate spec rows are rejected" test_conflicting_duplicates_rejected
run_case "non-root:root owner row is rejected before copying" test_non_root_owner_rejected
run_case "required_secrets rejects unknown host" test_required_secrets_unknown_host_fails
run_case "required secret with no spec entry is rejected with diagnostic" test_missing_spec_entry_rejected
run_case "exact host row preferred over wildcard decoy" test_exact_row_preferred_over_wildcard
run_case "root:wheel group row is rejected before copying" test_wrong_group_rejected
run_case "missing secrets/secrets.json aborts before any phase" test_orchestration_missing_secrets_json_aborts
run_case "malformed secrets/secrets.json aborts" test_orchestration_malformed_secrets_json_aborts
run_case "missing secrets/unlocked/spec.txt aborts" test_orchestration_missing_spec_aborts
run_case "missing required secret file aborts" test_orchestration_missing_required_secret_file_aborts
run_case "zero filtered xray users aborts" test_orchestration_zero_xray_users_aborts
run_case "fingerprint mismatch aborts before any SSH" test_orchestration_fingerprint_mismatch_aborts
run_case "UEFI live ISO aborts" test_orchestration_uefi_aborts
run_case "missing target disk aborts" test_orchestration_missing_target_disk_aborts
run_case "undersized disk aborts" test_orchestration_undersized_disk_aborts
run_case "partition path instead of whole disk aborts" test_orchestration_partition_not_whole_disk_aborts
run_case "hostname confirmation mismatch aborts" test_orchestration_hostname_confirm_mismatch_aborts
run_case "disk-path confirmation mismatch aborts" test_orchestration_disk_confirm_mismatch_aborts
run_case "failed root key verification aborts" test_orchestration_root_key_verify_failure_aborts
run_case "happy path runs disko before install,reboot with staged secrets and swap" test_orchestration_happy_path_two_phases
run_case "8 GiB disk passes the stribog minimum" test_orchestration_stribog_8gib_boundary_passes
run_case "resume install skips Disko and only installs" test_orchestration_resume_mode_skips_disko
run_case "Disko failure stops before the install phase with recovery hint" test_orchestration_disko_failure_no_install_phase
run_case "install failure never re-runs Disko" test_orchestration_install_failure_never_redisks
run_case "install.sh has no set -x and no sshpass" test_install_sh_no_trace_no_sshpass
run_case "main forwards --resume-install and rejects unknown args" test_main_forwards_resume_and_rejects_unknown_args
run_case "post-Disko check accepts Disko-shaped /mnt without install markers" test_orchestration_post_disko_check_accepts_disko_shaped_mnt
run_case "post-Disko check rejects wrong label or unmounted /mnt" test_orchestration_post_disko_check_rejects_bad_mnt
run_case "resume accepts clean post-Disko and installed /mnt" test_orchestration_resume_accepts_clean_and_installed_mnt
run_case "resume rejects unmounted or wrong-label /mnt" test_orchestration_resume_rejects_bad_mnt

echo "test-install: $pass passed, $fail failed"
if ((fail > 0)); then
	exit 1
fi
exit 0
