# AGENTS.md — Project Overview for Coding Agents

## What is this repo?

**NixOS server fleet management** using [Colmena](https://github.com/zhaofengli/colmena).

Public infrastructure code (NixOS modules). A **separate private repo** provides
secrets and node-specific values via NixOS options (`infra.*`).

Target: OVH VPS initially provisioned as Debian 11, infected with NixOS.

## Architecture

```
nixos/
  modules/default.nix       ← top-level: import lib/ + all module dirs
  modules/nodes.nix         ← infra.nodeName, infra.nodes, infra.registeredTags
  lib/services.nix          ← _module.args.services (hasTag, getVpnIpsByTag, …)
  lib/ops.nix               ← _module.args.ops (mkSecretKeys)
  modules/
    applications/           ← docker-registry, gitea, ntfy, reposilite, filesave
    backup/                 ← restic + backup paths
    monitoring/             ← node-metrics, prometheus, grafana
    web/                    ← nginx + ingress
    network/                ← wireguard, ssh, base network
    security/               ← acls, acme
```

## Key concepts

### Tags

Nodes are assigned tags in the private repo (`inventory/services.nix`).
Modules activate themselves via `services.hasTag "my-tag"`.

Every tag on every node must be registered by a module (`infra.registeredTags`).
Assertions in `nodes.nix` enforce this at build time.

### `_module.args` injected libraries

```nix
{ config, lib, pkgs, services, ops, ... }:
```

| Name       | Key functions                                          |
|------------|--------------------------------------------------------|
| `services` | `hasTag`, `getHostsByTag`, `getVpnIpsByTag`, `getVpnIp` |
| `ops`      | `mkSecretKeys` (Colmena deployment.keys without /nix/store) |

### Cross-node side effects (critical concept)

**All options are global.** A module evaluated on vps1 can populate
`infra.telemetry` that vps2's prometheus reads. Choose guards accordingly:

| Guard                                | When                                            |
|--------------------------------------|-------------------------------------------------|
| `lib.mkIf (services.hasTag tag)`     | Local only: service activation, acls, backup     |
| No guard                             | Global: telemetry (empty list = harmless)        |
| `lib.mkIf (getHostsByTag tag != [])` | Global guard: dashboards (skip if unused)        |

### VPN-first networking

All services bind to `services.getVpnIp` (WireGuard mesh). Only nginx
(`web-server`) exposes ports publicly. Access between services goes through
the VPN — ACL rules resolve tags to VPN IPs.

### Secrets

Never in `/nix/store`. `ops.mkSecretKeys` → Colmena `deployment.keys` →
uploaded via SSH at deploy time. Read via systemd `LoadCredential` or
direct file path in `/var/lib/secrets/<app>/`.

## Module checklist

See `docs/MODULE-GUIDE.md` for the complete guide. Quick reference:

- Create `nixos/modules/<category>/<name>.nix`
- Add to `<category>/default.nix` imports
- Declare `options.infra.<name>` (use `nullOr str` for secrets)
- Register tag: `{ infra.registeredTags = [ tag ]; }`
- Guard local config with `lib.mkIf enabled`
- Bind to `services.getVpnIp`
- Self-register: `infra.security.acls`, `infra.backup.paths`, `infra.ingress.*`, `infra.telemetry.*`, `infra.grafana.dashboards`
- Secrets via `ops.mkSecretKeys`
- Verify: `nix flake check --all-systems`

## Build & verify

```sh
nix flake check --all-systems    # validates all module derivations
colmena apply                    # deploy from private repo
colmena apply --on <host>        # deploy single host
```

## Scripts

```sh
./scripts/infect.sh -i <ssh-key> <user>@<ip>   # NixOS infection
./scripts/adopt-hardware.sh                     # download hardware configs
./scripts/generate-mesh.sh                      # generate WireGuard keys
./scripts/export-ssh-key.sh                     # download host SSH pubkeys
./scripts/generate-key.sh                       # generate cert-syncer key
```

## Key files to know

| File                                 | Purpose                                       |
|--------------------------------------|-----------------------------------------------|
| `flake.nix`                          | Flake entry (Colmena hive + devShell)          |
| `hive.nix`                           | Colmena deployment entry (imports private)     |
| `nixos/modules/nodes.nix`            | Node inventory options + tag assertions        |
| `nixos/lib/services.nix`             | Service discovery functions                    |
| `nixos/lib/ops.nix`                  | mkSecretKeys helper                            |
| `nixos/modules/web/nginx.nix`        | Nginx reverse proxy + ingress → ACME bridge    |
| `nixos/modules/security/acme.nix`    | ACME cert issuer + cert-syncer                 |
| `nixos/modules/network/wireguard.nix` | Full mesh VPN via WireGuard                    |
| `docs/MODULE-GUIDE.md`               | Complete module authoring guide                |
| `inventory/topology.example.nix`     | Template for private node topology             |
| `inventory/services.example.nix`     | Template for private node tags                 |
