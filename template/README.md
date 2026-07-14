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
      ipv6Gateway = "2001:41d0:305:2100::1"; # Passerelle IPv6

      publicInterface = "ens3";         # Interface publique (défaut: ens3)
      useDHCP = true;                   # DHCP sur l'interface publique (défaut: true)

      sshKey = "~/.ssh/id_ed25519";      # Chemin local de votre clé SSH
      sshPort = 22;                       # Port SSH final après infection

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
- `config/jellyfin/jellyfin.nix` → URL
- `config/docker-registry/docker-registry.nix` → URL, comptes htpasswd
- `config/ntfy/ntfy.nix` → URL, upstream
- `config/reposilite/reposilite.nix` → URL
- `config/filesave/filesave.nix` → URL
- `config/kanidm/kanidm.nix` → URL, users OAuth2, LDAPS (optionnel)
- `config/rclone-sync/rclone-sync.nix` → montages rclone (S3, SFTP, …) par nœud
- `config/www/www.nix` → URL, paquet Nix optionnel

Supprimez les fichiers `config/<app>/<app>.nix` des applications que vous
n'utilisez pas, et retirez-les de `config/default.nix`.

### 3. Mettre à jour la librairie publique

```sh
nix flake update infra
```

### 4. Infecter les VPS avec NixOS

Pour chaque VPS Debian 11 :

```sh
infect-server -i ~/.ssh/id_ed25519 --post-port <port-final> root@<ip-publique>
```

Le serveur redémarre sous NixOS. Le compte `root` est accessible en SSH
avec la clé utilisée pour l'infection.

### 5. Adopter le matériel et préparer les fichiers locaux

```sh
just prepare
```

`just prepare` ne déploie rien. Il génère le mesh, adopte le matériel et
exporte les clés nécessaires.

### 6. Vérifier sans déployer

```sh
just check
```

`nix flake check` vérifie les sorties déclarées par le flake. La seconde
commande de la recette force en plus l'évaluation complète des `drvPath` de
tous les nœuds avec Colmena ; elle ne construit ni ne déploie les systèmes.

### 7. Déployer

```sh
just deploy               # tous les nœuds
just deploy vps1          # un seul nœud
```

## Structure

```
├── flake.nix            ← flake principal (input infra + colmena)
├── justfile             ← commandes just (deploy, generate-mesh, etc.)
├── .gitignore           ← ignore inventory/keys/ et wireguard/
├── config/              ← valeurs des options infra.*
│   ├── default.nix      ← imports de tous les fichiers de config
│   ├── acme/acme.nix
│   ├── grafana/grafana.nix
│   └── ...
├── inventory/
│   ├── nodes.nix        ← topologie (IPs, tags, clé SSH)
│   ├── hardware/        ← placeholder suivi, remplacé par adopt-hardware
│   ├── wireguard/       ← généré par generate-mesh
│   └── keys/            ← généré par export-ssh-key
└── README.md            ← ce fichier
```

## Commandes utiles

| Commande             | Description                              |
|----------------------|------------------------------------------|
| `just`               | Liste toutes les commandes               |
| `just check`         | Évalue tous les nœuds sans déployer      |
| `just prepare`       | Prépare les fichiers locaux              |
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
3. `just prepare`
4. `just check`
5. `just deploy`

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
