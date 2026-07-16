# Managing Kanidm from the CLI

This guide covers Kanidm 1.10.2 and its integration in this repository.
`kanidm` performs routine operations through the HTTPS API. `kanidmd` accesses
the server database directly and is reserved for recovery and offline
maintenance.

## What Nix manages and what Kanidm manages

| Item | Managed by |
|---|---|
| Server, URL, and backups | NixOS |
| OAuth2 clients, callbacks, and claims | Application modules through `infra.sso.<name>` |
| Application group names | NixOS |
| People and credentials | Kanidm CLI or interface |
| Group membership | Kanidm CLI or interface |

Application groups are created with `overwriteMembers = false`. A redeployment
therefore preserves members added through the CLI. Do not manually modify a
client with `kanidm system oauth2`, however: its definition is declarative and
the next deployment may restore the Nix value.

## Installing and configuring the client

With Nix, open a shell that contains the same major version as the server:

```sh
nix shell nixpkgs#kanidm_1_10
```

Create `~/.config/kanidm` on the administrator workstation:

```toml
uri = "https://auth.example.com"
```

Use the public HTTPS URL declared in `infra.kanidm.url`. Its certificate is
valid, so do not add `verify_ca = false` or `--accept-invalid-certs`. For a
one-off command, `-H https://auth.example.com` overrides the file.

## Logging in

`idm_admin` is the initial recovery account for people and groups:

```sh
kanidm login -D idm_admin
kanidm self whoami -D idm_admin
```

In the private repository, its stable password is stored in
`secrets/kanidm.json`. To view it without placing it in the shell history:

```sh
sops decrypt --extract '["idm_admin_password"]' secrets/kanidm.json
```

A write operation may request authentication again, like `sudo`:

```sh
kanidm reauth -D idm_admin
```

Sessions are local to the workstation:

```sh
kanidm session list
kanidm session cleanup
kanidm logout -D idm_admin
```

Do not use `idm_admin` for routine work. Create a named account and grant it
only the required administrative roles.

## Creating and initializing a person

A newly created person has no credentials:

```sh
kanidm person create alice "Alice Example" -D idm_admin
kanidm person update alice \
  --legalname "Alice Example" \
  --mail "alice@example.com" \
  -D idm_admin
kanidm person get alice -D idm_admin
```

Then generate an enrollment link valid for one hour:

```sh
kanidm person credential create-reset-token alice --ttl 3600 -D idm_admin
```

Send the link or QR code directly to the person. The token can be used only
once. The person then chooses their password, TOTP, or passkeys.

For an assisted reset, run the command again. Editing credentials directly is
still possible, but should remain exceptional:

```sh
kanidm person credential status alice -D idm_admin
kanidm person credential update alice -D idm_admin
```

## Managing groups and permissions

Always query the server first:

```sh
kanidm group list -D idm_admin
kanidm group search grafana -D idm_admin
kanidm group get grafana_admins -D idm_admin
kanidm group list-members grafana_admins -D idm_admin
```

Create a group and add several people:

```sh
kanidm group create my_group -D idm_admin
kanidm group add-members my_group alice bob -D idm_admin
kanidm group list-members my_group -D idm_admin
```

Remove only selected members:

```sh
kanidm group remove-members my_group bob -D idm_admin
```

`set-members` replaces the complete list. It therefore removes every member
that is not specified; use it only when this behavior is intended:

```sh
kanidm group set-members my_group alice charlie -D idm_admin
```

A group can also be a member of another group. This command grants the members
of `dev_team` the access assigned to `gitea_users`:

```sh
kanidm group add-members gitea_users dev_team -D idm_admin
```

Check both sides of the membership:

```sh
kanidm group list-members gitea_users -D idm_admin
kanidm person get alice -D idm_admin
```

For automated processing:

```sh
kanidm -o json group list -D idm_admin
```

The main Kanidm roles used for operations are:

| Group | Permission |
|---|---|
| `idm_people_admins` | Create and manage people |
| `idm_group_admins` | Create and manage groups |
| `idm_service_desk` | Help with resets and account issues |
| `idm_recycle_bin_admins` | View and restore the recycle bin |
| `idm_oauth2_admins` | Manage OAuth2 integrations |
| `idm_admins` | Broad role for managing people and groups |

Prefer targeted roles over `idm_admins`. The server's current list and
descriptions remain the source of truth: inspect each group with
`kanidm group get` before granting it.

For example, to delegate the management of people, groups, and restores to
`alice` without granting full domain administration:

```sh
kanidm group add-members idm_people_admins alice -D idm_admin
kanidm group add-members idm_group_admins alice -D idm_admin
kanidm group add-members idm_recycle_bin_admins alice -D idm_admin
```

`alice` must then log in again, or run `kanidm reauth -D alice`, to obtain an
up-to-date privileged session. The `idm_oauth2_admins` role is not required for
clients generated through `infra.sso`, because Nix manages them.

## Granting access to applications

### Gitea

The Gitea integration creates a single access group without an associated
Gitea role or permission:

```sh
kanidm group add-members gitea_users alice -D idm_admin
kanidm group list-members gitea_users -D idm_admin
```

Removing a person from this group prevents new OIDC authorizations to Gitea
without deleting their local Gitea account:

```sh
kanidm group remove-members gitea_users alice -D idm_admin
```

On the first login, an existing local Gitea account must confirm its local
password to establish the link. Administrator and restricted statuses remain
managed in Gitea.

### Grafana

The Grafana integration automatically creates:

| Group | Grafana level |
|---|---|
| `grafana_viewers` | Viewer |
| `grafana_editors` | Editor |
| `grafana_admins` | Grafana organization administrator |

Add a person to only one Grafana level:

```sh
kanidm group add-members grafana_viewers alice -D idm_admin
kanidm group list-members grafana_viewers -D idm_admin
```

To change their level, first remove the old group:

```sh
kanidm group remove-members grafana_viewers alice -D idm_admin
kanidm group add-members grafana_editors alice -D idm_admin
```

Revocation follows the same procedure:

```sh
kanidm group remove-members grafana_editors alice -D idm_admin
```

Future applications will follow the `<client>_<role>` convention. Use
`kanidm group search <client>` to discover the roles that are actually
available.

## Blocking or deleting an account

To immediately block new authentication attempts without deleting the person:

```sh
kanidm person validity expire-at alice now -D idm_admin
```

To reactivate the person:

```sh
kanidm person validity expire-at alice clear -D idm_admin
```

Deletion moves the person to the recycle bin:

```sh
kanidm person delete alice -D idm_admin
kanidm recycle-bin list -D idm_admin
```

To restore an entry, use the UUID shown by the recycle bin:

```sh
kanidm recycle-bin get <uuid> -D idm_admin
kanidm recycle-bin revive <uuid> -D idm_admin
kanidm person get alice -D idm_admin
```

The recycle bin provides short-term, best-effort recovery. After restoring an
entry, check its groups and add any missing memberships again.

## Checking the Grafana OAuth2 integration

The following commands are read-only:

```sh
kanidm system oauth2 list -D idm_admin
kanidm system oauth2 get grafana -D idm_admin
curl -fsS https://auth.example.com/oauth2/openid/grafana/.well-known/openid-configuration
```

Kanidm normally requests consent on first access and when the requested scopes
change. For this internal application that the administrator has already
approved, disable the consent prompt after the first deployment:

```sh
kanidm system oauth2 disable-consent-prompt grafana -D idm_admin
```

The current Kanidm provisioner cannot declare this setting yet. Run the command
once; its value is retained in the Kanidm database and its backups.

This command is the only expected manual change to the Grafana client. Do not
run `reset-basic-secret`, `delete`, `set-name`, or modify its scopes: Nix owns
its definition.

## Selecting the OIDC `preferred_username` claim

