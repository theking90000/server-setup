# Guide: Writing a New Module

This guide explains how to create a new module in this NixOS configuration — from
file structure and options to tag registration, service discovery, secrets, and
cross-module integration.

---

## 1. Module Architecture

```
nixos/
  modules/
    default.nix              ← top-level: imports lib/ + nodes.nix + all subdirs
    nodes.nix                ← declares infra.nodeName, infra.nodes, infra.registeredTags
  lib/
    services.nix             ← _module.args.services (hasTag, getVpnIpsByTag, …)
    ops.nix                  ← _module.args.ops (mkSecretKeys)
  modules/
    applications/            ← each app = one file + a default.nix import aggregator
    backup/                  ← backup modules
    monitoring/              ← monitoring modules
    web/                     ← nginx + ingress option declaration
    network/                 ← wireguard, ssh, base network
    security/                ← acls, acme
```

Every NixOS module receives:
```nix
{ config, lib, pkgs, ... }:
```

Additionally, via `_module.args` (injected by `modules/default.nix`):
```nix
{ services, ops, ... }:
```

| Argument   | Source              | Purpose                                                |
|------------|---------------------|--------------------------------------------------------|
| `services` | `lib/services.nix`  | Tag queries, host/IP discovery                         |
| `ops`      | `lib/ops.nix`       | Secret deployment via Colmena (`mkSecretKeys`)         |

---

## 2. File Checklist

To add a new application module:

1. **Create** `nixos/modules/<category>/<name>.nix`
2. **Add it** to `nixos/modules/<category>/default.nix`:
   ```nix
   {
     imports = [
       ./existing.nix
       ./<name>.nix    # ← add your module here
     ];
   }
   ```
3. **Declare user-configurable options** in the private repo (see §12)

---

## 3. Module Skeleton

Every application module follows this shape:

```nix
# -------------------------------------------------------------------------
# <name>.nix — <one-line description>
#
# <longer description of what the service does>
#
# Tags requis : `applications/<name>`
# Secrets     : `infra.<name>.<field>` (déployé via Colmena)
# -------------------------------------------------------------------------
{
  config,
  lib,
  pkgs,
  services,
  ops,
  ...
}:

let
  tag = "applications/myapp";
  enabled = services.hasTag tag;
  cfg = config.infra.myapp;
in
{
  # ── Options ──────────────────────────────────────────────────────────
  options.infra.myapp = {
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL publique.";
    };

    # Add other options here (ports, credentials, etc.)
  };

  # ── Config ───────────────────────────────────────────────────────────
  config = lib.mkMerge [

    # Tier 1 — Always: register the tag (global, no guard)
    { infra.registeredTags = [ tag ]; }

    # Tier 2 — Per-node: service activation, ACLs, backup (local)
    (lib.mkIf enabled {
      systemd.services.myapp = { ... };
      infra.backup.paths = [ "/var/lib/myapp" ];
      infra.security.acls = [ {
        port = 8080;
        allowedTags = [ "web-server" ];
        description = "MyApp";
      } ];
    })

    # Tier 3 — Global: public ingress (any node can register)
    (lib.mkIf (cfg.url != null && services.getVpnIpsByTag tag != [ ]) {
      infra.ingress."myapp" = {
        domain = lib.replaceStrings [ "https://" ] [ "" ] cfg.url;
        backend = map (ip: "${ip}:8080") (services.getVpnIpsByTag tag);
        blockPaths = [ "/metrics" "/private" ];  # paths to 403
      };
    })

    # Tier 4 — Global: telemetry, always; empty list when no nodes tagged
    {
      infra.telemetry."myapp" = map (host: {
        targets = [ "${host}:8080" ];
        labels = { job = "myapp"; };
      }) (services.getHostsByTag tag);
    }

    # Tier 5 — Global: dashboard, guarded on ANY node having the tag
    (lib.mkIf (services.getHostsByTag tag != [ ]) {
      infra.grafana.dashboards = [ ./dashboards/myapp.json ];
    })
  ];
}
```

---

## 4. The Tag System

### What are tags?

Tags are arbitrary strings assigned to nodes in the private repo's
`inventory/services.nix`:

```nix
# inventory/services.nix (private repo)
{
  vps1 = [ "node-metrics" "backup" ];
  vps2 = [ "web-server" "grafana" ];
}
```

### How modules use tags

Each module **declares what tag(s) it handles** and **checks if the current
node has that tag**:

