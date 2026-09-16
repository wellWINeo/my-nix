# Anytype MCP on Mokosh

This runbook operates the public Anytype MCP endpoint backed by the dedicated
`anytype` bot on mokosh. Perform bootstrap, secret changes, membership changes,
and recovery on mokosh or from a trusted client as specified below. Do not put
credentials, invite links, object content, or recovery material in this
repository or in the journal.

## Endpoint and Client Authentication

The public endpoint is `https://anytype.uspenskiy.tech/mcp`. TLS terminates at
Nginx; the Anytype CLI API (`127.0.0.1:31012`) and MCP bridge
(`127.0.0.1:8118`) are loopback-only. No additional firewall port is exposed.

Clients authenticate with the static bearer token installed in
`/etc/nixos/secrets/anytype-mcp-nginx-auth.conf`. This bearer has all authority
held by the bot: anyone holding it can use every space the bot has joined and
all enabled MCP tools. Treat it as a high-value credential. The bearer is
separate from the private Anytype API key in
`/etc/nixos/secrets/anytype-mcp.env`; do not send the private key to clients.

## Initial Bot Bootstrap

On mokosh, after Task 2's Nix evaluation has passed, first confirm that the
pre-deployment local API is unavailable:

```bash
curl --fail http://127.0.0.1:31012/docs/openapi.json
```

The expected result is a connection failure. Before the first switch, create
the Nginx source file with its real bearer condition. Because the bot API key
does not exist until the CLI has started, create the private environment source
as an empty mode-0400 root-owned file for this staged switch. It is a valid
empty systemd environment file, allowing the CLI to start; the bridge may be
unhealthy until the bot key is installed. Do not use a dummy API key or an
unauthenticated Nginx include.

The files are untracked plaintext source files whose contents are included in
the encrypted archive; they are not credentials embedded in Nix. Their exact
non-secret formats are:

```text
# secrets/unlocked/anytype-mcp.env when populated, mode 0400, final newline
OPENAPI_MCP_HEADERS='{"Authorization":"Bearer ACTUAL_ANYTYPE_API_KEY","Anytype-Version":"2025-11-08"}'
```

```nginx
# secrets/unlocked/anytype-mcp-nginx-auth.conf, mode 0400
if ($http_authorization != "Bearer ACTUAL_BASE64URL_TOKEN") { return 401; }
```

For the staged switch, leave the environment file empty and replace only the
marked bearer value in the Nginx include. After the bot key is created below,
replace the empty environment file with the one-line assignment shown above.
Use a secret manager or editor that does not record values in shell history.
`secrets/unlocked/spec.txt` declares only installation metadata
(`host:filename:mode:owner:group`); it does not contain either secret's
contents. Keep both source files out of Git and run:

```bash
install -m 0400 /dev/null secrets/unlocked/anytype-mcp.env
# Create secrets/unlocked/anytype-mcp-nginx-auth.conf with the real condition.
chmod 0400 secrets/unlocked/anytype-mcp-nginx-auth.conf
make lock-files
make install-secrets
sudo nixos-rebuild switch --flake 'path:.#mokosh'
sudo systemctl status anytype-cli.service anytype-mcp-proxy.service nginx.service
sudo ss -ltnp | rg ':(31012|8118)\b'
```

The CLI must be active and its listener must show `127.0.0.1`; the bridge may
be unhealthy until its private key is installed. Create the dedicated bot and a distinct private API key as the
service user, using its persistent service environment:

```bash
sudo -u anytype env HOME=/var/lib/anytype DATA_PATH=/var/lib/anytype \
  anytype auth create anytype-mcp
sudo -u anytype env HOME=/var/lib/anytype DATA_PATH=/var/lib/anytype \
  anytype auth apikey create anytype-mcp
```

Keep the bot recovery material outside the repository. After creating the bot,
replace the private API-key value in the untracked plaintext source file
`secrets/unlocked/anytype-mcp.env`; do not print it or add it to Nix source.
Generate the public bearer in the operator's secret manager and put it only in
`secrets/unlocked/anytype-mcp-nginx-auth.conf`. Re-encrypt, install, and reload
only the consumers:

```bash
make lock-files
make install-secrets
sudo systemctl restart anytype-mcp-proxy.service
sudo systemctl reload nginx.service
```

Neither command should print either credential.

## Adding and Removing Space Access

Space membership is performed in Anytype, rather than Nix. Copy an invite link
directly from Anytype and pass it as a quoted positional argument. Join only a
disposable test space for initial validation.

```bash
read -r ANYTYPE_INVITE_LINK
sudo -u anytype env HOME=/var/lib/anytype DATA_PATH=/var/lib/anytype \
  anytype space join "$ANYTYPE_INVITE_LINK"
unset ANYTYPE_INVITE_LINK
sudo -u anytype env HOME=/var/lib/anytype DATA_PATH=/var/lib/anytype \
  anytype space list
```

To remove access, remove the bot from the space in Anytype, then verify its
remaining scope with the same `anytype space list` command. Removing the bot
from a space is the membership revocation control; it requires no Nix change or
service restart.

