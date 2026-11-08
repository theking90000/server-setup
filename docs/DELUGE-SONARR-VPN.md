# Deluge and independent Servarr silly instances

Assign `applications/deluge`, `applications/sonarr-silly`,
`applications/radarr-silly`, `applications/prowlarr-silly` and
`applications/qbittorrent` to the same node. Deluge and the silly instances reuse
qBittorrent's existing provider VPN namespace. No second WireGuard profile
is needed.

The existing `applications/sonarr` and `applications/radarr` remain separate,
with their own URLs, users, API keys, databases and ports. All application
instances run on `rpi1`:

| Instance | Unit | State | Mesh port |
| --- | --- | --- | --- |
| Existing Sonarr | `sonarr.service` | `/var/lib/sonarr` | 8989 |
| Existing Radarr | `radarr.service` | `/var/lib/radarr` | 7878 |
| Silly Prowlarr | `prowlarr-silly.service` | `/var/lib/prowlarr-silly` | 9697 |
| Silly Radarr | `radarr-silly.service` | `/var/lib/radarr-silly` | 7879 |
| Silly Sonarr | `sonarr-silly.service` | `/var/lib/sonarr-silly` | 8990 |
| Silly Deluge | `deluged.service`, `deluge-web.service` | `/var/lib/deluge` | 8112 |

The private `config/` contains functional choices only:

```nix
{
  infra.deluge = {
    url = "https://deluge.silly.6700067.xyz";
    dataDirectory = "/srv/deluge-media";
  };
  infra.sonarrSilly.url = "https://sonarr.silly.6700067.xyz";
  infra.radarrSilly.url = "https://radarr.silly.6700067.xyz";
  infra.prowlarrSilly.url = "https://prowlarr.silly.6700067.xyz";
}
```

## DNS, HTTPS and authentication

All silly DNS records are CNAMEs targeting `lb.theking90000.be`. The public entry
forwards HTTPS requests to the Pi over its WireGuard mesh IP. The modules
register their ingress and ACME claims; configure the matching ACME issuer
in the private repository.

`init-project` creates encrypted `secrets/deluge.json` and
`secrets/sonarr-silly.json` / `secrets/radarr-silly.json`. All public interfaces use HTTP Basic
authentication with username `admin`. The generated password is
`webui_password` in `secrets/deluge.json`; `proxy_htpasswd` contains its
bcrypt hash for nginx. Update both fields together when rotating it.
Deluge additionally requires the same password in its WebUI. Sonarr and Radarr silly
use external authentication behind nginx. The existing Sonarr's SSO
configuration is independent.

## Storage and network isolation

All new applications join `/run/netns/qbittorrent`, inherit its provider
VPN routes and stop when `qbittorrent-netns.service` stops. Their restart
relationships also follow a namespace restart. The existing Sonarr keeps
its existing networking.

A separate `deluge-vpn-guard.service` filters the new WebUI ports inside
that namespace, without filtering qBittorrent's or JOAL's ports. These
interfaces accept connections from loopback and the host relay veth only.
New outgoing connections from the new application users to the host
veth are rejected. The host firewall permits only root-owned local relays
to connect to these new WebUI ports. Deluge RPC listens on loopback.

The host relays listen on the Pi's mesh IP, with ACLs for `web-server`
nodes and local root. No application port opens on the public interface.

Each application has its own Unix user and private state. Sonarr, Radarr and
Deluge can write `/srv/deluge-media`, shared through the `media-silly` group
with fixed GID `2001` and setgid directories. All four application accounts
belong to `media-silly`. Prowlarr has access to its own state only and does
not bind the shared media directory. Private mount namespaces mask other contents of `/var/lib`,
`/srv` and `/mnt`, including the existing media library. Homes, runtime
SOPS secrets, backups and host logs are inaccessible. System files are
read-only; public system files and packages remain readable as needed.

Restic includes the new application state and a consistent SQLite snapshot
for Sonarr and Radarr silly. Bulk downloads and series in `/srv/deluge-media` are not
included automatically.

## First application setup

Deluge initially downloads to `/srv/deluge-media/downloads` and its WebUI
connects to its local daemon. Preferences and torrents persist. Its WebUI
password is imposed at every restart.

In Sonarr silly, add `/srv/deluge-media/series` as a root folder. Add a
Deluge download client using host `10.200.0.2`, port `8112`, no TLS and the
Deluge WebUI password. Use category `sonarr-silly`. Indexers and quality
profiles remain configured through the UI, as for the existing Sonarr.
For Radarr silly use root folder `/srv/deluge-media/movies` and category
`radarr-silly` on the same Deluge client. The shared local paths need no
remote path mapping.

Prowlarr uses `/api/v1`; configure Sonarr and Radarr as applications using
their internal namespace URLs and dedicated API keys. Their Prowlarr URL is
`http://10.200.0.2:9697`. Add indexers to Prowlarr and sync them to the silly
instances; the existing original instances remain independent.

## Verification and deployment

Run the public flake checks and evaluate the private Colmena fleet. Build
`rpi1` before switching it, then deploy the web entry nodes for ingress and
certificates. When testing local public changes, use a temporary private
flake with an `infra` input override; do not persist a machine-specific
path in the private lock file.

After activation, verify all original and silly instances, the new namespace bindings,
DNS, HTTPS authentication, protected paths and an import. Check that the
new applications have no Internet fallback when the provider interface is
down, and restore it immediately. Namespace or tunnel changes also affect
qBittorrent and JOAL, so prefer a separate temporary namespace for destructive
network tests.

## Shared media group

`infra.servarrSilly.mediaGroup` exposes the group's `name`, `gid` and local
`enable` status. Align a silly FUSE mount with these values, using
`gid=${toString config.infra.servarrSilly.mediaGroup.gid}` and `umask=007`.
The original stack keeps its separate `media` group and GID `2000`.

When migrating from the older `deluge-media` group, stop the silly services,
change only the files with that old GID under the shared data directory to
`media-silly`, then restart the services. Preserve file owners, modes and
application state. The application's systemd mount restrictions still apply
independently of its Unix group membership.
