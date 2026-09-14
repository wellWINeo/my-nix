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

The expected result is a connection failure. Install the decrypted files and
switch the mokosh configuration:

```bash
make install-secrets
sudo nixos-rebuild switch --flake 'path:.#mokosh'
sudo systemctl status anytype-cli.service anytype-mcp-proxy.service nginx.service
sudo ss -ltnp | rg ':(31012|8118)\b'
```

Both services must be active and both listeners must show `127.0.0.1`, never a
public address. Create the dedicated bot and a distinct private API key as the
service user, using its persistent service environment:

```bash
sudo -u anytype env HOME=/var/lib/anytype DATA_PATH=/var/lib/anytype \
  anytype auth create anytype-mcp
sudo -u anytype env HOME=/var/lib/anytype DATA_PATH=/var/lib/anytype \
  anytype auth apikey create anytype-mcp
```

Keep the bot recovery material outside the repository. Put the generated API
key only in the untracked encrypted-source file `secrets/unlocked/anytype-mcp.env`
using the secret-file format declared in `secrets/unlocked/spec.txt`; do not
print it or add it to Nix source. Generate the public bearer in the operator's
secret manager and put it only in
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

For restore credentials, repository selection, snapshot inspection, and restic
integrity checks, use `docs/backups.md`. Before restoring, stop both Anytype
services and preserve the current state outside the target directory. Restore
the saved `var/lib/anytype` path into a temporary target, then copy its contents
back to `/var/lib/anytype` with ownership `anytype:anytype` and mode `0700`.
Start the services and confirm persistence and public access:

```bash
sudo systemctl stop anytype-mcp-proxy.service anytype-cli.service
# Restore with the restic procedure in docs/backups.md, then restore ownership.
sudo chown -R anytype:anytype /var/lib/anytype
sudo chmod 0700 /var/lib/anytype
sudo systemctl start anytype-cli.service anytype-mcp-proxy.service
sudo -u anytype env HOME=/var/lib/anytype DATA_PATH=/var/lib/anytype \
  anytype space list
```

If the recovered state cannot authenticate or list its expected spaces, rebuild
the bot identity using the recovery material stored outside the repository,
rejoin only the intended spaces in Anytype, create a replacement private API
key, and rotate the public bearer before resuming client access.

## Smoke Test Workflow

On a trusted client, retrieve the public bearer from the secret manager without
printing it, then run the unauthenticated and authenticated Streamable-HTTP
initialization requests:

```bash
read -rs MCP_TOKEN
printf '\n'
curl -sS -D /tmp/anytype-mcp.headers -o /tmp/anytype-mcp.body \
  -H 'Accept: application/json, text/event-stream' \
  -H 'Content-Type: application/json' \
  -H 'MCP-Protocol-Version: 2025-11-25' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"mokosh-smoke","version":"1"}}}' \
  https://anytype.uspenskiy.tech/mcp
curl -sS -D /tmp/anytype-mcp-auth.headers -o /tmp/anytype-mcp-auth.body \
  -H "Authorization: Bearer $MCP_TOKEN" \
  -H 'Accept: application/json, text/event-stream' \
  -H 'Content-Type: application/json' \
  -H 'MCP-Protocol-Version: 2025-11-25' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"mokosh-smoke","version":"1"}}}' \
  https://anytype.uspenskiy.tech/mcp
unset MCP_TOKEN
```

The unauthenticated response must be `401`. The authenticated initialization
must succeed and, when the bridge selects a sessionful transport, include an
`Mcp-Session-Id` response header. Reuse that session ID with the same bearer to
call `tools/list`; create, update, read, and delete a disposable test object in
the bot's invited test space. Do not copy object content or tokens into the
repository or journal. Complete the upload-boundary and restart/persistence
checks described above before treating the deployment as operational.