## Rotating the Public Bearer Token

Generate a high-entropy base64url token in the operator's secret manager. Keep
the alphabet to `A-Z`, `a-z`, `0-9`, `-`, and `_`, then replace only the token
in the untracked `secrets/unlocked/anytype-mcp-nginx-auth.conf` Nginx include.
Do not use the private Anytype API key as this token and do not expose either
value in shell history, repository files, or logs.

Re-encrypt and install the changed file, then reload Nginx:

```bash
make lock-files
make install-secrets
sudo systemctl reload nginx.service
```

Verify an old bearer now receives `401` and the new bearer completes the
authenticated smoke test below. Distribute the new bearer only through the
approved secret manager.

## Rotating the Private Anytype API Key

Create a replacement API key as the bot service user:

```bash
sudo -u anytype env HOME=/var/lib/anytype DATA_PATH=/var/lib/anytype \
  anytype auth apikey create anytype-mcp
```

Update only `secrets/unlocked/anytype-mcp.env` with the new private API key in
the declared `OPENAPI_MCP_HEADERS` environment assignment. Keep
`ANYTYPE_API_BASE_URL` out of that secret file: it remains declarative service
configuration. Re-encrypt, install, and restart only the bridge:

```bash
make lock-files
make install-secrets
sudo systemctl restart anytype-mcp-proxy.service
```

Run the authenticated smoke test before revoking the previous API key through
the supported Anytype key-management interface. Retain no plaintext copy of
either key after rotation.

## Upload Directory Boundary

All MCP tools are enabled, including the upstream file-upload tool. Files for
that tool must first be placed in `/var/lib/anytype-mcp/uploads`, owned by
`anytype-mcp`. The bridge sandbox grants the MCP process access to that
directory only; it cannot read `/var/lib/anytype`, `/etc/nixos/secrets`, or
arbitrary host paths.

For a boundary test, place a disposable file in the upload directory as the
`anytype-mcp` user, upload it through an authenticated MCP client, and confirm
success. Then try the same tool with
`/etc/nixos/secrets/restic-password`; it must fail with permission denied or
not found. Do not place real secrets or sensitive content in the upload
directory.

## Service Health and Logs

On mokosh, inspect units, listener scope, and recent logs with:

```bash
sudo systemctl status anytype-cli.service anytype-mcp-proxy.service nginx.service
sudo ss -ltnp | rg ':(31012|8118)\b'
sudo journalctl -u anytype-cli.service -u anytype-mcp-proxy.service -n 100 --no-pager
sudo journalctl -u nginx.service -n 100 --no-pager
```

Do not copy Anytype object content, file names, Authorization headers, or
credentials from logs into tickets or the repository. Following a CLI or bridge
restart, confirm the bot still sees the intended spaces:

```bash
sudo systemctl restart anytype-cli.service anytype-mcp-proxy.service
sudo -u anytype env HOME=/var/lib/anytype DATA_PATH=/var/lib/anytype \
  anytype space list
```

## Backup and State Recovery

The existing restic configuration backs up `/var/lib/anytype`, which contains
the bot identity and persistent Anytype state. Trigger and inspect its local
backup job on mokosh:

```bash
sudo systemctl start restic-backups-local.service
sudo systemctl status restic-backups-local.service
```

Use the repository's documented restic workflow and supply its S3 credentials
from the operator's secret manager without printing them. The Anytype-specific
restore command is:

```bash
sudo -i
REPO="s3:storage.yandexcloud.net/wellwineo-backups/mokosh"
export RESTIC_PASSWORD_FILE=/etc/nixos/secrets/restic-password
. /etc/nixos/secrets/restic-env
restic -r "$REPO" snapshots
RESTORE_DIR="$(mktemp -d /tmp/anytype-restore.XXXXXX)"
chmod 0700 "$RESTORE_DIR"
trap 'rm -rf "$RESTORE_DIR"' EXIT
restic -r "$REPO" restore latest --target "$RESTORE_DIR" --include var/lib/anytype
test -d "$RESTORE_DIR/var/lib/anytype"
sudo systemctl stop anytype-mcp-proxy.service anytype-cli.service
sudo mv /var/lib/anytype /var/lib/anytype.pre-restore
sudo install -d -o anytype -g anytype -m 0700 /var/lib/anytype
sudo rsync -a --chown=anytype:anytype \
  "$RESTORE_DIR/var/lib/anytype/" /var/lib/anytype/
sudo chown -R anytype:anytype /var/lib/anytype
sudo chmod 0700 /var/lib/anytype
stat -c '%U:%G %a %n' /var/lib/anytype
sudo systemctl start anytype-cli.service anytype-mcp-proxy.service
sudo -u anytype env HOME=/var/lib/anytype DATA_PATH=/var/lib/anytype \
  anytype space list
exit
```

