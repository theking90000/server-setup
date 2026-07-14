# Secrets du projet

Ce dossier est l'unique adaptateur entre les choix fonctionnels `infra.*` et
SOPS. Les fichiers de `config/` ne doivent contenir ni déclaration
`sops.secrets`, ni chemin `/run/secrets`, ni détail systemd.

## Initialisation

1. Convertir les clés SSH Ed25519 de l'administrateur et des hôtes en clés Age :

   ```sh
   ssh-to-age < ~/.ssh/id_ed25519.pub
   ssh-to-age < inventory/keys/vps1/key.pub
   ```

2. Remplacer les destinataires `CHANGEME` dans `.sops.yaml`.
3. Créer uniquement les fichiers nécessaires aux tags activés :

   ```sh
   sops secrets/acme.json
   sops secrets/acme-syncer.json
   sops secrets/restic.json
   sops secrets/grafana.json
   sops secrets/kanidm.json
   sops secrets/docker-registry.json
   mkdir -p secrets/wireguard
   sops secrets/wireguard/vps1.json
   ```

Les clés attendues sont :

| Fichier | Clés |
|---|---|
| `acme.json` | `dnsCredentials` |
| `acme-syncer.json` | `privateKey` |
| `restic.json` | `repository`, `password`, `env` |
| `grafana.json` | `password`, `grafana_secret`, `oidc_client_secret` |
| `kanidm.json` | `idm_admin_password` |
| `docker-registry.json` | `accounts` |
| `wireguard/<hôte>.json` | `privateKey` |

`oidc_client_secret` et `idm_admin_password` sont nécessaires quand Grafana et
Kanidm sont tous deux activés. Grafana s'enregistre alors automatiquement dans
Kanidm ; aucun client OAuth2 ne doit être recopié dans `config/kanidm`.

`just prepare` génère les clés privées WireGuard et cert-syncer dans les
dossiers ignorés d'`inventory/`. Copiez leurs valeurs dans les fichiers SOPS
ci-dessus avant le premier `just check`; ne les ajoutez jamais à Git.

Pour Rclone, ajoutez le fichier chiffré et son branchement technique dans
`secrets/default.nix`, car les noms de montage sont propres à chaque projet.

Ne déchiffrez jamais un secret avec `builtins.readFile` : SOPS le matérialise
dans `/run/secrets` lors de l'activation du système.
