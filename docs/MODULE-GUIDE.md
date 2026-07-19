# Writing a `server-setup` module

This guide describes the complete contract of a public or private module. The
central rule is simple: **a service owns all of its configuration in its
module**. The same file declares its activation, SOPS secrets, network, ACLs,
ingress, backups, metrics, dashboards, and SSO.

Cross-cutting modules (`nginx`, `prometheus`, `grafana`, `restic`, `kanidm`) do
not know every application. They aggregate the contributions that application
modules publish through `infra.*` options.

## 1. Before creating a module

A new module is justified when the service has its own deployment
responsibility. Do not create:

- a separate adapter for its secrets;
- one file per integration (`myapp-grafana.nix`, `myapp-backup.nix`, etc.);
- a generic abstraction used by only one service;
- a tag when activation is already naturally expressed by a target list, such
  as `infra.rcloneSync.mounts.<name>.targetNodes`.

Then select its location:

| Location | Usage |
|---|---|
| `nixos/modules/applications/` | Reusable application |
| `nixos/modules/monitoring/` | Collection or visualization |
| `nixos/modules/network/` | Network, mount, or transport |
| `nixos/modules/security/` | Identity, certificates, or access control |
| `nixos/modules/backup/` | Backup mechanism |
| `<private-repo>/modules/` | Service specific to one infrastructure |

Add a public module to its category's `default.nix`. Import a private module
from the private `flake.nix`. Both follow exactly the same contract.

## 2. Fleet model

### 2.1 Tags

The private repository assigns roles in `inventory/nodes.nix`:

```nix
vps1 = {
  publicIp = "203.0.113.10";
  vpnIp = "10.100.0.1";
  tags = [
    "web-server"
    "applications/myapp"
  ];
};
```

Every tag must be registered by a module, even when no node uses it yet:

```nix
{ infra.registeredTags = [ "applications/myapp" ]; }
```

`nodes.nix` rejects any unknown tag during evaluation. The convention is
`applications/<name>` for an application and a short role name for a fleet
function (`web-server`, `backup`, `grafana`, etc.).

### 2.2 Injected helpers

A module receives helpers through `_module.args`:

```nix
{ config, lib, pkgs, services, ops, ... }:
```

| Helper | Result |
|---|---|
| `services.hasTag tag` | The current node has the tag |
| `services.getHostsByTag tag` | Names of all nodes with the tag |
| `services.getVpnIpsByTag tag` | WireGuard IP addresses of those nodes |
| `services.getVpnIp` | WireGuard IP address of the current node |
| `ops.mkSecretKeys` | Legacy compatibility for `deployment.keys` |

SOPS is the normal path for a new module. `ops.mkSecretKeys` is used only to
preserve older text options and existing tests.

### 2.3 Local scope and cross-node effects

Each NixOS node is evaluated with the complete topology. A declaration made
while evaluating one node can therefore feed an aggregator installed on
another node.

| Contribution | Correct guard |
|---|---|
| Service, package, systemd, ACL, backup path | `lib.mkIf enabled` |
| Telemetry derived from `getHostsByTag` | No guard; an empty list is neutral |
| Dashboard | Global presence: `getHostsByTag tag != [ ]` |
| Ingress | Configured URL and non-empty VPN backends |
| SSO client | Global presence of the application and Kanidm |

A common mistake is to wrap a dashboard with `services.hasTag tag`. Grafana
then sees it only if Grafana and the application run on the same node.

Always check global presence before reading a private value:

```nix
services.getVpnIpsByTag tag != [ ] && cfg.url != null
```

The order is intentional. Thanks to Nix lazy evaluation, values for an absent
service are not forced. Its private file can remain imported with its
placeholders. A syntax error is still fatal because Nix must parse the file.

## 3. Recommended skeleton

This skeleton shows every possible responsibility. Remove the blocks that the
service does not need.