Kanidm does not provide a second arbitrary per-person alias for
`preferred_username`. For each OAuth2 client, it selects between two existing
attributes:

| Mode | Claim sent for `alice` | Command |
|---|---|---|
| Short name (`name`) | `alice` | `prefer-short-username` |
| SPN (`spn`) | `alice@auth.example.com` | `prefer-spn-username` |

To test the SPN with Gitea:

```sh
kanidm system oauth2 prefer-spn-username gitea -D idm_admin
kanidm system oauth2 get gitea -D idm_admin
```

To return to the short name:

```sh
kanidm system oauth2 prefer-short-username gitea -D idm_admin
```

In this repository, the Gitea client is declarative and currently uses the
short name. A CLI change will therefore be reverted by the next deployment. To
use the SPN permanently, add the following setting to `infra.sso.gitea` in
[`nixos/modules/applications/gitea.nix`](../nixos/modules/applications/gitea.nix),
then commit, update the private input, and redeploy:

```nix
infra.sso.gitea = {
  # ...
  preferShortUsername = false;
};
```

This setting applies to every user of the `gitea` client. It cannot assign a
different OIDC alias to each person. Renaming a person with the following
command changes their actual Kanidm `name`, and therefore also their login
identifier; it is not an alias:

```sh
kanidm person update alice --newname alice2 -D idm_admin
```

Changing `preferred_username` does not rename an already linked Gitea account:
Gitea subsequently resolves the identity through its stable OIDC identifier.
For an unlinked first login, the SPN contains `@` and Gitea may normalize it to
form a local username; the short name is therefore the more predictable choice
here.

## Recovery with `kanidmd`

`kanidmd` opens the database directly. Run it only on the Kanidm node, with the
service stopped and the same package as the active system.

The NixOS module generates `server.toml` in the store. Find its path after `-c`
in the unit:

```sh
sudo systemctl cat kanidm.service
```

Then replace `<server.toml>` with that exact path:

```sh
sudo systemctl stop kanidm.service
sudo -u kanidm kanidmd recover-account -c <server.toml> admin
sudo systemctl start kanidm.service
```

This command produces a new password: treat it as a secret immediately. For
`idm_admin`, the SOPS file is the source of truth and the provisioner reapplies
its value at startup. Read that file, or modify it and redeploy; an isolated
`kanidmd recover-account idm_admin` would be overwritten after a restart.

## Full backup and restore

The server creates online backups in `/var/lib/kanidm/backups`. The Restic
module also backs up `/var/lib/kanidm`. Check their presence regularly:

```sh
sudo systemctl status kanidm.service
sudo journalctl -u kanidm.service --since today
sudo ls -lah /var/lib/kanidm/backups
```

A full restore is destructive. Use exactly the same Kanidm version that created
the backup, stop the service, and preserve a copy of the current state before
running:

```sh
sudo systemctl stop kanidm.service
sudo -u kanidm kanidmd database restore -c <server.toml> <backup>
sudo systemctl start kanidm.service
```

After the restore, check people, groups, and OAuth2 clients before reopening
application access.

## Official sources

- [CLI client configuration and sessions](https://kanidm.github.io/kanidm/stable/client_tools.html)
- [Group management and nesting](https://kanidm.github.io/kanidm/stable/accounts/groups.html)
- [OAuth2 and short-name or SPN selection](https://kanidm.github.io/kanidm/master/integrations/oauth2.html#short-names)
- [Accounts and groups](https://kanidm.github.io/kanidm/master/accounts/intro.html)
- [People](https://kanidm.github.io/kanidm/master/accounts/people_accounts.html)
- [Credentials and resets](https://kanidm.github.io/kanidm/master/accounts/authentication_and_credentials.html)
- [Access control and roles](https://kanidm.github.io/kanidm/master/access_control/intro.html)
- [Recycle bin](https://kanidm.github.io/kanidm/master/recycle_bin.html)
- [Backup and restore](https://kanidm.github.io/kanidm/master/backup_and_restore.html)
