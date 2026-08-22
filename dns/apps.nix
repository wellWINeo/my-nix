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
        domain_args=()
        if [ "$#" -eq 1 ]; then
          domain_args=(--domains "$1")
        fi

        umask 077
        creds="$(mktemp "''${TMPDIR:-/tmp}/dnscontrol-creds.XXXXXX")"
        cleanup() {
          rm -f "$creds"
        }
        trap cleanup EXIT HUP INT TERM

        printf '%s' '{"cloudflare":{"TYPE":"CLOUDFLAREAPI","apitoken":' > "$creds"
        printf '%s' "$CLOUDFLARE_DNS_TOKEN" | jq -Rs . >> "$creds"
        printf '%s\n' '}}' >> "$creds"
        chmod 600 "$creds"

        case "$mode" in
          preview)
            dnscontrol preview --no-colors --full --no-populate --ir ${ir} --creds "$creds" "''${domain_args[@]}"
            ;;
          drift-check)
            dnscontrol preview --no-colors --full --expect-no-changes --no-populate --ir ${ir} --creds "$creds" "''${domain_args[@]}"
            ;;
          apply)
            dnscontrol preview --no-colors --full --no-populate --ir ${ir} --creds "$creds" "''${domain_args[@]}"
            dnscontrol push --no-colors --full --no-populate --ir ${ir} --creds "$creds" "''${domain_args[@]}"
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
