# Select Named Proxy Users

## Goal

Use explicit `singBoxUsers` names for proxy authentication instead of relying on list order:

- nixpi authenticates to Veles with the user named `nixpi`.
- Veles authenticates to Buyan with the user named `veles`.

## Design

Add `common/select-proxy-user.nix`, a helper that filters `singBoxUsers` by exact `name` and requires exactly one match. Missing or duplicate names must fail evaluation with a clear error.

Use the helper in `machines/nixpi/default.nix` and `machines/veles/default.nix`. Keep `common/filter-proxy-users.nix` unchanged; its hostname-based filtering continues to control inbound authorization.

## Validation

- Evaluate nixpi, Veles, and Buyan configurations with dummy secrets.
- Confirm the selected users are `nixpi` and `veles`.
- Confirm missing and duplicate names fail evaluation.
- Run `nixfmt`, `git diff --check`, and `make check`.
