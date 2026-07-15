# Installer une infrastructure de A à Z

Ce guide part d'un poste qui possède Nix et d'un ou plusieurs serveurs Debian
neufs. Il mène à une flotte NixOS vérifiée et déployée avec Colmena, WireGuard,
SOPS et les modules publics `server-setup`.

> **Attention :** `infect-server` remplace le système du serveur. Utilisez-le
> uniquement sur une machine neuve ou sauvegardée. L'adresse IP, le port SSH et
> la clé d'accès doivent être vérifiés avant de lancer la commande.

## 1. Ce qui vit dans chaque dépôt

Le dépôt public contient le fonctionnement réutilisable : modules NixOS,
scripts et template. Votre dépôt privé contient uniquement :

- `inventory/nodes.nix` : topologie, tags et paramètres SSH ;
- `config/` : URLs et choix fonctionnels ;
- `secrets/` : JSON chiffrés par SOPS ;
- les configurations matérielles récupérées sur les machines ;
- les éventuels modules propres à cette infrastructure.

SOPS est intégré à `infra.nixosModules.default`. Chaque module public déclare
ses propres secrets ; le dépôt privé ne recopie aucun adaptateur central.

## 2. Prérequis

Sur le poste d'administration :

- Nix avec `nix-command` et `flakes` activés ;
- une clé SSH Ed25519 permettant d'accéder aux serveurs ;
- Git ;
- un accès au compte qui gère la zone DNS ;
- des credentials pour le stockage Restic ou Rclone si ces rôles sont activés.

