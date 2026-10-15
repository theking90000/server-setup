# Rauthy as an independent application

The `rauthy` tag runs one native Rauthy instance backed by local Hiqlite.
Kanidm remains the provider for application SSO. Rauthy does not consume
`infra.sso` or register a client in Kanidm.

## Private configuration

Assign `rauthy` to one node and set these functional options in `config/`:

```nix
{
  infra.rauthy = {
    url = "https://auth.example.com";
    adminEmail = "admin@example.com";
    registrationEnabled = false;
    httpWorkers = 1;
    maxHashThreads = 1;
  };
}
```

The URL must be an HTTPS origin without a path or explicit port. Changing
the hostname later also changes the WebAuthn relying party ID, so existing
passkeys will need to be registered again.

HTTP and metrics bind to the node's WireGuard address, on ports 8081 and
9091 by default. Only `web-server` nodes can reach HTTP, and only
`prometheus` nodes can reach metrics. Hiqlite's Raft and API listen on
loopback. The module publishes `infra.ingress.rauthy` and
`infra.telemetry.rauthy` across the fleet.

Nginx requests the certificate through `infra.acme`. The DNS provider is a
deployment choice. A second domain at Cloudflare can coexist with an OVH
policy:

```nix
infra.acme.issuers.cloudflare = {
  match.suffixes = [ "example.com" ];
  email = "admin@example.com";
  dnsProvider = "cloudflare";
};
```

Keep the existing policy for other domains. Configure public DNS records to
reach the `web-server` nodes. DNS-01 does not require a public HTTP challenge.

## Secrets

`init-project` creates `secrets/rauthy.json` when the tag is present. Its
`environment` key contains a systemd environment file with these variables:

```text
ENC_KEY_ACTIVE=initial
ENC_KEYS=initial/<base64-encoded 32-byte key>
HQL_SECRET_RAFT=<random secret of at least 16 characters>
HQL_SECRET_API=<different random secret of at least 16 characters>
BOOTSTRAP_ADMIN_PASSWORD_PLAIN=<initial administrator password>
```

The initializer generates all five values. Edit the encrypted file with
`sops secrets/rauthy.json`; never commit a plaintext environment file.
systemd reads the root-only SOPS file at startup. Secret changes restart
Rauthy. The bootstrap password applies only to an empty database; changing
it later does not reset an existing administrator's password.

Preserve the encryption key and its ID with the database backups. To rotate
keys, retain the old keys while migrating encrypted data in Rauthy. Multiple
`ENC_KEYS` entries require a quoted multiline environment value, with one
`ID/base64-key` per line.

The Cloudflare policy reads `issuers.cloudflare.dnsCredentials` in the
existing `secrets/acme.json`. Its value is:

```text
CF_DNS_API_TOKEN=<Cloudflare API token>
```

Grant `Zone:Read` and `DNS:Edit` for the relevant zone. The token is required
on each Nginx node that issues a certificate for the domain. `init-project`
uses the selected provider when creating a new ACME file. It preserves an
existing file, so add the new issuer manually with `sops secrets/acme.json`.

## Email

SMTP is optional. Without it, Rauthy starts but cannot deliver verification
or password reset emails. Enable it with functional choices in `config/`:

```nix
infra.rauthy.smtp = {
  host = "smtp.example.com";
  port = 465;
  from = "Rauthy <auth@example.com>";
};
```

Add `SMTP_USERNAME` and `SMTP_PASSWORD` to the encrypted `environment` value
when authentication is required. Use systemd environment-file quoting for
values containing spaces, quotes or newlines. For STARTTLS on port 587,
also set `startTlsOnly = true`. TLS verification remains enabled.

## Backups and restoration

The service stores data under `/var/lib/rauthy`. Hiqlite creates native,
consistent SQLite backups every hour at minute 30 and retains three days
locally. User pictures use the default database storage and are included.

The module registers `/var/lib/rauthy/data/state_machine/backups` for
Restic. On nodes tagged `backup`, preparation rejects a run if there is no
export between one minute and two hours old. After a first deployment,
wait for the first scheduled export before taking a Restic backup.
The newest export may still be writing; select a completed export for
restoration. Hourly exports can lose up to an hour of changes before the
Restic run.

To restore, stop Rauthy, preserve its existing data directory for recovery,
and recover a completed `backup_node_1_*.sqlite` from Restic. Place it in a
path readable by the `rauthy` user under `/var/lib/rauthy`, restore the
corresponding SOPS encryption keys, then temporarily add
`HQL_BACKUP_RESTORE=file:/var/lib/rauthy/<backup-file>.sqlite` to the
encrypted environment. Start Rauthy and check that restoration succeeds.
Remove `HQL_BACKUP_RESTORE` immediately afterward so the next start does not
restore the same backup again.

References: [Rauthy configuration](https://sebadob.github.io/rauthy/config/config.html),
[backup restoration](https://sebadob.github.io/rauthy/config/backup.html),
[key rotation](https://sebadob.github.io/rauthy/config/encryption.html), and
[Cloudflare credentials for Lego](https://go-acme.github.io/lego/dns/cloudflare/).
