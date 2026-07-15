# Mon infrastructure privée

Déploiement NixOS avec Colmena, les modules publics `server-setup` et des
secrets JSON chiffrés par SOPS.

## Démarrage

1. Remplace tous les `CHANGEME` dans `inventory/nodes.nix` et `config/`.
2. Entre dans l'environnement :

   ```sh
   nix develop
   ```

3. Infecte chaque serveur Debian :

   ```sh
   infect-server -i ~/.ssh/id_ed25519 --post-port 22 root@203.0.113.10
   ```

4. Prépare le projet :

   ```sh
   init-project
   ```

   Cette commande récupère le hardware et les clés SSH hôtes, génère les clés
   locales, crée `.sops.yaml` et chiffre les fichiers de secrets manquants. Elle
   ne remplace jamais un secret existant.

5. Renseigne uniquement les champs signalés :

   ```sh
   sops secrets/acme.json
   sops secrets/restic.json
   ```

6. Vérifie puis déploie :

   ```sh
   check-project
   deploy-project          # toute la flotte
   deploy-project vps1     # un seul hôte
   ```

## Règles simples

- `config/` contient uniquement les choix fonctionnels `infra.*` : URLs, ports,
  tags et options de service.
- `secrets/` contient uniquement les JSON chiffrés et leur courte documentation.
- Le câblage standard SOPS est fourni par `infra.nixosModules.sops` depuis le
  dépôt public ; il n'est pas recopié ici.
- Les fichiers privés WireGuard et cert-syncer restent ignorés par Git.
- Un module privé spécifique déclare lui-même ses éventuels secrets spécifiques.

## Commandes

| Commande | Rôle |
|---|---|
| `init-project` | Prépare les fichiers locaux et initialise SOPS |
| `update-sops-keys` | Met à jour les destinataires après un changement de nœud |
| `check-project` | Vérifie les placeholders, Nix et tous les nœuds Colmena |
| `deploy-project [hôte]` | Initialise, vérifie et déploie |
| `infect-server` | Remplace Debian par NixOS |
| `generate-mesh` | Régénère les clés WireGuard absentes |
| `adopt-hardware` | Récupère la configuration matérielle |

## Structure

```text
├── flake.nix
├── config/              # choix fonctionnels finaux
├── secrets/             # fichiers SOPS chiffrés
├── inventory/
│   ├── nodes.nix        # topologie et tags
│   ├── hardware/        # configurations matérielles
│   ├── wireguard/       # clés générées, privées ignorées
│   └── keys/            # clés générées, privées ignorées
└── README.md
```

## Ajouter un nœud

1. Ajoute-le dans `inventory/nodes.nix`.
2. Lance `infect-server` sur ce serveur.
3. Lance `init-project`, puis `deploy-project <hôte>`.

`init-project` recalcule les destinataires SOPS et re-chiffre les fichiers dans
une zone temporaire avant de remplacer les versions existantes.

## Ajouter une application

1. Ajoute son tag dans `inventory/nodes.nix`.
2. Ajoute ses choix non secrets dans `config/<app>/<app>.nix` et son import.
3. Lance `init-project`, complète les champs signalés, puis déploie.

Les modules standards connaissent déjà leurs fichiers et chemins SOPS. Pour un
module privé, garde son adaptateur secret dans ce module privé.
