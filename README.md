# Server Setup

Automatisation de serveurs NixOS avec [Colmena](https://github.com/zhaofengli/colmena).

Cible : VPS OVH provisionnés en Debian 11, infectés avec NixOS.

## Architecture deux dépôts

Ce dépôt est le **dépôt public** — il contient les modules NixOS réutilisables
(configuration réseau, services, monitoring, sécurité), les scripts de déploiement,
et le *template* pour créer un dépôt privé.

Le **dépôt privé** contient les secrets, les IPs, les tags et la topologie
spécifique à ton infrastructure. Il importe ce dépôt public comme input Flake
et définit les valeurs des options `infra.*`.

```
┌─ github:theking90000/server-setup (public) ─┐
│  nixos/modules/   ← modules NixOS            │
│  template/        ← squelette privé           │
│  scripts/         ← infect, mesh, bootstrap…  │
│  flake.nix        ← packages, nixosModules    │
└──────────────────────────────────────────────┘
                    ↓ importé par
┌─ dépôt privé ────────────────────────────────┐
│  flake.nix        ← input infra + déploiement │
│  inventory/nodes.nix   ← IPs, tags, topologie │
│  config/*.nix     ← URLs, credentials (infra.*)│
│  justfile         ← commandes de déploiement   │
└──────────────────────────────────────────────┘
```

## Démarrage rapide

```sh
# 1. Créer un dépôt privé depuis le template
nix run github:theking90000/server-setup#bootstrap-project -- ./my-infra

# 2. Éditer les valeurs
cd ./my-infra
# → inventory/nodes.nix : remplacer tous les CHANGEME (IPs, tags, clé SSH)
# → config/*.nix        : remplacer tous les CHANGEME (URLs, credentials)

# 3. Entrer dans l'environnement
nix develop

# 4. Infecter chaque VPS
infect-server -i ~/.ssh/id_ed25519 root@<ip>

# 5. Tout déployer
just deploy
```

## Scripts

Tous les scripts sont disponibles dans le `devShell` (via `nix develop` ou `direnv`) :

| Commande            | Description                                                            |
|---------------------|------------------------------------------------------------------------|
| `bootstrap-project` | Crée un nouveau dépôt privé depuis le template                         |
| `infect-server`     | Infecte un VPS Debian 11 avec NixOS                                    |
| `adopt-hardware`    | Télécharge les configs hardware depuis les VPS                         |
| `generate-mesh`     | Génère les clés WireGuard du mesh                                      |
| `export-ssh-key`    | Télécharge les clés SSH publiques des hôtes                            |
| `generate-key`      | Génère la clé SSH pour le cert-syncer (ACME)                           |

## Fonctionnement

### Tags

Chaque nœud reçoit des **tags** dans `inventory/nodes.nix` (dépôt privé).
Les modules NixOS s'activent automatiquement en fonction de ces tags via
`services.hasTag`.

Les tags disponibles et leurs descriptions sont listés dans
[`docs/MODULE-GUIDE.md`](docs/MODULE-GUIDE.md).

### Réseau VPN (WireGuard)

Tous les nœuds sont reliés par un mesh WireGuard. Chaque service écoute
sur l'IP VPN (`services.getVpnIp`), jamais sur l'interface publique.
Seul Nginx (tag `web-server`) expose des ports publiquement (80/443).

### Secrets

Les secrets (passwords, tokens) ne transitent **jamais** par `/nix/store`.
Ils sont déclarés comme options NixOS (`infra.<app>.password`, etc.) et
déployés directement sur les nœuds via `ops.mkSecretKeys` → Colmena
`deployment.keys` → upload SSH au moment du déploiement.

Les services lisent les secrets depuis `/var/lib/secrets/<app>/` ou
via systemd `LoadCredential`.

### Module NixOS

Chaque service est un module dans `nixos/modules/<catégorie>/`.
Un module :
1. Déclare ses options (`options.infra.<app>.*`)
2. Enregistre son tag (`infra.registeredTags`)
3. S'active conditionnellement (`lib.mkIf enabled`)
4. S'auto-enregistre auprès des autres services (ingress, ACLs, backup, telemetry, dashboards)

Guide complet : [`docs/MODULE-GUIDE.md`](docs/MODULE-GUIDE.md).

## Structure du dépôt

```
├── flake.nix              ← packages, nixosModules, devShells
├── hive.nix               ← point d'entrée Colmena (imports dépôt privé)
├── AGENTS.md              ← instructions pour agents IA
├── README.md              ← ce fichier
├── scripts/               ← scripts shell (infect, mesh, bootstrap...)
├── template/              ← squelette pour bootstrap-project
├── inventory/             ← exemples pour le dépôt privé
├── nixos/
│   ├── modules/           ← modules NixOS
│   │   ├── default.nix
│   │   ├── nodes.nix
│   │   ├── applications/  ← docker-registry, gitea, ntfy, reposilite, filesave
│   │   ├── backup/        ← restic
│   │   ├── monitoring/    ← node-metrics, prometheus, grafana
│   │   ├── web/           ← nginx + ingress
│   │   ├── network/       ← wireguard, ssh
│   │   └── security/      ← acls, acme
│   └── lib/               ← services.nix, ops.nix
├── config/                ← (supprimé — config dans le dépôt privé)
├── docs/                  ← documentation
│   └── MODULE-GUIDE.md    ← guide complet d'écriture de module
└── pkgs/                  ← paquets Nix customs
```

## Vérification

```sh
nix flake check --all-systems    # valide tous les modules
```

## Déploiement (depuis le dépôt privé)

```sh
colmena apply                    # tous les nœuds
colmena apply --on vps1          # un seul nœud
```