```nix
{
  config,
  lib,
  pkgs,
  services,
  ops,
  ...
}:

let
  cfg = config.infra.myapp;
  tag = "applications/myapp";
  enabled = services.hasTag tag;
  port = 8080;
  dataDir = "/var/lib/myapp";

  useSopsPassword =
    enabled && cfg.password == null && cfg.passwordFile == null;
  passwordPath =
    if cfg.passwordFile != null then cfg.passwordFile
    else if cfg.password != null then "/var/lib/secrets/myapp/password"
    else "/run/secrets/myapp/password";
in
{
  options.infra.myapp = {
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Public URL of MyApp.";
    };

    password = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Compatibility: password injected by Colmena.";
    };

    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Compatibility: runtime path of the password.";
    };
  };

  config = lib.mkMerge [
    { infra.registeredTags = [ tag ]; }

    (lib.mkIf useSopsPassword {
      sops.secrets."myapp/password" = {
        sopsFile = config.infra.sops.secretsDirectory + "/myapp.json";
        key = "password";
      };
    })

    (lib.mkIf enabled {
      assertions = [{
        assertion = cfg.password == null || cfg.passwordFile == null;
        message = "Set at most one MyApp password source.";
      }];

      deployment.keys = ops.mkSecretKeys "myapp" {
        password = if cfg.passwordFile == null then cfg.password else null;
      } [ "password" ];

      systemd.services.myapp.serviceConfig.LoadCredential = [
        "password:${passwordPath}"
      ];

      services.myapp = {
        enable = true;
        listenAddress = services.getVpnIp;
        inherit port;
      };

      infra.security.acls = [{
        inherit port;
        allowedTags = [ "web-server" ];
        description = "MyApp";
      }];

      infra.backup.paths = [ dataDir ];
    })

    {
      infra.telemetry.myapp = map (host: {
        targets = [ "${host}:9091" ];
        labels = { inherit host; };
      }) (services.getHostsByTag tag);
    }

    (lib.mkIf (services.getVpnIpsByTag tag != [ ] && cfg.url != null) {
      infra.ingress.myapp = {
        url = cfg.url;
        backend = map (ip: "${ip}:${toString port}")
          (services.getVpnIpsByTag tag);
      };
    })

    (lib.mkIf (services.getHostsByTag tag != [ ]) {
      infra.grafana.dashboards = [ ./dashboards/myapp.json ];
    })
  ];
}
```

The module reads from top to bottom: contract, secrets, local configuration,
then global contributions.

## 4. Network and exposure

### 4.1 VPN first

An internal service listens on `services.getVpnIp`. Use `0.0.0.0` only when the
software provides no better option, and explicitly protect the port in that
case. Normally, only the `web-server` node exposes HTTP/HTTPS to the Internet.

The standard path is:

```text
Internet -> public Nginx -> backend over WireGuard -> application
```

### 4.2 ACLs

The module that opens a port also declares who can reach it:

```nix
infra.security.acls = [{
  port = 8080;
  proto = "tcp";                 # default
  allowedTags = [ "web-server" ];
  allowedIps = [ ];              # manual exceptions only
  trustLocalRoot = true;         # default
  description = "MyApp HTTP";
}];
```

Tags are resolved to VPN IP addresses. The firewall accepts the specified
sources, then explicitly rejects other connections to that port. Also add an
ACL for the metrics port that allows the `prometheus` tag.

### 4.3 Ingress

A public application contributes to `infra.ingress`:

```nix
infra.ingress.myapp = {
  url = cfg.url;                       # e.g. https://app.example.com/path
  proxyTo = [ "http://10.100.0.2:8080" ];
  routes.metrics = {
    path = "/metrics";
    nginx.return = "403";
  };
};
```

The backend scheme in `proxyTo` carries upstream TLS (`https://` enables
`proxy_ssl_verify off`). Route paths are relative to the base path of the
endpoint, and the `nginx` fragment of a route uses the native vocabulary of
`services.nginx.virtualHosts.*.locations.*` for advanced needs (headers,
timeouts, returns). Endpoints are HTTPS only. Nginx groups entries by host —
several entries may share one host with distinct routes — generates one ACME
claim per entry, and wires the certificate through `useACMEHost`. Do not
configure the Nginx virtual host directly from the private repository for a
standard application.

### 4.4 ACME

The `acme.nix` module resolves certificate claims against the deployment's
issuance policies (`infra.acme.issuers`, declared in the private repository)
and issues every certificate locally with the native NixOS `security.acme`
module. A consumer module never handles DNS credentials: an ingress generates
its claim automatically, and Nginx reloads after each real renewal.

If a non-Nginx service consumes a certificate directly, declare a claim and
read the computed output:

```nix
infra.acme.claims.myservice = {
  names = [ "svc.example.com" ];
  consumer = { kind = "service"; scope = "myservice"; };
  restartServices = [ "myservice.service" ];
};

systemd.services.myservice.serviceConfig.LoadCredential =
  let cert = config.infra.acme.claims.myservice.certificate;
  in [ "tls_chain:${cert.fullchain}" "tls_key:${cert.key}" ];
```

Use `restartServices` (not `reloadServices`) for `LoadCredential` consumers:
systemd only re-reads credentials when the service restarts. The `scope`
keeps the private key separate from the Nginx wildcard by default; sharing a
key requires deliberately reusing the same scope.

## 5. SOPS secrets

SOPS is not optional in a new infrastructure. The main public module imports
`sops-nix`, and the private repository configures a single root:

```nix
infra.sops.secretsDirectory = ./secrets;
```

The service module then declares the file, JSON key, and runtime permissions:

```nix
sops.secrets."myapp/api-key" = {
  sopsFile = config.infra.sops.secretsDirectory + "/myapp.json";
  key = "api_key";
  owner = "myapp";
  group = "myapp";
  mode = "0400";
};
```

The private repository contains only:

```json
{"api_key":"value-encrypted-by-sops"}
```

Mandatory rules:

- keep the SOPS wiring in the module that consumes the secret;
- `config/` contains no `sops.secrets`, `/run/secrets` path, or secret value;
- create no plaintext file in the repository; use `sops file.json`;
- never read a secret value with `builtins.readFile`;
- prefer systemd `LoadCredential` when the service supports it;
- set `owner`, `group`, and `mode` only according to the actual requirement;
- add a `password` or `passwordFile` option only for existing compatibility or
  a concrete testing need.

`builtins.readFile` remains acceptable for a **public key**, for example a
WireGuard public key from the inventory.

When a service is used by several roles, declare the secret on every node that
consumes it. Grafana is an example: the OIDC secret is required on both the
Grafana node and the Kanidm node that provisions the client.

## 6. Integrations owned by the module

### 6.1 Backups

The application module publishes its persistent data:

```nix
infra.backup.paths = [ "/var/lib/myapp" ];
```

Do not back up reproducible caches. Check that the service actually writes to
this path, that restoration is possible, and whether it requires a pause or a
consistent dump. Database-backed applications can also contribute an idempotent
preparation command that writes an atomic dump into one of those paths:

```nix
infra.backup.prepareCommands = [
  ''
    pg_dump --format=custom --file=/var/lib/myapp-backup/database.dump.tmp myapp
    mv /var/lib/myapp-backup/database.dump.tmp /var/lib/myapp-backup/database.dump
  ''
];
```

The Restic module aggregates the paths and preparation commands on nodes with
the `backup` tag. A failing preparation command aborts that backup run.

### 6.2 Prometheus

A module publishes a global job:

```nix
infra.telemetry.myapp = map (host: {
  targets = [ "${host}:9091" ];
  labels = { inherit host; };
  scheme = "http";
  metrics_path = "/metrics";
  tls_config = null;
  basic_auth = null;
}) (services.getHostsByTag tag);
```

WireGuard hostnames can be used in targets. Protect the port with an ACL that
allows `prometheus`. Use `basic_auth` only when the service requires it: this
option currently places its password in the Nix evaluation and is unsuitable
for a new sensitive secret.

### 6.3 Grafana

The dashboard JSON lives next to the module:

```nix
lib.mkIf (services.getHostsByTag tag != [ ]) {
  infra.grafana.dashboards = [ ./dashboards/myapp.json ];
}
```

The dashboard must target the stable Prometheus job name, avoid
environment-specific data source UIDs, and remain useful without manual changes
after deployment.

### 6.4 SSO/Kanidm

An OIDC-compatible application registers its own client:

```nix
infra.sso.myapp = {
  displayName = "MyApp";
  serviceTag = tag;
  redirectUris = [ "${cfg.url}/oauth/callback" ];
  landingUrl = cfg.url;
  secretFile = "/run/secrets/sso/myapp-client-secret";
  scopes = [ "openid" "profile" "email" ];
  pkce = true;
  groups.admins.claims.myapp_role = [ "Admin" ];
};
```

The same module declares the OIDC SOPS secret and configures its application to
read that file. Kanidm aggregates `infra.sso`, but accounts and group
memberships are still managed in Kanidm. See
[`KANIDM-CLI.md`](KANIDM-CLI.md).

Before adding an authentication proxy, check whether the application supports
OIDC natively. The module remains responsible for the selected integration.