The restore target must contain `"$RESTORE_DIR/var/lib/anytype"`. The trap
removes that temporary target if restore or copying fails, while the live
directory is preserved as `/var/lib/anytype.pre-restore` before replacement.
The `stat` result must show `anytype:anytype` and mode `700`. Retain
`/var/lib/anytype.pre-restore` until the authenticated smoke test succeeds;
remove it only through the normal operator cleanup process. Run the complete
authenticated smoke test below, including the expected successful
initialization, session handling, and test-object operations, before resuming
client access. Run `restic -r "$REPO" check` after recovery when the repository
integrity check is required.

If the recovered state cannot authenticate or list its expected spaces, rebuild
the bot identity using the recovery material stored outside the repository,
rejoin only the intended spaces in Anytype, create a replacement private API
key, and rotate the public bearer before resuming client access.

## Smoke Test Workflow

On a trusted client, retrieve the public bearer from the secret manager without
printing it. The temporary header file is mode `0600`; curl receives its path,
not the bearer value, so the token is not expanded into curl's process
arguments. The assertions fail closed if the expected HTTP or MCP result is not
returned:

```bash
set -eu
umask 077
MCP_HEADER_FILE="$(mktemp)"
UNAUTH_STATUS_FILE="$(mktemp)"
AUTH_STATUS_FILE="$(mktemp)"
UNAUTH_HEADERS_FILE="$(mktemp)"
UNAUTH_BODY_FILE="$(mktemp)"
AUTH_HEADERS_FILE="$(mktemp)"
AUTH_BODY_FILE="$(mktemp)"
TOOLS_HEADERS_FILE="$(mktemp)"
TOOLS_BODY_FILE="$(mktemp)"
trap 'rm -f "$MCP_HEADER_FILE" "$UNAUTH_STATUS_FILE" "$AUTH_STATUS_FILE" "$UNAUTH_HEADERS_FILE" "$UNAUTH_BODY_FILE" "$AUTH_HEADERS_FILE" "$AUTH_BODY_FILE" "$TOOLS_HEADERS_FILE" "$TOOLS_BODY_FILE"' EXIT
read -rs MCP_TOKEN
printf '\n'
printf 'Authorization: Bearer %s\n' "$MCP_TOKEN" >"$MCP_HEADER_FILE"
curl -sS -D "$UNAUTH_HEADERS_FILE" -o "$UNAUTH_BODY_FILE" \
  -w '%{http_code}' >"$UNAUTH_STATUS_FILE" \
  -H 'Accept: application/json, text/event-stream' \
  -H 'Content-Type: application/json' \
  -H 'MCP-Protocol-Version: 2025-11-25' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"mokosh-smoke","version":"1"}}}' \
  https://anytype.uspenskiy.tech/mcp
test "$(<"$UNAUTH_STATUS_FILE")" = 401

curl -sS -D "$AUTH_HEADERS_FILE" -o "$AUTH_BODY_FILE" \
  -w '%{http_code}' >"$AUTH_STATUS_FILE" \
  -H @"$MCP_HEADER_FILE" \
  -H 'Accept: application/json, text/event-stream' \
  -H 'Content-Type: application/json' \
  -H 'MCP-Protocol-Version: 2025-11-25' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"mokosh-smoke","version":"1"}}}' \
  https://anytype.uspenskiy.tech/mcp
test "$(<"$AUTH_STATUS_FILE")" -ge 200
test "$(<"$AUTH_STATUS_FILE")" -lt 300
rg -q '"result"[[:space:]]*:' "$AUTH_BODY_FILE"

if rg -qi '^Mcp-Session-Id:' "$AUTH_HEADERS_FILE"; then
  SESSION_ID="$(awk 'BEGIN { IGNORECASE=1 } /^Mcp-Session-Id:/ { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/\r/, ""); print; exit }' "$AUTH_HEADERS_FILE")"
  test -n "$SESSION_ID"
  curl -sS -D "$TOOLS_HEADERS_FILE" -o "$TOOLS_BODY_FILE" \
    -w '%{http_code}' >"$AUTH_STATUS_FILE" \
    -H @"$MCP_HEADER_FILE" \
    -H "Mcp-Session-Id: $SESSION_ID" \
    -H 'Accept: application/json, text/event-stream' \
    -H 'Content-Type: application/json' \
    -H 'MCP-Protocol-Version: 2025-11-25' \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    https://anytype.uspenskiy.tech/mcp
  test "$(<"$AUTH_STATUS_FILE")" -ge 200
  test "$(<"$AUTH_STATUS_FILE")" -lt 300
  rg -q '"result"[[:space:]]*:' "$TOOLS_BODY_FILE"
else
  echo 'No Mcp-Session-Id returned; bridge selected a stateless transport.'
fi
unset MCP_TOKEN
```

The first assertion proves `401`; the second proves a successful authenticated
MCP initialization and a JSON-RPC result. When a sessionful transport is
selected, the branch asserts a non-empty `Mcp-Session-Id` and a successful
`tools/list` call using that session. Create, update, read, and delete a
disposable test object in the bot's invited test space through the authenticated
client. Do not copy object content or tokens into the repository or journal.
Complete the upload-boundary and restart/persistence checks described above
before treating the deployment as operational.
