# Setting up an infrastructure from start to finish

This guide starts with a workstation that has Nix and one or more fresh Debian
servers. It produces a checked NixOS fleet deployed with Colmena, WireGuard,
SOPS, and the public `server-setup` modules.

> **Warning:** `infect-server` replaces the server's operating system. Use it
> only on a new or backed-up machine. Check the IP address, SSH port, and access
> key before running the command.

## 1. What belongs in each repository

The public repository contains the reusable NixOS modules, scripts, and
template. Your private repository contains only:

- `inventory/nodes.nix`: topology, tags, and SSH settings;
- `config/`: URLs and functional choices;
- `secrets/`: JSON files encrypted with SOPS;
- hardware configuration fetched from the machines;
- optional modules specific to this infrastructure.

SOPS is integrated into `infra.nixosModules.default`. Each public module
declares its own secrets; the private repository does not duplicate a central
adapter.

## 2. Requirements

On the administration workstation:

- Nix with `nix-command` and `flakes` enabled;
- an Ed25519 SSH key that can access the servers;
- Git;
- access to the account that manages the DNS zone;
- credentials for Restic or Rclone storage if those roles are enabled.

Install Nix from the [official page](https://nixos.org/download/) and check
access to the flake:

```sh
nix flake show github:theking90000/server-setup
```

For each server, record its public IPv4 address, optional IPv6 address and
gateway, public network interface, Debian user, initial SSH port, and SSH key.

## 3. Creating the private repository

One command copies the template, initializes Git, and creates the first commit:

```sh
nix run github:theking90000/server-setup#bootstrap-project -- ./my-infra
cd ./my-infra
```

If the initial commit fails because Git does not have an identity yet, the
files have already been copied. Configure `user.name` and `user.email`, then
finish in the created directory with
`git add -A && git commit -m "Initial commit"`.

Then create a **private** Git repository with your hosting provider. Never
publish this repository, even though the SOPS files are encrypted: its topology
is still sensitive.

## 4. Describing the nodes

Edit `inventory/nodes.nix`. Each attribute name becomes the Colmena node name
and its NixOS hostname.

```nix
{
  nodes.vps1 = {
    publicIp = "203.0.113.10";
    vpnIp = "10.100.0.1";
    ipv6 = "2001:db8::10";
    ipv6Gateway = "2001:db8::1";
    publicInterface = "ens3";
    useDHCP = true;
    sshKey = "~/.ssh/id_ed25519";
    sshPort = 22;
    tags = [
      "web-server"
      "node-metrics"
      "backup"
    ];
  };
}
```

| Field | Value |
|---|---|
| `publicIp` | IPv4 address reachable by SSH and Colmena |
| `vpnIp` | Unique private mesh address, for example `10.100.0.x` |
| `ipv6`, `ipv6Gateway` | Provider values, or `null` when unused |
| `publicInterface` | Actual interface: `ens3`, `eth0`, `enp1s0`, etc. |
| `useDHCP` | `true` when the provider configures IPv4 through DHCP |
| `sshKey` | Local private key used for root access after infection |
| `sshPort` | **Final** NixOS SSH port, identical to `--post-port` |
| `tags` | Services enabled on this node |

Every `vpnIp` must be unique. Evaluation intentionally rejects unknown tags to
catch typing errors.

### Common tags

| Tag | Function |
|---|---|
| `web-server` | Public Nginx, HTTPS ingress, and local ACME issuance |
| `node-metrics` | Node Exporter |
| `prometheus` | Metrics collection |
| `grafana` | Visualization and dashboards |
| `backup` | Restic backup of registered paths |
| `kanidm` | Identity and SSO |
| `applications/gitea` | Git forge |
| `applications/docker-registry` | Private OCI registry |
| `applications/jellyfin` | Media server |
| `applications/ntfy` | Notifications |
| `applications/filesave-server` | File sharing |
| `applications/reposilite` | Maven repository |
| `applications/rust-storage-streamer` | Discord-backed Files and S3 gateways |
| `applications/www` | Static website |
| `raspberry-pi` | Raspberry Pi 5 hardware modules from the template |

Rclone has no tag: each mount directly names its `targetNodes`.

## 5. Selecting services and preparing DNS

Edit only files for services whose tag is enabled in the fleet. `config/` must
contain only non-secret values: URLs, ports, or features.

```nix
{
  infra.gitea = {
    url = "https://git.example.com";
    registrationEnabled = false;
  };
}
```

Replace the `CHANGEME` values for enabled services. A configuration file can
remain imported and unchanged if no node uses its tag: its values are not
evaluated in that case. A Nix syntax error is always fatal because every
imported file must be parseable.

For each public URL, create the following records in your DNS zone:

- an `A` record pointing to the IPv4 address of the `web-server` node;
- an `AAAA` record pointing to its IPv6 address if IPv6 is actually routed;
- no record pointing to the WireGuard IP address.

All public services enter through Nginx. Nginx then reaches applications over
the WireGuard mesh and automatically derives ACME domains from ingresses.

### OVH credentials for Lego/ACME

The template uses the `ovh` DNS provider. Configure the issuance policy —
the suffix covers its apex and every subdomain, and each node issues locally
the certificates its own services consume:

```nix
{
  infra.acme.issuers.primary = {
    match.suffixes = [ "example.com" ];
    email = "admin@example.com";
    dnsProvider = "ovh";
  };
}
```

Create dedicated OVH credentials on the
[OVH token creation page](https://www.ovh.com/auth/api/createToken). For
Application Key authentication, Lego expects:

```text
OVH_ENDPOINT=ovh-eu
OVH_APPLICATION_KEY=...
OVH_APPLICATION_SECRET=...
OVH_CONSUMER_KEY=...
```

The Consumer Key must at least be allowed to create and delete records in the
zone (`POST /domain/zone/*` and `DELETE /domain/zone/*`). Use `ovh-ca` instead
of `ovh-eu` for a Canadian account. Do not mix this method with OVH OAuth
credentials. The official list and alternative IAM policies are documented by
[Lego](https://go-acme.github.io/lego/dns/ovh/).

These values never go in `config/acme/acme.nix`. You will enter them in
`secrets/acme.json` after initialization.

## 6. Entering the environment

```sh
nix develop
```

The development shell provides Colmena, SOPS, WireGuard, and all project
scripts. If you use `direnv`, the provided `.envrc` already contains
`use flake`; authorize the directory with `direnv allow`.

## 7. Infecting the servers

First check Debian access manually:

```sh
ssh -i ~/.ssh/id_ed25519 -p 22 debian@203.0.113.10
```

Then run the infection for each machine:

```sh
infect-server \
  -i ~/.ssh/id_ed25519 \
  -p 22 \
  --post-port 22 \
  debian@203.0.113.10
```

- `-p` is the SSH port of the initial Debian system;
- `--post-port` is the final NixOS port set in `nodes.nix`;
- the initial user can be `debian`, `ubuntu`, or `root`, with `sudo` when
  required;
- after infection, the scripts and Colmena connect as `root`.

The script installs the public key before rebooting, pins and checks the
`nixos-infect` hash, then waits for SSH to return. If the host already runs
NixOS, it does not infect it again.

## 8. Initializing the project

One command prepares everything it can:

```sh
init-project
```

It performs the following steps idempotently:

1. generates missing WireGuard key pairs;
2. fetches hardware configuration;
3. exports administration SSH public keys;
4. creates or updates the administrator Age identity;
5. reads each server's host SSH key through an authenticated connection;
6. generates `.sops.yaml` and transactionally re-encrypts existing files when
   recipients have changed;
7. creates missing standard secret files.

An existing secret is never replaced. If a host key cannot be read or
re-encryption fails, `update-sops-keys` replaces neither the old configuration
nor the old files.

### Administrator Age identity

The default path follows the SOPS convention:

| System | Path |
|---|---|
| macOS | `~/Library/Application Support/sops/age/keys.txt` |
| Linux | `${XDG_CONFIG_HOME:-~/.config}/sops/age/keys.txt` |

The file is created with mode `0600`. Back it up in a secure vault: it can
administer every project secret. To use a different path, export
`SOPS_AGE_KEY_FILE` before using the scripts.

The current policy is deliberately simple: the administrator identity and the
host SSH keys of **all** nodes are recipients of **all** SOPS files.

## 9. Completing external secrets

At the end, `init-project` prints the exact file and field for every remaining
`CHANGEME` value. Edit them with SOPS:

```sh
sops secrets/acme.json
sops secrets/restic.json
sops secrets/docker-registry.json
sops secrets/rclone-sync.json
```

Do not use an editor that writes a plaintext copy into the repository. `sops`
decrypts into a protected temporary file, then writes the encrypted file again.

| File | Field | Source |
|---|---|---|
| `wireguard/<host>.json` | `privateKey` | Generated automatically |
| `acme.json` | `issuers.<name>.dnsCredentials` | OVH/Lego credentials to provide |
| `restic.json` | `repository` | Repository URL to provide |
| `restic.json` | `password` | Generated automatically |
| `restic.json` | `env` | Backend credentials to provide |
| `grafana.json` | `password`, `grafana_secret` | Generated automatically |
| `grafana.json` | `oidc_client_secret` | Generated when Grafana is active |
| `gitea.json` | `oidc_client_secret` | Generated when Gitea and Kanidm are active |
| `jellyfin.json` | `jellarr_api_key` | Generated when Jellyfin is active |
| `kanidm.json` | `idm_admin_password` | Generated when an SSO client is active |
| `docker-registry.json` | `accounts` | htpasswd contents to provide |
| `rust-storage-streamer.json` | `webhooks` | One Discord `<id>:<token>` per line |
| `rclone-sync.json` | key named after the mount | Complete `rclone.conf` to provide |

For the registry, generate a bcrypt htpasswd line without permanently
installing a tool:

```sh
nix shell nixpkgs#apacheHttpd -c htpasswd -Bbn my-user
```

Copy the generated line into the `accounts` field with `sops`. For Restic,
`repository` is, for example, an `s3:...` URL; `env` contains the variables
required by that backend, one per line. For Rclone, the field value is the
complete contents of a working configuration, including its `remote` section
and optional `crypt` section.

Rust Storage Streamer exposes Files only through an SSH tunnel:

```sh
ssh -L 8080:127.0.0.1:8080 root@<host>
```

Create S3 credentials after deployment from the protected catalog:

```sh
database='sqlite:///var/lib/rust-storage-streamer-s3/s3-catalog.db?mode=rwc'
sudo -u rust-storage-streamer-s3 \
  streamer-s3-discord --database-url "$database" \
  credential create --can-create-buckets
```

## 10. Checking and deploying

```sh
check-project
```

The command:

- rejects any `CHANGEME` in decrypted values without printing those values;
- rejects secret wiring under `config/`;
- runs `nix flake check --all-systems`;
- evaluates the `drvPath` of every Colmena node.

Deploy one canary node first:

```sh
deploy-project vps1
```

`deploy-project` runs initialization and checks again before
`colmena apply --on vps1`. After checking the canary, deploy the full fleet:

```sh
deploy-project
```

On the canary, check at least:

```sh
ssh root@203.0.113.10 systemctl --failed
ssh root@203.0.113.10 systemctl status wireguard-wg0
```

Then test the public URLs, certificates, metrics, backups, and SSO associated
with the tags that are actually enabled.

## 11. Minimal three-minute path

Network time, infection, and obtaining provider credentials are excluded. A
person who already has these elements only needs to run:

```sh
nix run github:theking90000/server-setup#bootstrap-project -- ./my-infra
cd ./my-infra
# edit inventory/nodes.nix and the configuration of enabled services
nix develop
# infect-server ... for each machine
init-project
# sops <each reported file>
deploy-project vps1
deploy-project
```

There is no `justfile`, secret manifest to maintain, or SOPS adapter to copy.

## 12. Routine operations

### Adding a node

1. Add the node and its tags to `inventory/nodes.nix`.
2. Infect it.
3. Run `init-project`: the new host key is added to the recipients and the
   files are re-encrypted in a temporary area.
4. Complete any new placeholders.
5. Run `deploy-project <new-host>`, then `deploy-project`.

### Removing a node

1. Remove it from `inventory/nodes.nix` after backing up useful data.
2. Run `update-sops-keys` to remove its recipient from every file.
3. Review the encrypted diff, then run `check-project`.

Removing a SOPS recipient prevents its key from being used for new versions of
the files; it does not erase old copies that the recipient may have retained.

### Adding an existing public service

1. Add its tag to the correct node.
2. Set its non-secret options in `config/<service>/`.
3. Prepare DNS if it uses a public URL.
4. Run `init-project`, edit the reported fields, then run `check-project`.
5. Deploy a canary.

### Adding a private module

Place it under `modules/`, import that directory in the flake, and keep all of
its responsibilities in the module, including its SOPS declarations. Modify
the public `init-project` script only when the secret becomes a standard
contract of the public repository; otherwise, create the encrypted file once
with `sops`.

### Changing recipients without other initialization

```sh
update-sops-keys
```

This command is sufficient after adding, removing, or replacing a host key.
Review and commit `.sops.yaml` and the encrypted files together.

### Rotating a credential

```sh
sops secrets/<service>.json
check-project
deploy-project <canary>
```

Do not delete the entire file: `init-project` would also recreate the internal
values, causing additional rotations.

## 13. Troubleshooting

### `init-project` still rejects `CHANGEME`

The placeholders in `inventory/nodes.nix` must be replaced before any
connection. After initialization, the remaining list contains only encrypted
external credentials.

### Cannot read the host SSH key

Check:

```sh
ssh -i ~/.ssh/id_ed25519 -p 22 root@203.0.113.10 \
  cat /etc/ssh/ssh_host_ed25519_key.pub
```

The `sshKey`, `sshPort`, IPv4 address, and root access must match
`inventory/nodes.nix`. Do not blindly accept an unexpected host key change:
confirm that it is the reinstalled machine.

### SOPS cannot decrypt

Check the path and `0600` mode of the Age identity. If `SOPS_AGE_KEY_FILE` is
not set, use the standard path for your operating system shown above. A valid
copy of the administrator Age key is the normal recovery method. Without it, a
host SSH key that is still a recipient can technically decrypt the files on
that host; treat this recovery as a security operation and back up the
encrypted files first.

### The OVH challenge fails

Check the endpoint, all four variables, the permission to create and delete DNS
records, and the relevant zone. Read the logs without printing credentials:

```sh
journalctl -u acme-\*.service --since today
```

Also wait for DNS propagation before concluding that the module is faulty.

### Colmena reports a failure after activation

Start with the target:

```sh
ssh root@203.0.113.10 systemctl --failed
ssh root@203.0.113.10 journalctl -b -p warning
```

A successful Nix evaluation does not guarantee that an external credential,
endpoint, or application migration works at runtime.

## 14. What to commit

Commit the following together:

- `inventory/nodes.nix`;
- `inventory/hardware/`;
- `config/`;
- `.sops.yaml`;
- all encrypted SOPS JSON files;
- `flake.lock` after an intentional update.

The `inventory/keys/` and `inventory/wireguard/` directories are ignored by the
template because they contain private keys. Back them up separately in
encrypted storage. Always check `git status` before pushing.

To understand or create a module, continue with
[`MODULE-GUIDE.md`](MODULE-GUIDE.md). To manage Kanidm after the first
deployment, use [`KANIDM-CLI.md`](KANIDM-CLI.md).