```nix
let
  tag = "web-server";
  enabled = services.hasTag tag;   # true if current node has "web-server"
in
```

### Tag validation

Every tag used on any node must be registered by some module. This happens
automatically:

```nix
# In every module:
config = lib.mkMerge [
  { infra.registeredTags = [ "my-tag" ]; }
  ...
];
```

The `nodes.nix` assertions check at build time that no node uses an
unregistered tag. If a tag is missing, the build fails:

```
Node "vps1": tag "foo" is not handled by any module. Known tags: [ web-server, grafana, ... ]
```

### Tag naming conventions

| Kind          | Convention                                     | Examples                  |
|---------------|------------------------------------------------|---------------------------|
| Core service  | Short descriptive name                         | `web-server`, `backup`, `grafana` |
| Application   | `applications/<app>`                           | `applications/gitea`, `applications/ntfy` |

---

## 5. `_module.args` Libraries

### services

Injected from `nixos/lib/services.nix`:

```nix
services.hasTag tag                # → bool
services.getHostsByTag tag         # → [string]    hostnames of nodes with tag
services.getVpnIpsByTag tag        # → [string]    VPN IPs of nodes with tag
services.getVpnIp                  # → string       this node's VPN IP
```

Always use `services.getVpnIp` as the bind address (never `0.0.0.0`):

```nix
listenAddress = services.getVpnIp;

# or as env:
environment = { HTTP_ADDR = "${services.getVpnIp}:8080"; };
```

### ops

Injected from `nixos/lib/ops.nix`:

```nix
ops.mkSecretKeys prefix secrets filterList   # → deployment.keys attrset
```

See §8 (Secrets) for full details.

---

## 6. Service Binding: VPN-Only

All services bind to the VPN IP, never to the public interface:

```nix
services.dockerRegistry = {
  listenAddress = services.getVpnIp;    # e.g., 10.100.0.2
  port = 5000;
};
```

The only exception is the Nginx web-server (tagged `web-server`) which binds
to port 443 on the public interface — but it reads traffic from VPN backends.

---

## 7. Self-Registration to Other Services

Modules integrate by **populating options** that other modules consume. You
NEVER call another module's functions directly — you set options.

### 7.1 Firewall ACLs (`infra.security.acls`)

Every service that listens on a port must declare who can reach it:

```nix
infra.security.acls = [
  {
    port = 5000;
    allowedTags = [ "web-server" ];       # resolved to VPN IPs
    description = "Docker registry";
  }
  {
    port = 5001;
    allowedTags = [ "prometheus" ];
    description = "Docker registry metrics";
  }
];
```

| Field          | Type      | Description                                    |
|----------------|-----------|------------------------------------------------|
| `port`         | int       | TCP/UDP port                                    |
| `allowedTags`  | [string]  | Tags whose VPN IPs can reach this port          |
| `allowedIps`   | [string]  | (optional) explicit CIDR ranges                 |
| `proto`        | string    | `"tcp"` (default) or `"udp"`                    |
| `trustLocalRoot` | bool    | Allow root from all nodes (default: true)       |
| `description`  | string    | Human-readable comment                          |

The ACL module resolves tags → VPN IPs at build time and generates nftables
rules. The final rule list is: accept from matching IPs, then explicit drop.

### 7.2 Backup (`infra.backup.paths`)

Register data directories for Restic backup:

```nix
infra.backup.paths = [ "/var/lib/gitea" "/var/lib/gitea/config" ];
```

The `restic.nix` module reads all registered paths from
`config.infra.backup.paths` and includes them in the backup job.

### 7.3 Ingress / Nginx (`infra.ingress`)

Register a public-facing domain → backend mapping:

```nix
(lib.mkIf (cfg.url != null && services.getVpnIpsByTag tag != [ ]) {
  infra.ingress."myapp" = {
    domain = lib.replaceStrings [ "https://" ] [ "" ] cfg.url;
    backend = map (ip: "${ip}:8080") (services.getVpnIpsByTag tag);
    blockPaths = [ "/metrics" ];               # optional 403 paths
    sslCertificate = "custom-cert";             # optional: override ACME cert name
  };
})
```

The guard condition ensures ingress is only created when:
- A public URL is configured (`cfg.url != null`)
- At least one backend exists (`getVpnIpsByTag != []`)

Nginx converts ingress entries into `upstreams` (load-balanced to all
backends) and `virtualHosts` (domain → upstream). It also auto-registers
each domain with ACME for TLS certificate generation.

### 7.4 Telemetry / Prometheus (`infra.telemetry`)

