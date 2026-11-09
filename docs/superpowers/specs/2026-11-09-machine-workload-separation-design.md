# Machine and Workload Separation Design

## Goal

Separate per-host operating-system configuration from deployed workloads, remove proven duplication, and keep the existing roles reusable outside the current infrastructure. This is a behavior-preserving refactor, not a deployment, migration, secret rotation, DNS change, or topology redesign.

## Composition

Each of the five existing machine directories becomes:

```text
machines/<host>/
  default.nix        # imports the two files and supplies shared host facts
  configuration.nix  # host, platform, boot, storage, network, SSH and state version
  workloads.nix      # selected roles and native workload services
```

`flake.nix` continues importing each machine directory. Its systems, special arguments, overlays, user module, output names, and the separate `do-generic` image remain unchanged. `default.nix` composes ordinary NixOS modules; it does not contain service policy. `hardware/` continues to hold reusable hardware/platform setup rather than host deployments. Use `workloads.nix`, not `roles.nix`, because workloads include native services such as Tailscale.

The classification is semantic, not based on option namespace. Boot, filesystem, swap, Btrfs maintenance, platform agents, SSH and host networking belong to `configuration.nix`; service roles and Tailscale to `workloads.nix`. Keep existing cache, common server and roles imports explicitly composed; the existing hardened module and role remain enabled on the same four VPSs, but not NixPi. No new base module is required solely to save imports.

Host facts needed by both modules are passed explicitly from the host's `default.nix` to imported module functions, rather than inferred by taking the first IP address from a merged list. In particular, NixPi's LAN interface, IP and gateway must be the same values used by networking and the relevant DNS, DHCP and home nginx workloads; Mokosh's external interface remains the WireGuard interface. Use `config.networking.hostName` in workload modules where only the already-declared hostname is needed; avoid duplicating the literal hostname. Secret access stays in the module that consumes it, using existing `secrets` imports and helpers. These facts are not new global options or flake-wide `specialArgs`.

## Shared deployment settings versus role implementation

- `roles/network/xray/default.nix`, `relay.nix`, and the other Xray roles remain generally reusable. They must not implicitly choose Buyan, Veles, Stribog, this repository's SNIs, proxy users, credentials, alternate ports or network topology. Retain their option defaults and opt-in behavior.
- Add `roles/network/xray/profiles/reverse-relay.nix`, explicitly imported only by Veles and Stribog's `workloads.nix`. It provides their genuinely shared deployment-specific relay inputs, including current ingress, reverse routing, forward rollback settings, SNI redirect and stream forward. It derives the host-filtered users and host-specific forward identity from `config.networking.hostName` using the existing helpers and selects the `buyan` reverse user from that host-filtered list. The profile is not imported from `roles/network/xray/default.nix`: auto-discovery reaches that directory through its existing `default.nix`, which imports only its named module files. Therefore merely importing `../../roles` must not activate the profile.
- Veles alone retains its CDN xHTTP settings and the explicitly configured disabled Hysteria2 forward settings; preserve these values even while inactive. Stribog must not gain a CDN origin or a second set of list-valued redirect/forward definitions. Buyan retains its separate server and bridge deployment.
- Add `common/tailscale-client.nix`, explicitly imported by Buyan, Veles and Stribog only. It contains their existing identical Tailscale client and autoconnect retry definitions. Mokosh's client has DNS and service-ordering differences; NixPi has different enrollment, DNS and logging settings. Neither imports this module. Do not put client setup into `roles.vpn`, which owns the Headscale server.
- Generic roles may absorb repeated behavior only if it is intrinsic to that role and does not change the current defaults or enable services on additional hosts. No such role change is required by this design. In particular, do not unconditionally enable Xray metrics, observability, port 2053 or stream forwarding from Xray. Keep host-specific overlays unchanged.

Nix list definitions merge rather than replace: move each shared Tailscale flag, redirect port and forward definition exactly once. Keep role/user lists and SNI ordering unchanged. Do not use `mkForce` to mask duplicate definitions or change option priorities. New shared modules introduce no configurable option namespace.

## Invariants and safety

Preserve all evaluated behavior for all five machines, including:

- each host's boot loader, filesystems, swap, network, firewall, SSH/root access, users and state version; in particular Stribog's `/32` routing, root-key login and `23.11` state version;
- Mokosh's cloud-init image module, service configuration and Tailscale ordering; NixPi's storage and LAN service configuration;
- Xray's users, bridge addresses, SNI/router ordering, firewall rules, runtime credential **paths**, CDN origin isolation, reverse fail-closed route, and manually selected forward rollback; no forwarding is enabled implicitly;
- the same per-host overlays and package choices, service activation, autoconnect flags, restart settings and scrape configuration.

No real secret values or generated real-secret configurations may be copied into a plan, test snapshot, terminal output, Git, or Nix store. Execute comparison and regression checks only with committed dummy secrets in separate disposable worktrees. Never overwrite an existing `secrets/secrets.json`; `make setup-dummy-secrets` overwrites it. Avoid `path:.` with real secrets because it copies the source tree into the store.

## Verification and documentation

Compare baseline and candidate using the same lock file and dummy secret fixture: force evaluation of all five `system.build.toplevel.drvPath`s, compare selected normalized non-secret host and service option projections, compare dummy Xray templates and forward-mode variants, and run `roles/network/xray/tests/reverse.sh` against both trees. Store comparison outputs in a private temporary directory and report only sanitized differences. Identical output derivation paths are useful evidence but are not required: source locations can alter derivation paths without a behavioral change. `nix flake check` by itself does not prove all host behavior or live functionality.

Run `make check`, `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/vulnerability -v`, the Xray regression script, and Nix formatting checks. Document any checks unavailable on the executing platform. Update README machine guidance, the root `AGENTS.md` machine pattern, and the active `docs/xray-reverse-deployment.md` source-edit/diff instructions. Its drift gate must cover all Veles machine files, the shared relay profile and the original role implementation files; historical plans and specs remain unchanged. No actual NixOS switch is authorized by this design, and existing live deployment gates remain in force.