## 7. Private options and packages

The private repository should define only choices that are understandable
without knowing SOPS or systemd:

```nix
{
  infra.myapp = {
    url = "https://app.example.com";
    registrationEnabled = false;
  };
}
```

For a binary that is not in nixpkgs, add a package under
`nixos/pkgs/<app>/` or in the private repository, then inject it through an
option of type `package`. A precompiled binary follows the `fetchurl` +
`autoPatchelfHook` + `dontUnpack = true` pattern. Do not add an overlay when a
simple `pkgs.callPackage` is sufficient.

## 8. Modules without a tag

A tag is not a technical requirement. `rclone-sync.nix` activates each mount
according to `targetNodes`:

```nix
infra.rcloneSync.mounts."backup-s3" = {
  mountPoint = "/mnt/backup";
  targetNodes = [ "vps1" ];
  remoteName = "s3-crypt";
};
```

The module derives mounts for the current node, declares the SOPS key for each
one in `secrets/rclone-sync.json`, then seeds a persistent, writable copy of
`rclone.conf`. This exception follows the natural `mount -> nodes` granularity,
not a different architecture.

## 9. Verification

Before considering the module complete:

1. add it to its category's `default.nix`;
2. add a synthetic node or extend an existing check in `flake.nix`;
3. evaluate the default SOPS path, not only the text fallbacks;
4. check the case without the tag and the case without a URL;
5. run:

   ```sh
   nix flake check --all-systems
   ```

6. in a private infrastructure, run `check-project`;
7. for a risky change, first run `deploy-project <canary>`, check the units and
   endpoints, then deploy the fleet.

A successful Nix evaluation proves neither network connectivity, the validity
of a provider credential, nor service health after activation.

## 10. Complete checklist

### Responsibility

- [ ] The service warrants a separate module.
- [ ] All of its integrations live in that module.
- [ ] The private repository receives only functional choices.
- [ ] No separate SOPS adapter is added.

### Activation and topology

- [ ] The tag is named and registered, or tagless activation is justified.
- [ ] The local block uses `services.hasTag` or the current node's targets.
- [ ] Cross-node contributions use a global guard.
- [ ] Global presence is checked before any service value so that configuration
      for an absent service is not evaluated.
- [ ] Important configuration errors have a readable assertion.

### Network

- [ ] The service listens on the VPN IP address when possible.
- [ ] Every port has an ACL and only the required roles are allowed.
- [ ] The metrics port is restricted to `prometheus`.
- [ ] The ingress uses VPN IP addresses and does not expose `/metrics` or an
      administrative route unnecessarily.
- [ ] Ports, protocols, and IPv6 requirements are explicit.

### Secrets

- [ ] Every secret has a SOPS declaration in the module.
- [ ] The JSON file, key, owner, and mode are correct.
- [ ] The service reads the secret at runtime, ideally with `LoadCredential`.
- [ ] No secret enters `/nix/store`, logs, or `config/`.
- [ ] `init-project` knows the expected files and fields when the module is
      public and standard.
- [ ] Rotation and the required restart are understood.

### Data and operations

- [ ] Useful persistent paths contribute to `infra.backup.paths`.
- [ ] Restore consistency has been considered.
- [ ] systemd logs support troubleshooting without exposing secrets.
- [ ] Updates and schema migrations have been anticipated.
- [ ] Resources, user permissions, and state directories are minimal.

### Observability

- [ ] An `infra.telemetry` target is published when metrics exist.
- [ ] Labels and the job name are stable.
- [ ] A useful dashboard is colocated and registered globally.
- [ ] Alerts that are actually actionable are planned in the appropriate place.

### SSO and access

- [ ] Native OIDC support was evaluated before any proxy.
- [ ] The application declares the client, redirect URIs, scopes, PKCE, groups,
      and claims.
- [ ] The application and Kanidm see the same client secret at runtime.
- [ ] Behavior without Kanidm is explicit.

### Validation

- [ ] The module is imported and covered by a synthetic evaluation.
- [ ] `nix flake check --all-systems` succeeds.
- [ ] `check-project` succeeds in the private repository.
- [ ] A canary deployment checks the service, ACL, ingress, metrics, dashboard,
      backup, and SSO as applicable.

If an item does not apply, it should be possible to dismiss it in one sentence.
This checklist reveals forgotten responsibilities; it is not a reason to
produce empty code.
