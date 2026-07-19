<p align="center">
  <img src="docs/assets/banner.webp" alt="Server Setup" width="880">
</p>

<p align="center">
  <em>Infrastructure designed to stay understandable after its author has forgotten how it works.</em>
</p>

<p align="center">
  <img alt="NixOS flake" src="https://img.shields.io/badge/NixOS-flake-5277C3?logo=nixos&logoColor=white">
  <img alt="Deploy: Colmena" src="https://img.shields.io/badge/deploy-Colmena-4A90D9">
  <img alt="Secrets: SOPS" src="https://img.shields.io/badge/secrets-SOPS-1A7F37?logo=gnuprivacyguard&logoColor=white">
</p>

## 🧭 Why this exists

Setting up a server is easy. Keeping it understandable for years is not. It
starts small: install a service, edit two files, add an Nginx rule, write the
password down somewhere. Then time passes. Versions drift apart, files get
edited by hand, nobody remembers exactly which services run where, certificates
and backups each work their own way, and one day a machine can no longer be
rebuilt without the memory of the last person who touched it.

Server Setup takes a different approach: **everything the fleet is supposed to
run is written down as code, versioned, checked before deployment, and
reproducible.** A server stops being a fragile thing you keep repairing and
becomes a copy of a known configuration that you can rebuild at any time.

Unlike most management solutions, there is no admin dashboard here, and that
is deliberate. A dashboard where you click to change things would bring the
problem right back: the real configuration would
no longer match the repository, and six months later you would be digging
through the server to understand why it behaves the way it does. The goal is
not to make manual administration nicer, but to make it rarely needed.

In practice, reading the repository is enough to know:

- which services exist and on which machines they run;
- what they depend on and what they can reach on the network;
- how ingress, backups, monitoring, secrets and SSO are connected, in one place;
- how to rebuild a machine instead of piecing its history back together;
- that updates apply the same way everywhere, and mistakes are caught before
  deployment.

If you have never inherited a server nobody dares to touch, this may sound
abstract. If you have, you will recognize the problem right away. The goal is
not to look impressive in a five-minute demo, but to still be able to
understand, update, repair or rebuild everything after three years of not
thinking about it every day.

## 🧱 What it is

Server Setup turns a fleet of fresh Linux servers into a fully declarative
NixOS deployment. Every server is described in code, reproducible bit for bit,[^repro]
and runs on plain systemd, with no container runtime or orchestrator in the way.
Nodes join a private WireGuard mesh and automatically get HTTPS ingress, single
sign-on, encrypted secrets, backups and monitoring.

Each deployment uses a separate private repository generated from `template/`.
It contains the list of nodes, the service configuration, the encrypted
secrets, the hardware configuration, and any deployment-specific modules.

## ✨ Features

- 🧷 **Batteries-included integrations**: ingress, backups, metrics and SSO connect themselves across the fleet through one stable mechanism
- 🧬 **Infrastructure as code**: the entire fleet is declarative and version-controlled
- 🪨 **Robust & deterministic**: plain systemd on NixOS, reproducible builds
- 🌐 **Private mesh**: every node joins an encrypted WireGuard network automatically
- 🚪 **HTTPS ingress**: Nginx with automatic Let's Encrypt certificates
- 🔐 **Security & SSO**: encrypted secrets (SOPS) and identity via Kanidm (OIDC/LDAPS)
- 💾 **Backups**: scheduled, deduplicated Restic backups
- 📊 **Monitoring**: Prometheus metrics and provisioned Grafana dashboards

## 🚀 Quick start

You need Nix, an SSH key, a fresh Linux server, and credentials for the
external services you enable.

> [!WARNING]
> `infect-server` **replaces the server's operating system**. Only run it on a
> machine you intend to wipe.

> [!NOTE]
> The starting OS does not have to be Debian. Onboarding goes through
> `infect-server` (built on `nixos-infect`), so any host that tool can convert
> will work. After infection the node runs standard NixOS on x86_64 or arm64,
> including the Raspberry Pi 5. Tested so far on OVH VPS shipped with Debian
> and on a Raspberry Pi 5 running Raspberry Pi OS.

