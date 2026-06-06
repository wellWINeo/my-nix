{ ... }:

# Stable UID/GID assignments for service users on this host.
# Pinned to prevent ownership drift across reinstalls/restores.
# DynamicUser services (miniflux) are omitted — systemd keeps those stable.
{
  users.users.vaultwarden.uid  = 992;
  users.groups.vaultwarden.gid = 990;

  users.users.postgres.uid  = 71;
  users.groups.postgres.gid = 71;

  users.users.stalwart-mail.uid  = 993;
  users.groups.stalwart-mail.gid = 991;

  users.users.writefreely.uid  = 991;
  users.groups.writefreely.gid = 989;

  users.groups.calibre.gid = 993;
}
