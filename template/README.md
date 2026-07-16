# My private infrastructure

This repository deploys a NixOS fleet with Colmena and the public
`server-setup` modules. It contains the actual topology, functional choices,
and JSON secrets encrypted with SOPS.

The complete guide is available in the public repository:
[setup from start to finish](https://github.com/theking90000/server-setup/blob/main/docs/SETUP-GUIDE.md).

## First deployment

1. Replace every `CHANGEME` value in `inventory/nodes.nix`, then replace only
   those for services whose tag is enabled in the fleet. Files under `config/`
   for absent services can remain imported and unchanged.
2. Load the tools:

   ```sh
   nix develop
   ```

3. Infect each fresh Debian server:

   ```sh
   infect-server \
     -i ~/.ssh/id_ed25519 \
     -p 22 \
     --post-port 22 \
     debian@203.0.113.10
   ```

4. Prepare the repository:

   ```sh
   init-project
   ```

5. Edit only the reported files and fields:

   ```sh
   sops secrets/acme.json
   sops secrets/restic.json
   ```

6. Check the configuration and deploy a canary first:

   ```sh
   check-project
   deploy-project vps1
   deploy-project
   ```

`init-project` fetches the hardware configuration and host SSH keys, generates
the WireGuard and cert-syncer keys, maintains `.sops.yaml`, then creates only
the missing standard secrets. It never replaces an existing secret.

## What to change where

| Path | Contents |
|---|---|
| `inventory/nodes.nix` | Nodes, IP addresses, SSH settings, and tags |
| `config/` | Non-secret URLs, ports, and feature flags |
| `secrets/` | Final values encrypted with SOPS |
| `inventory/hardware/` | NixOS hardware configuration fetched by `init-project` |
| `modules/` | Optional modules specific to this project |
| `flake.nix` | Colmena assembly and imports |

Rules:

- never put a secret, `sops.secrets`, `/run/secrets`, or `deployment.keys` in
  `config/`;
- never create a plaintext copy of a JSON file: use `sops <file>`;
- the service's public module already owns the standard SOPS wiring;
- a private module remains responsible for its own secrets and systemd units;
- inactive service configuration is not evaluated, but its file must still
  contain valid Nix syntax;
- private keys under `inventory/keys/` and `inventory/wireguard/` are ignored
  by Git and must be backed up separately.

## Common commands

| Command | Usage |
|---|---|
| `init-project` | Prepare or complete the repository without overwriting existing files |
| `update-sops-keys` | Recompute recipients after a node change |
| `check-project` | Check active secrets, config/secret separation, Nix, and Colmena |
| `deploy-project <host>` | Initialize, check, and deploy a canary |
| `deploy-project` | Initialize, check, and deploy the entire fleet |
| `infect-server` | Install NixOS on a fresh Debian server |
| `adopt-hardware` | Fetch hardware configuration without running the full initialization |
| `generate-mesh` | Generate missing WireGuard keys |

## Adding a node

1. Add it to `inventory/nodes.nix` with a unique `vpnIp`.
2. Infect the server.
3. Run `init-project` to add its host key to the SOPS recipients.
4. Deploy with `deploy-project <host>`, then deploy the fleet.

## Removing a node

1. Back up its data, then remove it from `inventory/nodes.nix`.
2. Run `update-sops-keys`.
3. Commit `.sops.yaml` and all re-encrypted JSON files together.
4. Run `check-project`.

## Adding a service

1. Add its tag to the selected node.
2. Set its non-secret options under `config/<service>/`.
3. Prepare its public DNS record if required.
4. Run `init-project`, then fill in the reported encrypted fields.
5. Check the configuration and deploy a canary.

To create a new module, follow the
[module guide](https://github.com/theking90000/server-setup/blob/main/docs/MODULE-GUIDE.md).
For SSO accounts and groups, use the
[Kanidm guide](https://github.com/theking90000/server-setup/blob/main/docs/KANIDM-CLI.md).

## Before each push

```sh
check-project
git status
```

The `.sops.yaml`, `secrets/*.json`, `inventory/hardware/`, `config/`,
`inventory/nodes.nix`, and `flake.lock` files normally belong in the private
repository.
