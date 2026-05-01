# Mon Infrastructure Privée

Déploiement NixOS + Colmena pour mon infra.

## Démarrage

```sh
nix develop
```

Cela donne accès aux outils : `colmena`, `just`, et tous les scripts
(`infect-server`, `generate-mesh`, `adopt-hardware`, etc.).

## Étapes de déploiement

### 1. Configurer les nœuds

Édite `inventory/nodes.nix` — remplace **tous** les `CHANGEME` :

```nix
{
  nodes = {
    vps1 = {
      publicIp = "51.38.239.124";       # IP publique du VPS
      vpnIp = "10.100.0.1";             # IP WireGuard (unique par nœud)
      ipv6 = "2001:41d0:305:2100::a38c"; # IPv6 (dans le panel OVH)
      ipv6_gateway = "2001:41d0:305:2100::1"; # Passerelle IPv6

      publicInterface = "ens3";         # Interface publique (défaut: ens3)
      useDHCP = true;                   # DHCP sur l'interface publique (défaut: true)

      user = "root";
      sshKey = "~/.ssh/id_ed25519";      # Chemin local de votre clé SSH

      tags = [                           # Services à activer sur ce nœud
        "web-server"
        "acme-issuer"
        "node-metrics"
        "backup"
      ];
    };

    # Ajoute d'autres nœuds ici si besoin
  };
}
```

### 2. Configurer les applications

Édite les fichiers dans `config/` — remplace **tous** les `CHANGEME` :

- `config/acme/acme.nix` → email Let's Encrypt, credentials DNS OVH
- `config/grafana/grafana.nix` → mot de passe, URL, secret
- `config/restic/restic.nix` → repo S3, mot de passe, credentials AWS
- `config/gitea/gitea.nix` → URL
- `config/docker-registry/docker-registry.nix` → URL, comptes htpasswd
- `config/ntfy/ntfy.nix` → URL, upstream
- `config/reposilite/reposilite.nix` → URL
- `config/filesave/filesave.nix` → URL

Supprimez les fichiers `config/<app>/<app>.nix` des applications que vous
n'utilisez pas, et retirez-les de `config/default.nix`.

### 3. Mettre à jour la librairie publique

```sh
nix flake update infra
```

### 4. Infecter les VPS avec NixOS

Pour chaque VPS Debian 11 :

```sh
infect-server -i ~/.ssh/id_ed25519 root@<ip-publique>
```

Le serveur redémarre sous NixOS. Le compte `root` est accessible en SSH
avec la clé utilisée pour l'infection.

### 5. Préparer le déploiement

```sh
just deploy
```

Cette commande exécute automatiquement :
1. `adopt-hardware` → télécharge les configs matérielles depuis les VPS
2. `generate-mesh` → génère les clés WireGuard du mesh
3. `export-ssh-key` → télécharge les clés SSH publiques des hôtes
4. `generate-key` → génère la clé SSH pour le cert-syncer (ACME)
5. `colmena apply` → déploie la configuration sur tous les nœuds

### 6. Déploiement ciblé (optionnel)

```sh
just deploy --on vps1     # un seul nœud
```

## Structure

```
├── flake.nix            ← flake principal (input infra + colmena)
├── justfile             ← commandes just (deploy, generate-mesh, etc.)
├── .gitignore           ← ignore inventory/keys/, wireguard/, hardware/
├── config/              ← valeurs des options infra.*
│   ├── default.nix      ← imports de tous les fichiers de config
│   ├── acme/acme.nix
│   ├── grafana/grafana.nix
│   └── ...
├── inventory/
│   ├── nodes.nix        ← topologie (IPs, tags, clé SSH)
│   ├── hardware/        ← généré par adopt-hardware
│   ├── wireguard/       ← généré par generate-mesh
│   └── keys/            ← généré par export-ssh-key
└── README.md            ← ce fichier
```

## Commandes utiles

| Commande             | Description                              |
|----------------------|------------------------------------------|
| `just`               | Liste toutes les commandes               |
| `just deploy`        | Déploiement complet (tous les nœuds)     |
| `just deploy vps1`   | Déploiement sur un seul nœud             |
| `just update-lib`    | Met à jour la librairie publique         |
| `just generate-mesh` | Régénère le mesh WireGuard               |
| `just adopt-hardware`| Re-télécharge les configs hardware       |
| `just export-keys`   | Re-exporte les clés SSH                  |
| `infect-server`      | Infecte un VPS (une seule fois)          |

## Ajouter un nouveau nœud

1. Ajoute le nœud dans `inventory/nodes.nix` avec ses IPs et tags
2. `infect-server -i ~/.ssh/id_ed25519 root@<ip>`
3. `just deploy`

Tous les nœuds seront re-déployés avec la nouvelle topologie (WireGuard,
ACLs, etc.).

## Ajouter une nouvelle application

1. Ajoute le tag correspondant au nœud dans `inventory/nodes.nix`
2. Crée le fichier de config dans `config/<app>/<app>.nix`
3. Ajoute l'import dans `config/default.nix`
4. `just deploy`

## Paquets customs et modules privés

### Binaires précompilés

Si vous avez besoin d'intégrer des binaires précompilés sans code source,
vous pouvez créer vos propres dérivations Nix. Ajoutez un dossier `pkgs/`
dans votre dépôt privé contenant des fichiers comme celui-ci :

```nix
# pkgs/mon-app/mon-app.nix
{ stdenv, fetchurl, autoPatchelfHook }:
stdenv.mkDerivation {
  pname = "mon-app";
  version = "1.0.0";
  src = fetchurl {
    url = "https://example.com/mon-app-linux64";
    sha256 = "sha256-...";
  };
  dontUnpack = true;
  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib ];
  installPhase = ''
    install -m755 -D $src $out/bin/mon-app
  '';
}
```

Puis importez le paquet dans votre flake et référencez-le dans vos modules
via `pkgs.callPackage ./pkgs/mon-app/mon-app.nix {}`.

### Modules NixOS customs

Vous pouvez créer vos propres modules NixOS dans votre dépôt privé
(par exemple dans un dossier `modules/`). Importez-les dans le `flake.nix`
privé en les ajoutant aux `imports` de la fonction `mkNode` :

```nix
mkNode = name: node: {
  imports = [
    ./inventory/hardware/${name}/hardware.nix
    ./config
    ./modules                    # vos modules customs
    infra.nixosModules.default
  ];
  # ...
};
```

Les modules customs peuvent déclarer leurs propres options `infra.*`
et utiliser `services.hasTag`, `ops.mkSecretKeys`, etc. comme n'importe
quel module du dépôt public.