Register scrape targets for Prometheus:

```nix
{
  infra.telemetry."myapp" = map (host: {
    targets = [ "${host}:8080/metrics" ];
    labels = {
      job = "myapp";
      host = host;      # optional, for per-host dashboards
    };
  }) (services.getHostsByTag tag);
}
```

This block has **no `mkIf` wrapper** — it runs on every node. When no node
has the tag, `getHostsByTag` returns `[]` and the resulting list is empty.
The Prometheus module reads `config.infra.telemetry` globally and generates
its scrape config from the aggregate.

### 7.5 Dashboards / Grafana (`infra.grafana.dashboards`)

Register a JSON dashboard file for auto-provisioning in Grafana:

```nix
# Register unconditionally, guarded on GLOBAL tag presence
# (any node having the tag, not just current node)
(lib.mkIf (services.getHostsByTag tag != [ ]) {
  infra.grafana.dashboards = [ ./dashboards/myapp.json ];
})
```

The guard `services.getHostsByTag tag != [ ]` is global — true if ANY node has
the tag. This ensures the dashboard is registered even when Grafana runs on a
different node than the service itself.

Store dashboard JSON files in `nixos/modules/<category>/dashboards/`. They are
aggregated via `pkgs.linkFarm` on the Grafana node and provisioned with folder
structure preserved.

### 7.6 Grafana datasource auto-discovery

If your module provides data that Prometheus scrapes, it doesn't need to
register with Grafana — the Grafana module auto-discovers Prometheus
instances via `services.getVpnIpsByTag "prometheus"`. However, if you need
a non-Prometheus datasource, you can push to:

```nix
services.grafana.provision.datasources.settings.datasources = [ ... ];
```

This is the same mechanism used by the Prometheus module to self-register.

---

## 7b. Cross-Node Side Effects — Global vs Per-Node Guards

### The fundamental concept

NixOS modules are **evaluated once per node**, but **all options are global**.
`config.infra.*` holds the same value regardless of which node's evaluation
you're in. This means a module evaluated on vps1 can populate options that
only vps2 reads:

```
Module "nginx.nix" on vps1    →  populates infra.telemetry."nginx"
Module "nginx.nix" on vps2    →  populates infra.telemetry."nginx"
                               ↓  (both merged into one list)
Module "prometheus.nix" on vps3 → reads infra.telemetry (sees both)
```

### Two types of guards

Because some options produce **side effects for other nodes**, there are two
fundamentally different conditional patterns:

| Guard                              | Meaning                                      | When to use                                     |
|------------------------------------|----------------------------------------------|-------------------------------------------------|
| `lib.mkIf (services.hasTag tag)`   | True only if THIS node has the tag           | Service activation, deployment, local config     |
| No guard / `services.getHostsByTag tag != []` | True if ANY node has the tag | Telemetry, dashboards, anything another node consumes |

### Per-node guard: local service activation

Use `services.hasTag tag` (or `enabled`) for anything that only affects
the CURRENT node:

```nix
(lib.mkIf enabled {
  services.myapp = { ... };           # deploy on this node only
  infra.backup.paths = [ "/var/lib/myapp" ];   # backup this node's data
  infra.security.acls = [ { ... } ];           # firewall on this node
})
```

### Global guard (or none): side effects for other nodes

For options that **other nodes consume**, use either no guard or the global
guard `services.getHostsByTag tag != []`:

```nix
# No guard — always runs. If tag isn't on any node, getHostsByTag returns [].
{
  infra.telemetry."myapp" = map (host: {
    targets = [ "${host}:8080/metrics" ];
  }) (services.getHostsByTag tag);
}

# Global guard — only registers if at least one node has the tag.
# This prevents registering dashboards for services that aren't deployed.
(lib.mkIf (services.getHostsByTag tag != [ ]) {
  infra.grafana.dashboards = [ ./dashboards/myapp.json ];
})
```

### Why telemetry is always unconditional

Telemetry uses no guard. The reason: `services.getHostsByTag` returns `[]`
when no node has the tag, so `map` produces an empty list. The Prometheus
module sees an empty scrape config — it's harmless. The `mkIf` buys nothing
and adds complexity.

### Why ingress uses a two-part guard

Ingress uses the current node's tag AND configuration:

```nix
(lib.mkIf (cfg.url != null && services.getVpnIpsByTag tag != [ ]) { ... })
```

