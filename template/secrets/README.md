# Secrets du projet

Ce dossier ne contient que les fichiers JSON chiffrés. Le câblage standard
SOPS vers les options `infra.*File` est fourni par `infra.nixosModules.sops`.

```sh
init-project                 # crée les fichiers manquants et affiche les champs à remplir
sops secrets/acme.json       # édite un fichier sans produire de copie claire
update-sops-keys             # resynchronise les destinataires après un changement de nœud
check-project                # vérifie les secrets et la configuration
```

`init-project` ne remplace jamais un fichier existant. Les credentials externes
restent à `CHANGEME` dans les fichiers chiffrés jusqu'à leur saisie. Les secrets
aléatoires et les clés locales sont générés automatiquement.

Les secrets propres à un module privé restent déclarés par ce module privé.
