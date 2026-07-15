# Secrets chiffrés

Ce dossier contient uniquement les valeurs JSON chiffrées par SOPS. Les
déclarations `sops.secrets`, chemins runtime, propriétaires et permissions
restent dans le module public ou privé qui consomme chaque secret.

```sh
init-project             # crée les fichiers absents et liste les champs externes
sops secrets/acme.json   # édite sans laisser de copie claire dans le dépôt
update-sops-keys         # met à jour les destinataires de tous les JSON
check-project            # refuse CHANGEME puis évalue Nix et Colmena
```

`init-project` ne remplace jamais un fichier existant. Commitez `.sops.yaml` et
les JSON re-chiffrés ensemble après tout changement de destinataires.

Guide complet :
https://github.com/theking90000/server-setup/blob/main/docs/SETUP-GUIDE.md