This is correct because:
- `cfg.url != null` — the URL must be configured in the private repo
- `services.getVpnIpsByTag tag != []` — at least one backend must exist

These are both global conditions (url comes from private config, which is
shared across all nodes; getVpnIpsByTag returns all nodes with the tag).

### Summary: which guard for which option

| Option                   | Guard                                            | Rationale                                   |
|--------------------------|--------------------------------------------------|---------------------------------------------|
| `infra.registeredTags`   | None (always)                                    | Tag must be known even if unused            |
| Service activation       | `lib.mkIf enabled`                               | Only deploy on nodes with the tag           |
| `infra.backup.paths`     | `lib.mkIf enabled`                               | Only backup nodes with running services     |
| `infra.security.acls`    | `lib.mkIf enabled`                               | Only open ports on nodes running services   |
| `infra.ingress`          | `lib.mkIf (cfg.url != null && getVpnIpsByTag != [])` | Needs URL + at least one backend       |
| `infra.telemetry`        | None (always)                                    | Harmless empty list when no nodes tagged    |
| `infra.grafana.dashboards` | `lib.mkIf (getHostsByTag != [])`               | Don't provision unused dashboards           |
| `deployment.keys`        | `lib.mkIf enabled`                               | Only deploy secrets to nodes needing them   |

### The golden rule

**Ask yourself: who reads this option?** If the answer is "another node" or
"another module that may run on a different node", you probably need a global
guard (or no guard at all). If the answer is "only this node's services",
use the per-node `enabled` guard.

---

## 8. Secrets

Secrets (passwords, tokens, API keys) must never reach `/nix/store`. Instead,
they are deployed directly onto the target node through Colmena's
`deployment.keys` mechanism.

### 8.1 Declaring secret options

In your module's `options`, declare sensitive fields as `nullOr str`:

```nix
options.infra.myapp = {
  password = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = ''Mot de passe admin (secret — déployé via Colmena).'';
  };
  apiKey = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = ''Clé API (secret — déployé via Colmena).'';
  };
};
```

### 8.2 Deploying secrets with `ops.mkSecretKeys`

```nix
deployment.keys = ops.mkSecretKeys "myapp" config.infra.myapp [ "password" "apiKey" ];
```

This generates:
- `/var/lib/secrets/myapp/password` (mode 0400)
- `/var/lib/secrets/myapp/apiKey` (mode 0400)

The files are uploaded by Colmena **over SSH at deploy time** — the values
never enter the Nix store.

| Parameter     | Description                                             |
|---------------|---------------------------------------------------------|
| `"myapp"`     | Subdirectory under `/var/lib/secrets/`                  |
| `config.infra.myapp` | Attrset of options (contains both secrets and non-secrets) |
| `[...]`       | List of **keys to deploy** (only these fields)             |
| `null`        | Instead of a list: deploy ALL fields from the attrset      |

### 8.3 Consuming secrets in the service

**Method A** — Systemd `LoadCredential` (recommended for single-file secrets):

```nix
systemd.services.myapp.serviceConfig.LoadCredential = [
  "password:/var/lib/secrets/myapp/password"
  "apiKey:/var/lib/secrets/myapp/apiKey"
];
```

The service reads them from `/run/credentials/myapp.service/password` and
`/run/credentials/myapp.service/apiKey`. These are bind-mounted into the
service namespace by systemd — the service sees them, nobody else does.

**Method B** — Direct file path (for apps that need multiple files or env):

```nix
systemd.services.myapp.serviceConfig = {
  EnvironmentFile = "/var/lib/secrets/myapp/env";
  ExecStart = "${pkgs.myapp}/bin/myapp --password-file /var/lib/secrets/myapp/password";
};
```

This is the Restic pattern: all three fields (repository, password, env) are
deployed with `filterList = null` and read from paths.

### 8.4 Non-secret options in the same attrset

You can declare non-secret options (like `url`, `port`) in the same
`options.infra.myapp` attrset. `mkSecretKeys` only deploys the fields you
specify in the filter list. Non-secret fields are ignored and can be freely
read from `config.infra.myapp`:

```nix
options.infra.myapp = {
  url = lib.mkOption { ... };           # non-secret: read from config
  password = lib.mkOption { ... };      # secret: deployed via mkSecretKeys
  port = lib.mkOption { ... };          # non-secret
};
```

---

## 9. Conditional Logic Patterns

### 9.1 Enabling based on tag (primary guard)

```nix
let enabled = services.hasTag tag;
in (lib.mkIf enabled { ... })
```

