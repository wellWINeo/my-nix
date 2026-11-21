#!/usr/bin/env bash
set -euo pipefail

flake='path:.'
cache='https://d3ktcuzmslp03i.cloudfront.net'
yandex_cache='https://storage.yandexcloud.net/nix-cache'
cache_key='nix-anysync-cache:8ig/2DyERXghDDOwhDJcjZaxx+A77HwREpQfSIh1oZc='

for host in mokosh veles stribog buyan nixpi do-generic; do
  settings=$(nix eval --json "$flake#nixosConfigurations.${host}.config.nix.settings")
  jq -e --arg cache "$yandex_cache" '(.substituters | index($cache)) != null' \
    <<<"$settings" >/dev/null || {
    echo "$host is missing the shared Yandex cache" >&2
    exit 1
  }
  if [[ "$host" == mokosh ]]; then
    jq -e --arg cache "$cache" --arg yandex_cache "$yandex_cache" --arg key "$cache_key" \
      '(.substituters | index($cache)) != null and (.substituters | index($yandex_cache)) < (.substituters | index($cache)) and (."trusted-public-keys" | index($key)) != null' \
      <<<"$settings" >/dev/null || {
      echo "Mokosh is missing the AnySync cache or its trusted key" >&2
      exit 1
    }
  else
    jq -e --arg cache "$cache" --arg key "$cache_key" \
      '(.substituters | index($cache)) == null and (."trusted-public-keys" | index($key)) == null' \
      <<<"$settings" >/dev/null || {
      echo "$host unexpectedly has the AnySync cache or its trusted key" >&2
      exit 1
    }
  fi
done
