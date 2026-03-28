# Server Setup

Ce dépôt contient des scripts et des configurations pour automatiser la mise en place et la gestion de serveurs avec [NixOS](https://nixos.org) et [colmena](https://github.com/zhaofengli/colmena).

Pour le moment, le setup fonctionne sur des VPS OVH. Chaque serveur est initialement provisionné sous Debian 11, avec l'utilisateur `debian` accessible en ssh (port 22) via une clé préalablement configurée.

Prérequis :

- Terminal Bash
- Utilitaires de base : curl, jq, ssh, ... (non exhaustif)
- Nix installé sur la machine en local
- [Colmena](https://github.com/zhaofengli/colmena) disponible dans l'environnement (`nix-shell -p colmena` ou installé de manière permanente).
- Un ou plusieurs hôte(s) distant(s) à configurer/gérer.

## 1. Déploiement

Pour déployer les serveurs, il faut tout d’abord infecter chaque serveur manuellement avec NixOS.

```sh
./scripts/infect.sh -i <clé-ssh> <user>@<ip>
```

Le script utilise la clé SSH pour se connecter au serveur, copie la clé publique dans le compte root et lance le script [nixos-infect](https://github.com/elitak/nixos-infect).

Le serveur redémarrera sous NixOS, et l’utilisateur `root` sera accessible en SSH (port 22) avec la clé utilisée pour l’infection.

## 2. Configuration de Colmena

Il faut ensuite configurer la flotte Colmena. Le script `hive.nix` est géré par `inventory/topology.nix` (renommer le fichier `inventory/topology.example.nix`).

Il faut ajouter chaque hôte dans la config :

```nix
{
  nodes = {
    vps1 = {
      publicIp = "1.2.3.4";
      vpnIp = "10.100.0.1";
      ipv6 = "0001:0002:XXX";
      ipv6_gateway = "<a trouver dans le panel OVH>";

      user = "root";
      sshKey = "~/.ssh/id_ed25519"; # emplacement local
    };
}
```

Il faut ensuite exécuter le script `adopt-hardware.sh` afin de télécharger localement le fichier de configuration hardware généré par nixos-infect. Ce script télécharge, pour tous les serveurs déclarés dans `topology.nix`, le fichier `/etc/nixos/hardware-configuration.nix` et le copie dans le répertoire local `.secrets/<host>`.

```sh
./scripts/adopt-hardware.sh
```

Ensuite, le mesh WireGuard doit être généré localement : celui-ci génère, pour chaque serveur déclaré dans `topology.nix`, une clé privée WireGuard, ainsi qu'un fichier local `.secrets/mesh.nix` contenant la topologie et les clés de chaque nœud.

```sh
./scripts/generate-mesh.sh
```

Ne pas oublier de télécharger localement la clé publique de chaque serveur (`.secrets`). Ceci est utilisé lors de la configuration du serveur SSH de NixOS. Si la clé publique n'est pas téléchargée, l'ancienne configuration (de nixos-infect) sera écrasée et le serveur sera rendu inaccessible ; il faudra tout recommencer depuis le début (réinstallation OVH).

```sh
./scripts/export-ssh-key.sh
```

Et finalement, générer une clé SSH pour l'utilisateur `cert-syncer`, utilisé pour répliquer les certificats TLS générés par ACME. Cette partie est optionnelle si aucun nœud n'est taggé avec `acme-issuer` (voir plus loin).

```sh
./scripts/generate-key.sh
```

## 3. Configuration des serveurs

Tous les nœuds partagent la même configuration (dans `nixos/`), cependant certaines parties de la configuration ne sont pas activées, en fonction des tags dont chaque serveur dispose.

Tous les serveurs sont reliés par un réseau virtuel géré par WireGuard, l’IP virtuelle est définie dans `inventory/topology.nix`.

Chaque nœud doit être taggé pour activer ou désactiver certaines parties de la config ; la configuration en « réseau » est automatique, c’est-à-dire que les nœuds sont configurés pour interagir avec les autres nœuds de manière automatique. Si un nœud possède le tag `web-server`, il pourrait faire office d’accès frontend pour un service hébergé sur un autre nœud automatiquement (via le réseau WireGuard). L’avantage d’une configuration globale Colmena est la connaissance des autres peers au moment du build de l’image NixOS. Ceci implique également qu’à chaque modification de topologie (suppression, ajout de serveur), tous les nœuds doivent être mis à jour avec la nouvelle configuration.

Chaque serveur doit être taggé dans `inventory/services.nix` :

```nix
{
  vps1 = [
    "node-metrics"
    "prometheus"
    "backup"
  ];

  vps2 = [
    "node-metrics"
    "prometheus"
    "grafana"
    "acme-issuer"
    "web-server"
    "backup"
  ];
}
```

Pour déployer la configuration, utiliser colmena :

```sh
colmena apply

# Ou sur un seul host pour "tester":
colmena apply --on vps2
```

### Liste des tags

| Nom            | Description                                                                                                                                                                                                  |
| :------------- | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `node-metrics` | Active l'exportation des métriques du nœud (CPU, RAM, disque, etc.) via Prometheus Node Exporter.                                                                                                            |
| `prometheus`   | Déploie une instance Prometheus pour collecter et stocker les métriques provenant des autres nœuds (`node-metrics`).                                                                                         |
| `grafana`      | Installe et configure Grafana pour visualiser les données collectées par Prometheus. (config : `config/grafana`)                                                                                             |
| `acme-issuer`  | Désigne ce nœud comme responsable de la génération et du renouvellement des certificats SSL/TLS via ACME (Let's Encrypt). Configure ACME ainsi qu'un utilisateur SSH `cert-syncer`. (config : `config/acme`) |
| `web-server`   | Configure un serveur web (Nginx) pour servir des applications. Écoute sur le port public 443.                                                                                                                |
| `backup`       | Active les scripts et services de sauvegarde automatique (via restic). (config : `config/restic`)                                                                                                            |

Par défaut, seul le port 22 (SSH) est ouvert sur la machine ; les autres ports peuvent être ouverts par d'autres tags.

La philosophie est d'exposer les applications sur le réseau VPN (WireGuard) au lieu de bind sur le port public. Chaque application (du moins pour l'HTTP) doit donc passer par le proxy unique Nginx afin de sortir vers le monde extérieur.

### Configuration des applications

Certaines applications supportent des configurations externes. Chaque configuration est stockée dans le dossier `config/`.
Pour utiliser une app ou une configuration, il faut renommer le fichier `.example.nix` correspondant en `.nix`. Les variables sensibles ne sont PAS stockées dans le `/nix/store`, mais utilisent Colmena pour être envoyées de manière sécurisée sur le serveur.

### Applications (tags)

| Nom                            | Description                                                                                                          |
| :----------------------------- | :------------------------------------------------------------------------------------------------------------------- |
| `applications/docker-registry` | Déploie un registre Docker pour stocker et gérer les images conteneurs. (config : `config/docker-registry`)          |
| `applications/reposilite`      | Installe un gestionnaire de dépôts Maven compatible pour héberger des artefacts Java. (config : `config/reposilite`) |
| `applications/gitea`           | Déploie un serveur Gitea (config `config/gitea`)                                                                     |
| `applications/ntfy`            | Déploie un serveur ntfy pour les notifications push (config `config/ntfy`)                                           |