Everything related to the service (deployment, acls, backup paths) goes inside
this block.

### 9.2 Conditional ingress (only when public)

```nix
(lib.mkIf (cfg.url != null && services.getVpnIpsByTag tag != [ ]) {
  infra.ingress."app" = { ... };
})
```

### 9.3 Conditional on multiple tags

```nix
(lib.mkIf (enabled && services.hasTag "node-metrics") {
  systemd.services.restic-stats = { ... };
})
```

### 9.4 Conditional on group existence

```nix
(lib.mkIf (enabled && builtins.hasAttr "cert-syncer" config.users.groups) {
  users.users.nginx.extraGroups = [ "cert-syncer" ];
})
```

---

## 10. Complete Example: Minimal HTTP Application

This is the absolute minimum for an application that serves HTTP on the VPN
and wants public access + Prometheus monitoring.

```nix
# -------------------------------------------------------------------------
# myapp.nix — MyApp service
#
# Tags requis : `applications/myapp`
# Secrets     : `infra.myapp.password` (déployé via Colmena)
# -------------------------------------------------------------------------
{
  config,
  lib,
  services,
  ops,
  ...
}:

let
  tag = "applications/myapp";
  enabled = services.hasTag tag;
  cfg = config.infra.myapp;
in
{
  options.infra.myapp = {
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL publique.";
    };
    password = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Mot de passe admin (secret).";
    };
  };

  config = lib.mkMerge [
    { infra.registeredTags = [ tag ]; }

    (lib.mkIf enabled {
      deployment.keys = ops.mkSecretKeys "myapp" cfg [ "password" ];

      systemd.services.myapp.serviceConfig.LoadCredential = [
        "password:/var/lib/secrets/myapp/password"
      ];

      services.myapp = {
        enable = true;
        listenAddress = services.getVpnIp;
        port = 8080;
        adminPasswordFile = "/run/credentials/myapp.service/password";
      };

      infra.backup.paths = [ "/var/lib/myapp" ];
      infra.security.acls = [
        { port = 8080; allowedTags = [ "web-server" ]; description = "MyApp"; }
      ];
    })

    (lib.mkIf (cfg.url != null && services.getVpnIpsByTag tag != [ ]) {
      infra.ingress."myapp" = {
        domain = lib.replaceStrings [ "https://" ] [ "" ] cfg.url;
        backend = map (ip: "${ip}:8080") (services.getVpnIpsByTag tag);
      };
    })

    {
      infra.telemetry."myapp" = map (host: {
        targets = [ "${host}:8080/metrics" ];
        labels = { host = host; };
      }) (services.getHostsByTag tag);
    }

    (lib.mkIf (services.getHostsByTag tag != [ ]) {
      infra.grafana.dashboards = [ ./dashboards/myapp.json ];
    })
  ];
}
```

## 11. Private Repo Configuration

Options declared by modules are set in the private repo (never in the public
infra repo). The private flake imports these values into the Colmena evaluation:

```nix
# private repo: inventory/config.nix
{
  infra.myapp = {
    url = "https://myapp.example.com";
    password = "changeme";
  };
}
```

Secrets (password, api keys, etc.) are automatically deployed via Colmena's
`deployment.keys` when passed through `ops.mkSecretKeys` (see §8).
```

---

## 12. Summary Checklist

For every new module:

- [ ] Create file in correct `nixos/modules/<category>/<name>.nix`
- [ ] Add to `<category>/default.nix` imports list
- [ ] Destructure `{ config, lib, pkgs, services, ops, ... }`
- [ ] Define `let tag = "..."` and `enabled = services.hasTag tag`
- [ ] Declare `options.infra.<name>` with at least a `url` field (nullOr str)
- [ ] `infra.registeredTags = [ tag ]` (in config)
- [ ] Service config inside `lib.mkIf enabled`
- [ ] Bind to `services.getVpnIp` (never `0.0.0.0`)
- [ ] `infra.security.acls` for every port
- [ ] `infra.backup.paths` for data directories
- [ ] `infra.ingress."<name>"` conditional on url + backends
- [ ] `infra.telemetry."<name>"` if the service exposes Prometheus metrics
- [ ] `infra.grafana.dashboards` if a Grafana dashboard exists (global guard: `mkIf (services.getHostsByTag tag != [ ])`)
- [ ] Secrets via `ops.mkSecretKeys` (never plain imports)
- [ ] Comment header describing purpose, tags, secrets
- [ ] Verify: `nix flake check --all-systems`
