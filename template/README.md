# Mon infrastructure privée

Ce dépôt déploie une flotte NixOS avec Colmena et les modules publics
`server-setup`. Il contient la topologie réelle, les choix fonctionnels et les
secrets JSON chiffrés par SOPS.

Le guide complet est disponible dans le dépôt public :
[installation de A à Z](https://github.com/theking90000/server-setup/blob/main/docs/SETUP-GUIDE.md).

## Premier déploiement

1. Remplacez tous les `CHANGEME` de `inventory/nodes.nix` et `config/`.
2. Chargez les outils :

   ```sh
   nix develop
   ```

3. Infectez chaque serveur Debian neuf :

   ```sh
   infect-server \
     -i ~/.ssh/id_ed25519 \
     -p 22 \
     --post-port 22 \
     debian@203.0.113.10
   ```

4. Préparez le dépôt :

   ```sh
   init-project
   ```

5. Éditez seulement les fichiers et champs signalés :

   ```sh
   sops secrets/acme.json
   sops secrets/restic.json
   ```

6. Vérifiez et déployez d'abord un canari :

   ```sh
   check-project
   deploy-project vps1
   deploy-project
   ```

`init-project` récupère le hardware et les clés SSH hôtes, génère les clés
WireGuard et cert-syncer, maintient `.sops.yaml`, puis crée uniquement les
secrets standards absents. Il ne remplace jamais un secret existant.

## Où modifier quoi

| Chemin | Contenu |
|---|---|
| `inventory/nodes.nix` | Nœuds, IP, SSH et tags |
| `config/` | URLs, ports et feature flags non secrets |
| `secrets/` | Valeurs finales chiffrées par SOPS |
| `inventory/hardware/` | Hardware NixOS récupéré par `init-project` |
| `modules/` | Éventuels modules propres à ce projet |
| `flake.nix` | Assemblage Colmena et imports |

Règles :

- ne placez jamais de secret, `sops.secrets`, `/run/secrets` ou
  `deployment.keys` dans `config/` ;
- ne créez pas de copie claire d'un JSON : utilisez `sops <fichier>` ;
- le câblage SOPS standard appartient déjà au module public du service ;
- un module privé reste responsable de ses propres secrets et unités systemd ;
- les clés privées sous `inventory/keys/` et `inventory/wireguard/` sont
  ignorées par Git et doivent être sauvegardées séparément.

## Commandes courantes

| Commande | Usage |
|---|---|
| `init-project` | Préparer ou compléter le dépôt sans écraser l'existant |
| `update-sops-keys` | Recalculer les destinataires après un changement de nœud |
| `check-project` | Vérifier placeholders, séparation config/secrets, Nix et Colmena |
| `deploy-project <hôte>` | Initialiser, vérifier et déployer un canari |
| `deploy-project` | Initialiser, vérifier et déployer toute la flotte |
| `infect-server` | Installer NixOS sur un serveur Debian neuf |
| `adopt-hardware` | Récupérer le hardware sans exécuter toute l'initialisation |
| `generate-mesh` | Générer les clés WireGuard absentes |

## Ajouter un nœud

1. Ajoutez-le dans `inventory/nodes.nix` avec une `vpnIp` unique.
2. Infectez le serveur.
3. Lancez `init-project` pour ajouter sa clé hôte aux destinataires SOPS.
4. Déployez avec `deploy-project <hôte>`, puis la flotte.

## Retirer un nœud

1. Sauvegardez ses données, puis retirez-le de `inventory/nodes.nix`.
2. Lancez `update-sops-keys`.
3. Commitez `.sops.yaml` et tous les JSON re-chiffrés ensemble.
4. Lancez `check-project`.

## Ajouter un service

1. Ajoutez son tag au nœud choisi.
2. Renseignez ses options non secrètes dans `config/<service>/`.
3. Préparez son DNS public si nécessaire.
4. Lancez `init-project`, puis complétez les champs chiffrés signalés.
5. Vérifiez et déployez un canari.

Pour créer un nouveau module, suivez le
[guide des modules](https://github.com/theking90000/server-setup/blob/main/docs/MODULE-GUIDE.md).
Pour les comptes et groupes SSO, utilisez le
[guide Kanidm](https://github.com/theking90000/server-setup/blob/main/docs/KANIDM-CLI.md).

## Avant chaque push

```sh
check-project
git status
```

Les fichiers `.sops.yaml`, `secrets/*.json`, `inventory/hardware/`, `config/`,
`inventory/nodes.nix` et `flake.lock` font normalement partie du dépôt privé.
