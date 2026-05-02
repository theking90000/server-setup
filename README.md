# Server Setup

Automatisation complète d'une infrastructure de serveurs avec **NixOS** et
[Colmena](https://github.com/zhaofengli/colmena).

Ce projet permet de gérer une flotte de VPS comme un seul système cohérent :
les services se découvrent automatiquement entre les nœuds via le réseau VPN
WireGuard, les ACLs firewall sont générées à partir des tags, les dashboards
Grafana et les cibles Prometheus s'enregistrent dynamiquement. Chaque module
sait quels autres nœuds existent au moment du build — pas de configuration
manuelle des IPs entre services.

### NixOS

[NixOS](https://nixos.org) est une distribution Linux déclarative : toute la
configuration (paquets, services, utilisateurs, firewall, réseau) est décrite
dans des fichiers `.nix`. Le système est immuable — chaque déploiement produit
un nouvel état reproductible. Pas de mutation progressive de `/etc`, pas de
`apt-get install` oublié. Si ça marche aujourd'hui, ça marchera demain.

### Colmena

[Colmena](https://github.com/zhaofengli/colmena) est un orchestrateur de
déploiement NixOS multi-nœuds. Il évalue la configuration de chaque nœud
**en ayant connaissance de tous les autres**, ce qui permet de générer des
règles réseau, des configs WireGuard et des ACLs inter-nœuds automatiquement.
Il déploie via SSH, en parallèle, avec rollback automatique en cas d'échec.

### Cibles matérielles

VPS [OVH](https://www.ovh.com) avec une **IP publique**, provisionnés
initialement sous **Debian 11**, puis infectés avec NixOS via le script
`infect-server`. N'importe quel VPS sous Debian 11 (ou 12) avec une IP
publique fonctionne — les configs hardware sont téléchargées automatiquement
après l'infection.

### Prérequis

- **Nix** installé sur votre machine locale ([installateur officiel](https://nixos.org/download))
- Une clé SSH configurée (`~/.ssh/id_ed25519`)
- Un ou plusieurs VPS Debian 11 accessibles en SSH (port 22)

## Architecture deux dépôts

Ce dépôt est le **dépôt public** — il contient les modules NixOS réutilisables
(configuration réseau, services, monitoring, sécurité), les scripts de déploiement,
et le *template* pour créer un dépôt privé.

Le **dépôt privé** contient les secrets, les IPs, les tags et la topologie
spécifique à votre infrastructure. Il importe ce dépôt public comme input Flake
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

## Stack déployée

Une fois configuré, le projet déploie une infrastructure complète :

| Service      | Rôle                                                                 |
|--------------|----------------------------------------------------------------------|
| **Nginx**    | Reverse proxy front-end, exposé sur le port 443 public. Termine le TLS via des certificats Let's Encrypt (ACME) générés automatiquement. Route le trafic vers les services internes via le VPN WireGuard. |
| **WireGuard**| Mesh VPN reliant tous les nœuds. Chaque service écoute sur son IP VPN, jamais sur l'interface publique. Les ACLs firewall (nftables) sont générées automatiquement à partir des tags. |
| **Prometheus**| Collecte les métriques de tous les nœuds et services (Node Exporter, Nginx VTS, Gitea, Docker Registry, Ntfy, Reposilite). Les cibles sont auto-découvertes via les tags. |
| **Grafana**  | Visualise les métriques via des dashboards auto-provisionnés. Chaque module peut fournir ses propres dashboards JSON, injectés dynamiquement. |
| **Restic**   | Sauvegarde automatique des données de tous les services (Gitea, Docker Registry, Grafana, etc.) vers un stockage S3. |
| **Gitea**    | Serveur Git auto-hébergé avec métriques Prometheus. |
| **Docker Registry** | Registre Docker privé avec authentification htpasswd et métriques. |
| **Ntfy**     | Serveur de notifications push avec métriques. |
| **Reposilite** | Gestionnaire de dépôts Maven avec métriques. |
| **FileSave** | Serveur d'hébergement de fichiers. |
| **Kanidm**   | Fournisseur d'identité SSO (OIDC/OAuth2/LDAPS) avec provisioning déclaratif des utilisateurs et clients OAuth2. Gère les certificats ACME via LoadCredential systemd. |
| **www**     | Serveur de fichiers statiques avec paquet Nix optionnel. |

Le tout est orchestré par **Colmena** : un seul `just deploy` suffit pour
construire et déployer l'intégralité de la configuration sur tous les nœuds
en parallèle. Les certificats TLS (Let's Encrypt) sont renouvelés
automatiquement via un mécanisme de synchronisation entre nœuds (cert-syncer).

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

### Modules NixOS customs (dépôt public ou privé)

Vous pouvez créer vos propres modules NixOS (déclarant des options `infra.*`,
utilisant `services.hasTag`, `ops.mkSecretKeys`, etc.) dans **l'un ou l'autre**
des deux dépôts :

| Emplacement                                | Usage                                        |
|--------------------------------------------|----------------------------------------------|
| `nixos/modules/<catégorie>/` (dépôt public) | Modules réutilisables partagés entre projets |
| `modules/` (dépôt privé)                    | Modules spécifiques à votre infrastructure   |

Un module suit toujours le même pattern (voir [Guide complet](docs/MODULE-GUIDE.md)) :
1. Déclare ses options (`options.infra.<app>.*`)
2. Enregistre son tag (`infra.registeredTags`)
3. S'active conditionnellement (`lib.mkIf enabled`)
4. S'auto-enregistre (ingress, ACLs, backup, telemetry, dashboards)
5. Gère ses secrets via `ops.mkSecretKeys`

Les modules privés s'importent dans le `flake.nix` privé en les ajoutant
aux `imports` de la fonction `mkNode`.

### Paquets customs et binaires précompilés

Il est possible d'intégrer des binaires précompilés (sans accès au code source)
comme paquets Nix customs. Créez une dérivation dans `nixos/pkgs/<app>/` qui
utilise `fetchurl` pour télécharger le binaire et `autoPatchelfHook` pour
corriger les liens dynamiques.

Exemple : [`nixos/pkgs/filesave/filesave-server.nix`](nixos/pkgs/filesave/filesave-server.nix)
— un binaire `x86_64-linux` précompilé intégré sans recompilation. Le module
correspondant dans `nixos/modules/` référence le paquet via `pkgs.callPackage`
pour l'utiliser dans un service systemd.

Cette technique fonctionne aussi dans le dépôt privé : créez un dossier
`pkgs/` contenant vos propres dérivations, importez-les dans le `flake.nix`
privé, et référencez-les dans vos modules via `pkgs.callPackage`.

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
│   │   ├── applications/  ← docker-registry, gitea, ntfy, reposilite, filesave, www
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
