{ pkgs, ir }:
let
  mkApp =
    name: mode:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        pkgs.coreutils
        pkgs.dnscontrol
        pkgs.jq
      ];
      text = ''
        set -euo pipefail
        unset CLOUDFLAREAPI_DEBUG

        mode=${pkgs.lib.escapeShellArg mode}
        usage() {
          case "$mode" in
            preview)
              printf '%s\n' 'usage: dns-preview [ZONE]' >&2
              ;;
            drift-check)
              printf '%s\n' 'usage: dns-drift-check [ZONE]' >&2
              ;;
            apply)
              printf '%s\n' 'usage: dns-apply --confirm [ZONE]' >&2
              ;;
          esac
          exit 64
        }

        if [ -z "''${CLOUDFLARE_DNS_TOKEN:-}" ]; then
          printf '%s\n' 'CLOUDFLARE_DNS_TOKEN must be set' >&2
          exit 2
        fi

        case "$mode" in
          apply)
            [ "''${1:-}" = '--confirm' ] || usage
            shift
            ;;
        esac

        [ "$#" -le 1 ] || usage
        domainArgs=()
        if [ "$#" -eq 1 ]; then
          domainArgs=(--domains "$1")
        fi

        umask 077
        creds="$(mktemp "''${TMPDIR:-/tmp}/dnscontrol-creds.XXXXXX")"
        cleanup() {
          rm -f "$creds"
        }
        trap cleanup EXIT HUP INT TERM

        jq -n --arg apitoken "$CLOUDFLARE_DNS_TOKEN" \
          '{ cloudflare: { TYPE: "CLOUDFLAREAPI", apitoken: $apitoken } }' > "$creds"
        chmod 600 "$creds"

        case "$mode" in
          preview)
            dnscontrol preview --no-colors --full --no-populate --ir ${ir} --creds "$creds" "''${domainArgs[@]}"
            ;;
          drift-check)
            dnscontrol preview --no-colors --full --expect-no-changes --no-populate --ir ${ir} --creds "$creds" "''${domainArgs[@]}"
            ;;
          apply)
            dnscontrol preview --no-colors --full --no-populate --ir ${ir} --creds "$creds" "''${domainArgs[@]}"
            dnscontrol push --no-colors --full --no-populate --ir ${ir} --creds "$creds" "''${domainArgs[@]}"
            ;;
        esac
      '';
    };
in
{
  preview = mkApp "dns-preview" "preview";
  driftCheck = mkApp "dns-drift-check" "drift-check";
  apply = mkApp "dns-apply" "apply";
}
