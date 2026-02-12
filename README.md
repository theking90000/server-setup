# Server Setup

Ce dépot contient des scripts et des configurations pour automatiser la mise en place et la gestion de serveurs avec [NixOS](https://nixos.org) et [colmena](https://github.com/zhaofengli/colmena).

Pour le moment, le setup fonctionne sur des VPS OVH, chaque serveur est initialement provisionné sous Debian 11,avec l'utilisateur `debian` accessible en ssh (port 22) via une clé préalablement configurée.

Pré-requis:

- Terminal bash
- Utilitaires de base : curl, jq, ssh, ... (non-exhaustif)
- Nix installé sur la machine en local
- [Colmena](https://github.com/zhaofengli/colmena) disponible dans l'environment (`nix-shell -p colmena` ou installé de manière permanente).
- Un ou plusieurs hôte(s) distant(s) à configurer/gérer.

## 1. Déploiement

Pour déployer les serveurs, il faut tout d'abord infecter chaque serveur manuellement avec NixOS.

```sh
./scripts/infect.sh -i <clé-ssh> <user>@<ip>
```

Le script utilise la clé ssh pour se connecter au serveur, copie la clé publique dans l'utilisateur root et lance le script [nixos-infect](https://github.com/elitak/nixos-infect).

Le serveur redémarrera sous NixOS l'utilisateur `root` sera accessible en ssh (port 22) avec la clé utilisé pour l'infection.

## 2. Configuration de Colmena

Il faut ensuite configurer la flotte colmena. Le script hive.nix est géré par `inventory/topolgy.nix` (renommer le fichier inventory/topology.example.nix).

Il faut ajouter chaque hôte dans la config:

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

Il faut ensuite executer les scripts `adopt-hardware.sh` afin de télécharger le fichier de configuration hardware généré par nixos-infect localement. Ce script télécharge, pour tout les serveurs déclarés dans topology.nix le fichier `/etc/nixos/hardware-configuration.nix` et le copie dans le répertoire local `.secrets/<host>`

```sh
./scripts/adopt-hardware.sh
```

Ensuite, le mesh wireguard doit être généré localement celui-ci génère, pour chaque serveur déclaré dans `topology.nix` une clée privée wireguard ainsi qu'un fichier local `.secrets/mesh.nix` contenant la topologie et les clés de chaque noeud.

```sh
./scripts/generate-mesh.sh
```

Ne pas oublier de télécharger la clé publique de chaque serveur localement (.secrets). Ceci est utilisé lors de la configuration du serveur SSH de NixOS. Si la clé publique n'est pas téléchargées, l'ancienne configuration (de nixos-infect) sera écrasée et le serveur sera rendu inaccessible, il faudra tout recommencer depuis le début (réinstallation OVH).

```sh
./scripts/export-ssh-key.sh
```

Et finalement, générer une clé SSH pour l'utilisateur `cert-syncer`, utilisé pour répliquer les certificats TLS générés par ACME. Cette partie est optionnelle si aucun noeud n'est taggé avec `acme-issuer` (voir plus loin).

```sh
./scripts/generate-key.sh
```

## 3. Configuration des serveurs

Tous les noeuds partagent la même configuration (dans `nixos/`) cependant certaines parties de la configuration ne sont pas activées, en fonction des tags donc chaque serveur dispose.

Tous les serveurs sont reliés par un réseau virtuel géré par wireguard, l'ip virtuelle est définie dans `inventory/topology.nix`.

Chaque noeud doit être taggé pour activer ou désactiver certaines parties de la config, la configuration en 'réseau' est automatique, c'est à dire que les noeuds sont configurés pour intéragir avec les autres noeud de manière automatique. Si un noeud possède le tag `web-server` il pourrait faire office d'accès frontend pour un service hébergé sur un autre noeud automatiquement (via le réseau wireguard). L'avantage d'une configuration globale colmena est la connaissance des autres peers au moment du build de l'image NixOS. Ceci implique également qu'a chaque modification de topologie (suppression, ajout de serveur), tous les noeuds doivent être mis à jour avec la nouvelle configuration.

Chaque serveur doit être taggé dans `inventory/services.nix`:

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

Pour déploier la configuration utiliser colmena:

```sh
colmena apply

# Ou sur un seul host pour "tester":
colmena apply --on vps2
```

### Liste des tags

| Nom            | Description                                                                                                                                                                          |
| :------------- | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `node-metrics` | Active l'exportation des métriques du noeud (CPU, RAM, Disque, etc.) via Prometheus Node Exporter.                                                                                   |
| `prometheus`   | Déploie une instance Prometheus pour collecter et stocker les métriques provenant des autres noeuds (`node-metrics`).                                                                |
| `grafana`      | Installe et configure Grafana pour visualiser les données collectées par Prometheus.                                                                                                 |
| `acme-issuer`  | Désigne ce noeud comme responsable de la génération et du renouvellement des certificats SSL/TLS via ACME (Let's Encrypt). Configure ACME ainsi qu'un utilisateur ssh `cert-syncer`. |
| `web-server`   | Configure un serveur web (Nginx) pour servir des applications. Ecoute sur le port publique 443                                                                                       |
| `backup`       | Active les scripts et services de sauvegarde automatique (via restic).                                                                                                               |

Par défaut, seul le port 22 (ssh) est ouvert sur la machine, les autres ports peuvent être ouverts par d'autres tags.

La philosophie est d'exposer les applications sur le réseau VPN (wireguard) au lieu de bind sur le port publique. Chaque application (du moins pour l'HTTP) doit donc passer par le proxy unique nginx afin de sortir vers le monde extérieur.
