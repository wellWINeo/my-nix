{ pkgs, apps }:
pkgs.runCommand "dns-app-safety-test"
  {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.gnugrep
    ];
  }
  ''
    set -euo pipefail

    checkMissingToken() {
      local executable="$1"
      local output
      if output="$(env -u CLOUDFLARE_DNS_TOKEN "$executable" 2>&1)"; then
        printf '%s\n' "expected $executable to reject a missing token" >&2
        exit 1
      fi
      test "$output" = 'CLOUDFLARE_DNS_TOKEN must be set'
    }

    checkMissingToken ${apps.preview}/bin/dns-preview
    checkMissingToken ${apps.driftCheck}/bin/dns-drift-check
    checkMissingToken ${apps.apply}/bin/dns-apply

    for executable in \
      ${apps.preview}/bin/dns-preview \
      ${apps.driftCheck}/bin/dns-drift-check \
      ${apps.apply}/bin/dns-apply; do
      test "$(grep -Fc -- '--no-populate --ir ' "$executable")" -eq 4
      test "$(grep -Fc -- '--creds "$creds"' "$executable")" -eq 4
    done

    touch "$out"
  ''
