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
3. **Declare user-configurable options** in the private repo (see §3)
4. **Copy the example config** to `config/<name>/<name>.example.nix`

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

    # Tier 1 — Always: register the tag
    { infra.registeredTags = [ tag ]; }

    # Tier 2 — Service present on this node
    (lib.mkIf enabled {
      systemd.services.myapp = { ... };
      infra.backup.paths = [ "/var/lib/myapp" ];
      infra.security.acls = [ {
        port = 8080;
        allowedTags = [ "web-server" ];
        description = "MyApp";
      } ];
    })

    # Tier 3 — Public ingress (only if url is set AND backends exist)
    (lib.mkIf (cfg.url != null && services.getVpnIpsByTag tag != [ ]) {
      infra.ingress."myapp" = {
        domain = lib.replaceStrings [ "https://" ] [ "" ] cfg.url;
        backend = map (ip: "${ip}:8080") (services.getVpnIpsByTag tag);
        blockPaths = [ "/metrics" "/private" ];  # paths to 403
      };
    })

    # Tier 4 — Telemetry (always; empty list when no nodes have the tag)
    {
      infra.telemetry."myapp" = map (host: {
        targets = [ "${host}:8080" ];
        labels = { job = "myapp"; };
      }) (services.getHostsByTag tag);
    }
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

### 7.5 Grafana datasource auto-discovery

If your module provides data that Prometheus scrapes, it doesn't need to
register with Grafana — the Grafana module auto-discovers Prometheus
instances via `services.getVpnIpsByTag "prometheus"`. However, if you need
a non-Prometheus datasource, you can push to:

```nix
services.grafana.provision.datasources.settings.datasources = [ ... ];
```

This is the same mechanism used by the Prometheus module to self-register.

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
  ];
}
```

And the corresponding example config file
(`config/myapp/myapp.example.nix`, tracked in git):

```nix
{
  infra.myapp = {
    url = "https://myapp.example.com";
    password = "";
  };
}
```

---

## 11. Summary Checklist

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
- [ ] Secrets via `ops.mkSecretKeys` (never plain imports)
- [ ] Create `config/<name>/<name>.example.nix` with placeholder values
- [ ] Comment header describing purpose, tags, secrets
- [ ] Verify: `nix flake check --all-systems`
