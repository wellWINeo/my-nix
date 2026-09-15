# Research: publishing an Anytype MCP server from mokosh

## Decision-ready conclusion

This is feasible, but the deployment is necessarily a **three-layer service**:

```text
Remote MCP client
  -> nginx, public TLS virtual host
  -> authenticated Streamable-HTTP MCP bridge (loopback only)
  -> official anytype-mcp subprocess (stdio)
  -> anytype-cli headless node (127.0.0.1:31012)
  -> Anytype network / only the spaces joined by the bot
```

The official `@anyproto/anytype-mcp` executable is not an HTTP server: its entry point creates an SDK `StdioServerTransport` and writes that it is running on stdio. It fetches the Anytype OpenAPI document at startup, then forwards MCP tool calls to the configured Anytype HTTP API. Its normal desktop default is `127.0.0.1:31009`; `ANYTYPE_API_BASE_URL=http://127.0.0.1:31012` selects the headless CLI API instead. Therefore nginx cannot reverse-proxy the official package directly. [MCP entry point](https://raw.githubusercontent.com/anyproto/anytype-mcp/main/src/init-server.ts#L46-L52) · [backend URL selection](https://raw.githubusercontent.com/anyproto/anytype-mcp/main/src/utils/base-url.ts#L27-L61)

Use the official **Anytype CLI**, not `anytype-heart` directly, as the node on mokosh. The CLI embeds `anytype-heart`, supports a dedicated bot account, and provides the local HTTP API on port 31012 by default. It deliberately binds its gRPC, gRPC-Web, and HTTP ports to loopback; only `--listen-address` changes the HTTP API listener. [Anytype CLI overview and bot quick start](https://github.com/anyproto/anytype-cli#anytype-cli) · [network configuration](https://github.com/anyproto/anytype-cli#network-configuration) · [listener constants](https://raw.githubusercontent.com/anyproto/anytype-cli/main/core/config/constants.go)

Do **not** expose port 31012, the official MCP process, or its Anytype bearer key. The public boundary is an HTTP MCP bridge with its own authentication. The bridge holds the backend Anytype API key privately and launches/communicates with `anytype-mcp` locally.

## What the upstream components do

| Component | Role | Deployment implication |
|---|---|---|
| `anytype-cli` | Headless, self-contained Anytype instance which embeds `anytype-heart`; the API is at `127.0.0.1:31012`. | Run one persistent instance under a dedicated system account. Its upstream `service` command is a *user* systemd service, so a NixOS system service should own lifecycle instead. [CLI README](https://github.com/anyproto/anytype-cli#running-the-server) |
| `anytype-heart` | Shared client library used by Anytype clients. | It is not the supported turnkey headless deployment interface; use it only indirectly through `anytype-cli`. [heart repository](https://github.com/anyproto/anytype-heart) |
| `@anyproto/anytype-mcp` | Converts Anytype's OpenAPI surface into MCP tools and forwards requests to the local API. | Official package is stdio-only; set `ANYTYPE_API_BASE_URL` to the CLI and put `Authorization: Bearer …` plus the API-version header in `OPENAPI_MCP_HEADERS`. [package README](https://github.com/anyproto/anytype-mcp#custom-api-base-url) · [header handling](https://raw.githubusercontent.com/anyproto/anytype-mcp/main/src/mcp/proxy.ts#L30-L46) |
| Streamable-HTTP bridge | Terminates remote MCP protocol and attaches the stdio child. | This is the missing component that must be selected or written; it must be authenticated and protocol-compliant. |
| nginx | Public TLS reverse proxy. | It proxies only to the loopback bridge and preserves MCP's streaming behavior; it never reaches the CLI API. |

The CLI uses a bot account created by `anytype auth create`; mnemonic login is intentionally unsupported. The upstream documentation says that the bot has access only to spaces it explicitly joins, and can be removed from a space from the desktop app. That makes a bot invited only to selected spaces the main least-privilege control. Generate a separate API key with `anytype auth apikey create` for the MCP backend. [CLI quick start](https://github.com/anyproto/anytype-cli#quick-start) · [API-key commands](https://github.com/anyproto/anytype-cli#api-keys)

`nix-anysync` is relevant for packaging, but it does not supply this end-to-end service. At revision `dfb8728`, its `pkgs/default.nix` package set defines `anytype-mcp` and `anytype-agent-runtime`, while its NixOS modules export only the four Any-Sync network services. Its `anytype-mcp` package is a `buildNpmPackage` pinned to upstream version 1.2.9, whereas the upstream package manifest currently reports 1.2.10. Its separate Anytype overlay *overrides* `prev.anytype-heart` and `prev.anytype-cli`; both depend on packages supplied by its Nixpkgs input rather than being standalone, upstream-source derivations in `nix-anysync`. Therefore `nix-anysync` is a credible source for a pinned MCP derivation, but not a provider of the official headless CLI package: the implementation must add and validate that package in this repository (or use a separately verified Nixpkgs package). It provides no NixOS module for the headless CLI, bridge, or public virtual host. [package set](https://github.com/wellWINeo/nix-anysync/blob/dfb8728c1b6c2b8bf059fe54fc6c80b16a139b75/pkgs/default.nix) · [MCP derivation](https://github.com/wellWINeo/nix-anysync/blob/dfb8728c1b6c2b8bf059fe54fc6c80b16a139b75/pkgs/anytype/anytype-mcp.nix) · [Anytype overlay](https://github.com/wellWINeo/nix-anysync/blob/dfb8728c1b6c2b8bf059fe54fc6c80b16a139b75/overlays/anytype/default.nix) · [module exports](https://github.com/wellWINeo/nix-anysync/blob/dfb8728c1b6c2b8bf059fe54fc6c80b16a139b75/nixos/modules/default.nix) · [upstream package manifest](https://raw.githubusercontent.com/anyproto/anytype-mcp/main/package.json)

`anytype-agent-runtime` is unrelated to an MCP HTTP bridge: it is a JavaScript runtime that consumes an Anytype API URL, key, and space ID to execute programs. It should not be included in this service. [agent-runtime README](https://github.com/anyproto/anytype-agent-runtime#configuration)

## Recommended design direction

### 1. Keep the Anytype data plane private

Run `anytype serve` with its default `127.0.0.1:31012` listener. Give it a persistent state directory and a non-login `anytype` system user. Set a stable `HOME` and `DATA_PATH` inside that state directory, rather than using the calling user's home directory.

This persistence is security-sensitive, not cache-like. On Linux without a usable keyring, the CLI falls back to placing the bot account key and session token in `~/.anytype/config.json`; its source explicitly calls this insecure for headless servers, although the file itself is written mode 0600. The NixOS service must keep that directory private, exclude it from the Nix store, and back it up as encrypted application state. [CLI configuration source](https://raw.githubusercontent.com/anyproto/anytype-cli/main/core/config/config.go#L9-L18) · [credential fallback](https://raw.githubusercontent.com/anyproto/anytype-cli/main/core/keyring.go#L36-L105) · [data/config paths](https://raw.githubusercontent.com/anyproto/anytype-cli/main/core/config/constants.go#L38-L80)

The Anytype API bearer key is a separate secret. Store it in the existing encrypted-secrets workflow and expose it to the bridge at runtime with a root-owned `EnvironmentFile`/credential file; never embed it in Nix source, an nginx config, or a derivation. Anytype's API uses HTTP bearer authentication, and the official MCP process takes its forwarded headers from `OPENAPI_MCP_HEADERS`. [Anytype API authentication](https://developers.anytype.io/docs/guides/get-started/authentication/) · [MCP header parsing](https://raw.githubusercontent.com/anyproto/anytype-mcp/main/src/mcp/proxy.ts#L116-L131)

### 2. Add a real Streamable-HTTP MCP boundary

The bridge should bind to `127.0.0.1:<port>` and expose a single `/mcp` endpoint through nginx. It launches the stdio MCP child with the private backend URL/key. It must support the current MCP Streamable HTTP transport, not merely a generic JSON reverse proxy: MCP uses POST and optional GET/SSE at one endpoint, and allows session IDs. [MCP transports specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)

For a first implementation, evaluate a maintained stdio-to-Streamable-HTTP bridge such as `mcp-proxy`; alternatively, package a small in-repository bridge/fork that uses the official TypeScript MCP SDK's HTTP transport. The acceptance criteria are more important than the product name:

- accepts the official Anytype MCP binary as a local stdio child;
- supports the target clients' required transport and authorization flow;
- binds locally, validates `Origin`, provides no permissive CORS, and has per-client rate/concurrency limits;
- keeps the child environment and backend bearer key out of client-visible requests and logs;
- has an explicit session/process model (one child per bridge or safely isolated child sessions) and a restart/health-check story.

For an Internet-reachable endpoint, implement OAuth 2.1 resource-server behavior if the target client requires standards-based remote MCP authorization. The MCP authorization specification says that authorization is optional overall, but HTTP implementations that support it should conform; the specified OAuth route requires protected-resource metadata and an authorization server. A static bridge API key or nginx basic auth may be adequate only for a known client that can send it and does not need OAuth discovery; it is not the default interoperable remote-MCP experience. [MCP authorization specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)

### 3. Put nginx only in front of the bridge

Follow the repository's existing TLS virtual-host pattern: a dedicated subdomain, the existing ACME certificate, `recommendedProxySettings`, and `proxyPass` to the bridge's loopback port. Do not open a new firewall port; nginx already owns public 80/443 on mokosh. Configure enough proxy read timeout for SSE/long-running tool calls, a bounded request body, connection limits, and an application-specific access log with secrets redacted.

The MCP specification requires an Origin check for Streamable HTTP and recommends authentication on every connection. This matters even if nginx terminates TLS: the check belongs in the bridge, not only in proxy configuration. [Streamable HTTP security requirements](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#security-warning)

## Security and operational constraints

1. **The remote caller effectively acts as the bot.** The official package generates tools for the API surface and forwards each call using the one configured bearer key. Do not accept a caller-supplied backend Anytype key. Scope the bot by space membership and retain a simple revocation path: remove it from the space and revoke its API key. [OpenAPI-to-tool conversion](https://raw.githubusercontent.com/anyproto/anytype-mcp/main/src/openapi/parser.ts#L296-L326) · [CLI space/bot isolation](https://github.com/anyproto/anytype-cli#quick-start)

2. **Do not expose files tools without a sandbox.** The official package's file-upload path accepts a path supplied in the tool arguments and calls `fs.createReadStream` on it. An authenticated remote model could therefore cause the bridge host to read files available to its Unix account. Either remove/deny file tools in the bridge, or run the child with a restrictive systemd filesystem sandbox and no readable secrets. [file-upload implementation](https://raw.githubusercontent.com/anyproto/anytype-mcp/main/src/client/http-client.ts#L48-L97)

3. **Patch or contain sensitive logging before production.** The current package logs full MCP request parameters and operation parameters to stderr. Those may include Anytype content and absolute file names; systemd would normally put them in the journal. Package a small patch to remove/redact these lines, and keep journal access restricted. [MCP request logging](https://raw.githubusercontent.com/anyproto/anytype-mcp/main/src/mcp/proxy.ts#L68-L81) · [HTTP-client logging](https://raw.githubusercontent.com/anyproto/anytype-mcp/main/src/client/http-client.ts#L147-L175)

4. **Retain the upstream Anytype rate limit.** The local API allows a burst of 60 requests but only one sustained request/second. Do not set `ANYTYPE_API_DISABLE_RATE_LIMIT=1`; instead queue/back-pressure MCP calls and rate-limit at the public bridge so an agent loop cannot degrade the node. [Anytype rate limits](https://developers.anytype.io/docs/guides/fundamentals/rate-limits/)

5. **Any-Sync is optional, not the API server.** For the normal Anytype Network, the headless bot is sufficient. If data must use a self-hosted Any-Sync network, create the bot with `--network-config` and persist the node YAML; the CLI then connects to that network. Running the Any-Sync components on mokosh does not replace the headless node/API layer. [CLI self-hosted-network guide](https://raw.githubusercontent.com/anyproto/anytype-cli/main/SELF-HOSTED.md)

## Alternatives considered

| Alternative | Result | Why |
|---|---|---|
| Public nginx proxy directly to `anytype-cli:31012` | Reject | It publishes the raw Anytype REST API and bearer-key trust boundary instead of MCP, despite the CLI warning that exposed API keys grant access to the bot's spaces. [CLI security note](https://github.com/anyproto/anytype-cli#network-configuration) |
| Run official `anytype-mcp` alone | Reject for remote clients | It is a local stdio server, not an HTTP listener. |
| Directly operate `anytype-heart` | Reject | It is lower-level shared-library infrastructure; the supported headless account/API lifecycle resides in `anytype-cli`. |
| HTTP bridge over official stdio child | Recommended direction | Keeps official API-to-tool mapping while adding the one missing transport/authentication boundary. |
| Fork/repackage Anytype MCP with native Streamable HTTP | Viable if the bridge cannot meet security/auth needs | More maintenance, but provides control over OAuth, tool allow-listing, logging, and process isolation. |

## Bootstrap and verification outline

1. Decide whether this bot connects to the normal Anytype Network or a self-hosted Any-Sync network, and decide the exact spaces it may join.
2. Deploy the private `anytype-cli` system service, but do not publish any of its three ports. Verify `http://127.0.0.1:31012/docs/openapi.json` locally after the node is ready.
3. Create the dedicated bot account, save its account key outside source control, join only approved spaces, create a backend API key, and confirm a local authenticated API request.
4. Package/pin `anytype-mcp` from `nix-anysync` or a repository-local derivation, and add a separately validated derivation for the official `anytype-cli` source. Update pins and hashes deliberately, then set the CLI API URL and backend headers as runtime secrets.
5. Deploy the bridge on loopback. Test MCP initialization and a read-only tool locally; confirm that restarting the CLI does not lose the bot or data.
6. Add the nginx virtual host and the chosen remote authorization. From an unauthenticated Internet client, verify 401/authorization discovery and no access to the bridge/CLI internals; from an authorized client, verify initialization, read, write, revoke, and rate-limit behavior.
7. Verify no tool can read a system secret or arbitrary host file, and inspect journals to ensure Anytype content and credentials are not logged.

## Decisions needed before implementation

- Which remote MCP clients must work? This determines whether static client credentials are acceptable or OAuth 2.1/resource metadata is required.
- Is “publicly exposed” intended to mean a public URL for one owner, or a multi-user service? The latter needs per-user identities, authorization policy, auditing, and likely separate bot accounts/spaces.
- Which exact Anytype spaces and operations are allowed? A read-only/restricted tool set would be materially safer than the full generated API.
- Is the target network the public Anytype Network or an Any-Sync deployment managed on mokosh? The latter adds node configuration and encrypted state/backup requirements.
- Is a pinned third-party stdio-to-HTTP bridge acceptable, or should the repository own the small HTTP adapter for tighter auditing and NixOS integration?
- Should this repository package `anytype-cli` from its official upstream source, or is a package in the pinned Nixpkgs revision available and acceptable after evaluation? `nix-anysync` is not a provider for it.

## Sources and scope

Research was performed from upstream Anytype source/documentation, the MCP specification, and the requested `wellWINeo/nix-anysync` source at commit `dfb8728c1b6c2b8bf059fe54fc6c80b16a139b75`, checked 2026-09-14. No configuration was changed and no package was built or evaluated on mokosh. Memory, disk, process-isolation behavior of a selected bridge, and compatibility with a particular remote MCP client remain implementation-time validation items.