```sh
# Create the private repository
nix run github:theking90000/server-setup#bootstrap-project -- ./my-infra
cd ./my-infra

# Edit inventory/nodes.nix and the configuration of enabled services
nix develop

# Repeat for each server
infect-server -i ~/.ssh/id_ed25519 -p 22 --post-port 22 debian@203.0.113.10

# Generate hardware configuration, keys, SOPS recipients, and standard secrets
init-project

# Replace the reported CHANGEME values
sops secrets/acme.json

# Check the configuration, deploy one canary, then deploy the full fleet
check-project
deploy-project vps1
deploy-project
```

The [setup guide](docs/SETUP-GUIDE.md) covers OVH/Lego DNS, server infection,
SOPS, secrets, checks, deployment, and routine operations.

## 🧩 How modules configure the fleet

Services do not need hand-written glue to work together. A module declares
what its service needs, and the shared services pick those declarations up
across the whole fleet.

Each node has tags. The module that registers a tag:

1. enables the service on the nodes that carry the tag;
2. declares the secret it needs and which process reads it;
3. connects the service to the WireGuard mesh;
4. registers its ACLs, ingress, backups, metrics, dashboards, and SSO clients;
5. lets Nginx, Restic, Prometheus, Grafana, and Kanidm collect these
   declarations.

A module uses one of two kinds of helpers, depending on where the
configuration applies:

- `services.hasTag tag` checks whether the current node has the tag.
- `services.getHostsByTag tag` and `getVpnIpsByTag tag` find the nodes that
  have it, anywhere in the fleet.

A file under `config/` can stay imported even when no node uses its service
tag. Its values are simply not evaluated in that case. The file only needs to
be valid Nix syntax.

## 🔒 Service ownership and private configuration

The public repository holds the reusable machinery. Each deployment keeps a
private repository with everything specific to it. Colmena deploys the
combination to the fleet, and the nodes talk to each other over the WireGuard
mesh.

| Public repository (this)            | Private repository (per deployment)                    |
| ----------------------------------- | ------------------------------------------------------ |
| NixOS modules and SOPS declarations | Node inventory and tags                                |
| `services` and `ops` helpers        | URLs, ports, and feature flags                         |
| Bootstrap and deployment commands   | Encrypted SOPS JSON files                              |
| Template and synthetic checks       | Hardware configuration and deployment-specific modules |

`infra.nixosModules.default` imports `sops-nix`, so a private repository does
not need its own SOPS module or a central adapter. Each public module owns
both its service and its secrets: `grafana.nix`, for example, declares the
Grafana service and the secret it uses.

The private repository only has to point at its encrypted secrets:

```nix
imports = [ infra.nixosModules.default ];

infra.sops.secretsDirectory = ./secrets;
```

Some modules still expose plain-text and `*File` options for compatibility and
tests. New deployments use SOPS by default.

## 📦 Available roles

### Fleet services

| Tag or activation         | Service                                             |
| ------------------------- | --------------------------------------------------- |
| Always enabled            | Base networking, OpenSSH, and the WireGuard mesh    |
| `web-server`              | Public Nginx, HTTPS ingress, and local ACME certs   |
| `backup`                  | Restic backups                                      |
| `node-metrics`            | Node Exporter                                       |
| `prometheus`              | Collection of registered scrape targets             |
| `grafana`                 | Provisioned data sources and dashboards             |
| `kanidm`                  | Identity, OIDC/OAuth2, and LDAPS                    |
| `kanidm` + `web-server`   | SSO proxy (oauth2-proxy) for apps without native OIDC |
| `infra.rcloneSync.mounts` | Per-node mounts without a tag                       |

### Applications

