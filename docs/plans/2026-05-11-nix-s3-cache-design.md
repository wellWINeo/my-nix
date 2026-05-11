# Nix S3 Binary Cache

## Goal

Use a Yandex.Cloud Object Storage bucket (`nix-cache`) as a Nix binary cache.
A GitHub Action builds packages on demand and uploads closures to S3. NixOS
machines pull from the public bucket as a substituter, avoiding builds on
cheap VPS hardware.

## Requirements

- Manual-dispatch GitHub Action: user provides a package spec (e.g.
  `nixpkgs#telemt`), action builds and uploads the closure to S3
- Public-read S3 bucket — no credentials needed on consumer machines
- Nix signing keys for trust verification
- `common/cache.nix` module imported by all NixOS machines
- Scope: x86_64-linux only (matches free GitHub runners)

## Architecture

```
GitHub Action (manual dispatch)
  input: package spec (e.g. "nixpkgs#telemt")
  → nix build <package>
  → nix copy --to s3://nix-cache (signed with private key)

Yandex.Cloud S3 (nix-cache bucket, public read)
  → stores NAR files + narinfo + nix-cache-info

NixOS machines
  → common/cache.nix adds substituter + trusted-public-key
  → nix pulls from cache.nixos.org first, then S3 bucket
```

## Components

### 1. GitHub Action (`build-cache.yml`)

Trigger: `workflow_dispatch` with input `package`.

Steps:
1. Checkout + install Nix (existing pattern from `check.yml`)
2. `nix build <package>` — builds the derivation
3. `nix copy --to 's3://nix-cache?...'` with `--option secret-key-files` —
   signs and uploads the full closure

Required GitHub Secrets:

| Secret | Description |
|--------|-------------|
| `YC_S3_ACCESS_KEY` | Yandex.Cloud static access key ID |
| `YC_S3_SECRET_KEY` | Yandex.Cloud static secret key |
| `NIX_CACHE_PRIVATE_KEY` | Full contents of the Nix signing private key |

### 2. NixOS Substituter (`common/cache.nix`)

```nix
{ lib, ... }:
{
  nix.settings = {
    substituters = lib.mkAfter [ "https://storage.yandexcloud.net/nix-cache" ];
    trusted-public-keys = [ "nix-cache-1:<public-key>" ];
  };
}
```

- `mkAfter` keeps `cache.nixos.org` as primary substituter
- Public HTTPS — no AWS credentials on machines
- Imported by each machine's `imports` list

### 3. Signing Keys

Generated once:

```bash
nix-store --generate-binary-cache-key nix-cache-1 \
  ./cache-private-key.pem ./cache-public-key.pem
```

- Private key → GitHub Secret `NIX_CACHE_PRIVATE_KEY` (CI only)
- Public key → hardcoded in `common/cache.nix` (it's public by nature)

### 4. Yandex.Cloud Bucket Setup (Manual)

```bash
aws --endpoint-url=https://storage.yandexcloud.net \
    --region ru-central1 \
    s3 mb s3://nix-cache
```

Bucket policy: public read (`s3:GetObject`, `s3:GetBucketLocation` for
`Principal: *`). Writes require authenticated static key.

## Files Changed

| File | Action |
|------|--------|
| `.github/workflows/build-cache.yml` | Create |
| `common/cache.nix` | Create |
| `machines/mokosh/default.nix` | Edit — add `../../common/cache.nix` import |
| `machines/veles/default.nix` | Edit — add `../../common/cache.nix` import |
| `machines/buyan/default.nix` | Edit — add `../../common/cache.nix` import |
| `machines/nixpi/default.nix` | Edit — add `../../common/cache.nix` import |

## S3 Store URL

```
s3://nix-cache?region=ru-central1&scheme=https&endpoint=storage.yandexcloud.net
```

Yandex.Cloud specifics:
- Endpoint: `storage.yandexcloud.net`
- Region: `ru-central1`
- HTTPS only
- Path-based addressing (compatible with Nix S3 store)

## Usage

Push a package to cache:

```bash
# Via GitHub CLI
gh workflow run build-cache.yml -f package=nixpkgs#telemt

# Or trigger in GitHub Actions UI
```

Verify on a machine:

```bash
nix path-info --store https://storage.yandexcloud.net/nix-cache nixpkgs#telemt
```