Installez Nix depuis la [page officielle](https://nixos.org/download/) et
validez l'accès au flake :

```sh
nix flake show github:theking90000/server-setup
```

Pour chaque serveur, relevez : IPv4 publique, IPv6 et passerelle éventuelles,
interface réseau publique, utilisateur Debian, port SSH initial et clé SSH.

## 3. Créer le dépôt privé

Une seule commande copie le template, initialise Git et crée le premier commit :

```sh
nix run github:theking90000/server-setup#bootstrap-project -- ./my-infra
cd ./my-infra
```

Si le commit initial échoue parce que Git n'a pas encore d'identité, les
fichiers sont déjà copiés. Configurez `user.name` et `user.email`, puis terminez
dans le dossier créé avec `git add -A && git commit -m "Initial commit"`.

Créez ensuite un dépôt Git **privé** chez votre hébergeur. Ne publiez jamais ce
dépôt, même si les fichiers SOPS sont chiffrés : sa topologie reste sensible.

## 4. Décrire les nœuds

Éditez `inventory/nodes.nix`. Chaque nom d'attribut devient le nom du nœud
Colmena et son hostname NixOS.

```nix
{
  nodes.vps1 = {
    publicIp = "203.0.113.10";
    vpnIp = "10.100.0.1";
    ipv6 = "2001:db8::10";
    ipv6Gateway = "2001:db8::1";
    publicInterface = "ens3";
    useDHCP = true;
    sshKey = "~/.ssh/id_ed25519";
    sshPort = 22;
    tags = [
      "web-server"
      "acme-issuer"
      "node-metrics"
      "backup"
    ];
  };
}
```

| Champ | Choix |
|---|---|
| `publicIp` | IPv4 joignable par SSH et Colmena |
| `vpnIp` | Adresse privée unique du mesh, par exemple `10.100.0.x` |
| `ipv6`, `ipv6Gateway` | Valeurs fournisseur, ou `null` si inutilisées |
| `publicInterface` | Interface réelle : `ens3`, `eth0`, `enp1s0`, etc. |
| `useDHCP` | `true` si le fournisseur configure l'IPv4 par DHCP |
| `sshKey` | Clé privée locale utilisée pour root après infection |
| `sshPort` | Port SSH **final** NixOS, identique à `--post-port` |
| `tags` | Services activés sur ce nœud |

Les `vpnIp` doivent être uniques. Un tag inconnu est volontairement refusé à
l'évaluation afin de détecter les fautes de frappe.

### Tags courants

| Tag | Fonction |
|---|---|
| `web-server` | Nginx public et ingress HTTPS |
| `acme-issuer` | Émission DNS-01 et distribution des certificats |
| `node-metrics` | Node Exporter |
| `prometheus` | Collecte des métriques |
| `grafana` | Visualisation et dashboards |
| `backup` | Sauvegarde Restic des chemins déclarés |
| `kanidm` | Identité et SSO |
| `applications/gitea` | Forge Git |
| `applications/docker-registry` | Registre OCI privé |
| `applications/jellyfin` | Serveur multimédia |
| `applications/ntfy` | Notifications |
| `applications/filesave-server` | Partage de fichiers |
| `applications/reposilite` | Dépôt Maven |
| `applications/www` | Site statique |
| `raspberry-pi` | Modules matériels Raspberry Pi 5 du template |

Rclone ne possède pas de tag : chaque montage nomme directement ses
`targetNodes`.

## 5. Choisir les services et préparer le DNS

Éditez uniquement les fichiers des services dont un tag est activé dans la
flotte. `config/` ne doit contenir que des valeurs non secrètes : URL, port ou
fonctionnalité.

```nix
{
  infra.gitea = {
    url = "https://git.example.com";
    registrationEnabled = false;
  };
}
```

Remplacez les `CHANGEME` des services activés. Un fichier de configuration peut
rester importé et inchangé si son tag n'est utilisé sur aucun nœud : ses valeurs
ne sont alors pas évaluées. Une erreur de syntaxe Nix reste toujours bloquante,
car tout fichier importé doit pouvoir être parsé.

Pour chaque URL publique, créez dans votre zone DNS :

- un enregistrement `A` vers l'IPv4 du nœud `web-server` ;
- un enregistrement `AAAA` vers son IPv6 si l'IPv6 est réellement routée ;
- aucun enregistrement vers l'IP WireGuard.

Tous les services publics arrivent sur Nginx. Nginx rejoint ensuite les
applications par le mesh WireGuard et déduit automatiquement les domaines ACME
depuis les ingress.

### Credentials OVH pour Lego/ACME

Le template utilise le provider DNS `ovh`. Configurez l'email ACME :

```nix
{
  infra.acme = {
    email = "admin@example.com";
    dnsProvider = "ovh";
  };
}
```

Créez des credentials OVH dédiés depuis la
[page de création de token OVH](https://www.ovh.com/auth/api/createToken). Pour
l'authentification Application Key, Lego attend :

```text
OVH_ENDPOINT=ovh-eu
OVH_APPLICATION_KEY=...
OVH_APPLICATION_SECRET=...
OVH_CONSUMER_KEY=...
```

Le Consumer Key doit au minimum pouvoir créer et supprimer les enregistrements
de la zone (`POST /domain/zone/*` et `DELETE /domain/zone/*`). Utilisez
`ovh-ca` au lieu de `ovh-eu` pour un compte canadien. Ne mélangez pas cette
méthode avec les credentials OAuth OVH. La liste officielle et les politiques
IAM alternatives sont documentées par
[Lego](https://go-acme.github.io/lego/dns/ovh/).

Ces valeurs ne vont jamais dans `config/acme/acme.nix`. Elles seront saisies
dans `secrets/acme.json` après l'initialisation.

## 6. Entrer dans l'environnement

```sh
nix develop
```

Le dev shell fournit Colmena, SOPS, WireGuard et tous les scripts du projet. Si
vous utilisez `direnv`, le `.envrc` fourni contient déjà `use flake` ; autorisez
le dossier avec `direnv allow`.

## 7. Infecter les serveurs

Vérifiez d'abord manuellement l'accès Debian :

```sh
ssh -i ~/.ssh/id_ed25519 -p 22 debian@203.0.113.10
```

Puis lancez l'infection pour chaque machine :

```sh
infect-server \
  -i ~/.ssh/id_ed25519 \
  -p 22 \
  --post-port 22 \
  debian@203.0.113.10
```

- `-p` est le port SSH du système Debian initial ;
- `--post-port` est le port NixOS final renseigné dans `nodes.nix` ;
- l'utilisateur initial peut être `debian`, `ubuntu` ou `root`, avec `sudo` si
  nécessaire ;
- après infection, les scripts et Colmena se connectent en `root`.

Le script installe la clé publique avant le reboot, épingle et vérifie le hash
de `nixos-infect`, puis attend le retour de SSH. Si l'hôte est déjà NixOS, il ne
le réinfecte pas.

## 8. Initialiser le projet

Une commande prépare tout ce qui peut l'être :

```sh
init-project
```

Elle effectue de manière idempotente :

1. la génération des paires WireGuard absentes ;
2. la récupération des configurations matérielles ;
3. l'export des clés SSH publiques d'administration ;
4. la génération de la paire cert-syncer ;
5. la création ou mise à jour de l'identité Age administrateur ;
6. la lecture authentifiée de la clé SSH hôte de chaque serveur ;
7. la génération de `.sops.yaml` et le re-chiffrement transactionnel des
   fichiers existants si les destinataires ont changé ;
8. la création des fichiers de secrets standards absents.

Un secret existant n'est jamais remplacé. Si une clé hôte ou un re-chiffrement
échoue, `update-sops-keys` ne remplace ni l'ancienne configuration ni les
anciens fichiers.

### Identité Age administrateur

Le chemin par défaut suit la convention SOPS :

| Système | Chemin |
|---|---|
| macOS | `~/Library/Application Support/sops/age/keys.txt` |
| Linux | `${XDG_CONFIG_HOME:-~/.config}/sops/age/keys.txt` |

Le fichier est créé en mode `0600`. Sauvegardez-le dans un coffre sûr : il
permet d'administrer tous les secrets du projet. Pour un chemin différent,
exportez `SOPS_AGE_KEY_FILE` avant d'utiliser les scripts.

La politique actuelle reste volontairement simple : l'identité administrateur
et les clés SSH hôtes de **tous** les nœuds sont destinataires de **tous** les
fichiers SOPS.

## 9. Compléter les secrets externes

À la fin, `init-project` affiche exactement chaque fichier et champ contenant
encore `CHANGEME`. Éditez-les avec SOPS :

```sh
sops secrets/acme.json
sops secrets/restic.json
sops secrets/docker-registry.json
sops secrets/rclone-sync.json
```

N'utilisez pas un éditeur qui écrit une copie claire dans le dépôt. `sops`
déchiffre dans un temporaire protégé puis réécrit le fichier chiffré.

| Fichier | Champ | Origine |
|---|---|---|
| `wireguard/<hôte>.json` | `privateKey` | Généré automatiquement |
| `acme.json` | `dnsCredentials` | Credentials OVH/Lego à fournir |
| `acme-syncer.json` | `privateKey` | Généré si plusieurs nœuds |
| `restic.json` | `repository` | URL du repository à fournir |
| `restic.json` | `password` | Généré automatiquement |
| `restic.json` | `env` | Credentials du backend à fournir |
| `grafana.json` | `password`, `grafana_secret` | Générés automatiquement |
| `grafana.json` | `oidc_client_secret` | Généré si Grafana est actif |
| `gitea.json` | `oidc_client_secret` | Généré si Gitea + Kanidm sont actifs |
| `kanidm.json` | `idm_admin_password` | Généré si un client SSO est actif |
| `docker-registry.json` | `accounts` | Contenu htpasswd à fournir |
| `rclone-sync.json` | clé portant le nom du montage | `rclone.conf` complet à fournir |

Pour le registre, générez une ligne htpasswd bcrypt sans installer durablement
un outil :

```sh
nix shell nixpkgs#apacheHttpd -c htpasswd -Bbn mon-utilisateur
```

Copiez la ligne produite dans le champ `accounts` avec `sops`. Pour Restic,
`repository` est par exemple une URL `s3:...`; `env` contient les variables
requises par ce backend, une par ligne. Pour Rclone, la valeur du champ est le
contenu complet d'une configuration fonctionnelle, y compris ses sections
`remote` et éventuelle `crypt`.

## 10. Vérifier puis déployer

```sh
check-project
```

La commande :

- refuse tout `CHANGEME` dans les valeurs déchiffrées sans les afficher ;
- refuse le câblage de secrets dans `config/` ;
- lance `nix flake check --all-systems` ;
- évalue le `drvPath` de tous les nœuds Colmena.

Déployez d'abord un nœud canari :

```sh
deploy-project vps1
```

`deploy-project` relance l'initialisation et les vérifications avant
`colmena apply --on vps1`. Une fois le canari vérifié, déployez toute la flotte :

```sh
deploy-project
```

Sur le canari, contrôlez au minimum :

```sh
ssh root@203.0.113.10 systemctl --failed
ssh root@203.0.113.10 systemctl status wireguard-wg0
```

Testez ensuite les URLs publiques, les certificats, les métriques, les backups
et le SSO correspondant aux tags réellement activés.

## 11. Parcours minimal « trois minutes »

Le temps réseau, l'infection et l'obtention des credentials fournisseurs sont
hors mesure. Une personne qui dispose déjà de ces éléments suit seulement :

```sh
nix run github:theking90000/server-setup#bootstrap-project -- ./my-infra
cd ./my-infra
# éditer inventory/nodes.nix et la config des services activés
nix develop
# infect-server ... pour chaque machine
init-project
# sops <chaque fichier signalé>
deploy-project vps1
deploy-project
```

Il n'y a ni `justfile`, ni manifeste de secrets à maintenir, ni adaptateur SOPS
à recopier.

## 12. Opérations courantes

### Ajouter un nœud

1. Ajoutez le nœud et ses tags dans `inventory/nodes.nix`.
2. Infectez-le.
3. Lancez `init-project` : la nouvelle clé hôte est ajoutée aux destinataires et
   les fichiers sont re-chiffrés dans une zone temporaire.
4. Complétez les éventuels nouveaux placeholders.
5. Lancez `deploy-project <nouvel-hôte>`, puis `deploy-project`.

### Retirer un nœud

1. Retirez-le de `inventory/nodes.nix` après avoir sauvegardé les données utiles.
2. Lancez `update-sops-keys` pour retirer son destinataire de tous les fichiers.
3. Vérifiez le diff chiffré, puis lancez `check-project`.

Retirer un destinataire SOPS empêche l'usage futur de sa clé pour les nouvelles
versions des fichiers ; cela n'efface pas les anciennes copies qu'il aurait pu
conserver.

### Ajouter un service public existant

1. Ajoutez son tag au bon nœud.
2. Renseignez ses options non secrètes dans `config/<service>/`.
3. Préparez DNS si une URL publique est utilisée.
4. Lancez `init-project`, éditez les champs signalés, puis `check-project`.
5. Déployez un canari.

### Ajouter un module privé

Placez-le dans `modules/`, importez ce dossier dans le flake et gardez dans ce
module toute sa responsabilité, y compris ses déclarations SOPS. Ne modifiez le
script public `init-project` que si le secret devient un contrat standard du
dépôt public ; sinon créez le fichier chiffré une fois avec `sops`.

### Modifier les destinataires sans autre initialisation

```sh
update-sops-keys
```

Cette commande est suffisante après un ajout, un retrait ou un remplacement de
clé hôte. Relisez et commitez `.sops.yaml` et les fichiers chiffrés ensemble.

### Rotation d'un credential

```sh
sops secrets/<service>.json
check-project
deploy-project <canari>
```

Ne supprimez pas le fichier entier : `init-project` recréerait aussi les valeurs
internes, ce qui provoquerait des rotations supplémentaires.

## 13. Diagnostic

### `init-project` refuse encore `CHANGEME`

Les placeholders de `inventory/nodes.nix` doivent être remplacés avant toute
connexion. Après initialisation, la liste restante concerne uniquement les
credentials externes chiffrés.

### Impossible de lire la clé SSH hôte

Vérifiez :

```sh
ssh -i ~/.ssh/id_ed25519 -p 22 root@203.0.113.10 \
  cat /etc/ssh/ssh_host_ed25519_key.pub
```

Le `sshKey`, le `sshPort`, l'IPv4 et l'accès root doivent correspondre à
`inventory/nodes.nix`. N'acceptez pas aveuglément un changement inattendu de
clé hôte : confirmez qu'il s'agit bien de la machine réinstallée.

### SOPS ne peut pas déchiffrer

Vérifiez le chemin et le mode `0600` de l'identité Age. Si
`SOPS_AGE_KEY_FILE` n'est pas définie, utilisez le chemin standard de votre OS
indiqué plus haut. Une
copie valide de la clé Age administrateur est le moyen normal de récupération.
Sans elle, une clé SSH hôte encore destinataire peut techniquement déchiffrer
les fichiers sur cet hôte ; traitez cette récupération comme une opération de
sécurité et sauvegardez d'abord les fichiers chiffrés.

### Le challenge OVH échoue

Vérifiez l'endpoint, les quatre variables, les droits de création/suppression
DNS et la zone concernée. Consultez les logs sans afficher les credentials :

```sh
journalctl -u acme-\*.service --since today
```

Attendez aussi la propagation DNS avant de conclure à un problème de module.

### Colmena retourne un échec après activation

Commencez par la cible :

```sh
ssh root@203.0.113.10 systemctl --failed
ssh root@203.0.113.10 journalctl -b -p warning
```

Une évaluation Nix réussie ne garantit pas qu'un credential externe, un
endpoint ou une migration applicative fonctionne au runtime.

## 14. Ce qui doit être commité

Commitez ensemble :

- `inventory/nodes.nix` ;
- `inventory/hardware/` ;
- `config/` ;
- `.sops.yaml` ;
- tous les JSON SOPS chiffrés ;
- le `flake.lock` après une mise à jour volontaire.

Les dossiers `inventory/keys/` et `inventory/wireguard/` sont ignorés par le
template car ils contiennent des clés privées. Sauvegardez-les séparément et de
manière chiffrée. Vérifiez toujours `git status` avant de pousser.

Pour comprendre ou créer un module, continuez avec
[`MODULE-GUIDE.md`](MODULE-GUIDE.md). Pour administrer Kanidm après le premier
déploiement, utilisez [`KANIDM-CLI.md`](KANIDM-CLI.md).