| Tag                            | Service                                        |
| ------------------------------ | ---------------------------------------------- |
| `applications/docker-registry` | Authenticated OCI registry                     |
| `applications/filesave-server` | File sharing                                   |
| `applications/gitea`           | Git forge                                      |
| `applications/jellyfin`        | Media server                                   |
| `applications/ntfy`            | Push notifications                             |
| `applications/qbittorrent`     | BitTorrent client in a VPN-only netns (kill switch) |
| `applications/reposilite`      | Maven repository                               |
| `applications/rust-storage-streamer` | Discord-backed Files and S3 gateways     |
| `applications/synapse`         | Federated Matrix homeserver with optional SSO  |
| `applications/www`             | Static hosting                                 |
| `applications/sncb-insights`   | Application provided by the private repository |

## 🛠️ Development shell commands

| Command                 | Action                                                               |
| ----------------------- | -------------------------------------------------------------------- |
| `bootstrap-project`     | Create a private repository from the template                        |
| `infect-server`         | Replace the existing OS with NixOS                                   |
| `init-project`          | Create missing hardware configuration, keys, SOPS files, and secrets |
| `update-sops-keys`      | Recompute recipients and re-encrypt staged files                     |
| `update-nixos-release`  | Detect and prepare the latest stable NixOS release                    |
| `check-project`         | Reject encrypted placeholders, then evaluate Nix and Colmena         |
| `deploy-project [host]` | Initialize, check, and deploy                                        |
| `adopt-hardware`        | Fetch hardware configuration from the nodes                          |
| `generate-mesh`         | Generate missing WireGuard keys                                      |
| `export-ssh-key`        | Export administration SSH public keys                                |

`init-project` and `deploy-project` never overwrite existing secret files.
Missing external credentials are created as encrypted `CHANGEME` values, and
their paths are reported so you know what to fill in.

## ⬆️ Updating NixOS

The public repository owns the NixOS release. The template and private
repositories follow its `nixpkgs` inputs, while existing machines keep their
original `system.stateVersion`.

```sh
# In server-setup: detect the latest official release, update every public
# version reference and lockfile, then evaluate all systems.
nix run .#update-nixos-release

# Review, commit and push the public change first. Then, in the private repository:
just update-lib
```

Use `nix run .#update-nixos-release -- --check` for a read-only check, or pass
an explicit release such as `26.11`. A release upgrade can still require manual
module changes; when `nix flake check` finds one, the command stops and never
deploys anything.

## 🗂️ Repository layout

<details>
<summary>Show the repository tree</summary>

```text
.
├── flake.nix
├── nixos/
│   ├── lib/                  # tag discovery and deployment helpers
│   ├── modules/              # NixOS modules grouped by service
│   └── pkgs/                 # project-specific packages
├── scripts/                  # commands distributed by the flake
├── template/                 # private repository skeleton
├── docs/
│   ├── SETUP-GUIDE.md        # setup and operations
│   ├── MODULE-GUIDE.md       # module contract
│   └── KANIDM-CLI.md         # Kanidm administration
└── AGENTS.md
```

</details>

## 📚 Documentation

- [Set up a deployment](docs/SETUP-GUIDE.md)
- [Write or maintain a module](docs/MODULE-GUIDE.md)
- [Manage Kanidm accounts and groups](docs/KANIDM-CLI.md)
- [Configure the generated private repository](template/README.md)

## ✅ Development and checks

A public module owns all the integrations for its service. The
[module guide](docs/MODULE-GUIDE.md) provides the module skeleton, the scope
rules, and the checks for networking, secrets, ingress, backups, metrics,
dashboards, and SSO.

```sh
# Public repository
nix flake check --all-systems

# Private repository, from nix develop
check-project
```

Once a change passes evaluation, deploy it to a single canary node before
running `deploy-project` for the whole fleet.

[^repro]: Reproducibility covers the system itself: the same configuration on a
    fresh install rebuilds an identical machine. User data (databases, uploads,
    application state) is not part of that guarantee. It is covered by the
    Restic backups instead, and in most cases a healthy backup restores the
    data in a couple of commands, often just one.
