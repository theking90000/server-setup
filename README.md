# Server Setup

Ce dépot contient des scripts et des configurations pour automatiser la mise en place et la gestion de serveurs avec [NixOS](https://nixos.org) et [colmena](https://github.com/zhaofengli/colmena)

Pour le moment, le setup fonctionne sur des VPS OVH, chaque serveur est initialement provisionné avec Debian 11, avec une clé ssh autorisée dans l'utilisateur `debian`.

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

Ne pas oublier de télécharger la clé publique de chaque serveur localement (.secrets)

```sh
./scripts/export-ssh-key.sh
```

Et finalement, générer une clé SSH pour l'utilisateur `cert-syncer`, utilisé pour répliquer les certificats TLS générés par ACME.

```sh
./scripts/generate-key.sh
```
