# Administrer Kanidm en CLI

Ce guide couvre Kanidm 1.10 et l'intégration de ce dépôt. `kanidm` sert aux
opérations courantes via l'API HTTPS. `kanidmd` agit directement sur la base du
serveur et reste réservé à la récupération et à la maintenance hors ligne.

## Ce que gère Nix, et ce que gère Kanidm

| Élément | Responsable |
|---|---|
| Serveur, URL et sauvegardes | NixOS |
| Clients OAuth2, callbacks et claims | Modules applicatifs via `infra.sso.<name>` |
| Noms des groupes applicatifs | NixOS |
| Personnes et credentials | CLI ou interface Kanidm |
| Appartenance aux groupes | CLI ou interface Kanidm |

Les groupes applicatifs sont créés avec `overwriteMembers = false`. Un
redéploiement conserve donc les membres ajoutés en CLI. En revanche, ne
modifiez pas manuellement un client de `kanidm system oauth2` : sa définition
est déclarative et le prochain déploiement peut rétablir la valeur Nix.

## Installer et configurer le client

Avec Nix, ouvrez un shell contenant la même version majeure que le serveur :

```sh
nix shell nixpkgs#kanidm_1_10
```

Créez `~/.config/kanidm` sur le poste administrateur :

```toml
uri = "https://auth.example.com"
```

Utilisez l'URL HTTPS publique déclarée dans `infra.kanidm.url`. Son certificat
étant valide, n'ajoutez ni `verify_ca = false` ni `--accept-invalid-certs`.
Pour une commande ponctuelle, `-H https://auth.example.com` remplace le fichier.

## Se connecter

`idm_admin` est le compte de secours initial pour les personnes et groupes :

```sh
kanidm login -D idm_admin
kanidm self whoami -D idm_admin
```

Dans le dépôt privé, son mot de passe stable est stocké dans
`secrets/kanidm.json`. Pour le consulter sans le placer dans l'historique du
shell :

```sh
sops decrypt --extract '["idm_admin_password"]' secrets/kanidm.json
```

Une opération d'écriture peut demander une nouvelle authentification, comme
`sudo` le ferait :

```sh
kanidm reauth -D idm_admin
```

Les sessions sont locales au poste :

```sh
kanidm session list
kanidm session cleanup
kanidm logout -D idm_admin
```

N'utilisez pas `idm_admin` au quotidien. Créez un compte nominatif et ne lui
accordez que les rôles administratifs nécessaires.

## Créer et initialiser une personne

Une personne nouvellement créée ne possède aucun credential :

```sh
kanidm person create alice "Alice Example" -D idm_admin
kanidm person update alice \
  --legalname "Alice Example" \
  --mail "alice@example.com" \
  -D idm_admin
kanidm person get alice -D idm_admin
```

Générez ensuite un lien d'enrôlement valable une heure :

```sh
kanidm person credential create-reset-token alice --ttl 3600 -D idm_admin
```

Transmettez le lien ou le QR code directement à la personne. Le token est à
usage unique. La personne choisit alors elle-même son mot de passe, son TOTP ou
ses passkeys.

Pour une réinitialisation assistée, répétez la commande. L'édition directe des
credentials reste possible, mais doit rester exceptionnelle :

```sh
kanidm person credential status alice -D idm_admin
kanidm person credential update alice -D idm_admin
```

## Lister les groupes et les permissions disponibles

Commencez toujours par interroger le serveur :

```sh
kanidm group list -D idm_admin
kanidm group search grafana -D idm_admin
kanidm group get grafana_admins -D idm_admin
kanidm group list-members grafana_admins -D idm_admin
```

Pour un traitement automatisé :

```sh
kanidm -o json group list -D idm_admin
```

Les principaux rôles Kanidm utiles à l'exploitation sont :

| Groupe | Permission |
|---|---|
| `idm_people_admins` | Créer et administrer les personnes |
| `idm_group_admins` | Créer et administrer les groupes |
| `idm_service_desk` | Aider aux resets et problèmes de comptes |
| `idm_recycle_bin_admins` | Consulter et restaurer la corbeille |
| `idm_oauth2_admins` | Administrer les intégrations OAuth2 |
| `idm_admins` | Rôle large de gestion des personnes et groupes |

Préférez les rôles ciblés à `idm_admins`. La liste exacte et les descriptions
du serveur restent la source de vérité : inspectez chaque groupe avec
`kanidm group get` avant de l'accorder.

Par exemple, pour déléguer la gestion des personnes, groupes et restaurations
à `alice` sans lui donner l'administration complète du domaine :

```sh
kanidm group add-members idm_people_admins alice -D idm_admin
kanidm group add-members idm_group_admins alice -D idm_admin
kanidm group add-members idm_recycle_bin_admins alice -D idm_admin
```

`alice` doit ensuite se reconnecter, ou exécuter `kanidm reauth -D alice`, pour
obtenir une session privilégiée à jour. Le rôle `idm_oauth2_admins` n'est pas
nécessaire pour les clients produits par `infra.sso`, puisque Nix les gère.

## Donner accès aux applications

L'intégration Grafana crée automatiquement :

| Groupe | Niveau Grafana |
|---|---|
| `grafana_viewers` | Viewer |
| `grafana_editors` | Editor |
| `grafana_admins` | Admin de l'organisation Grafana |

Ajoutez une personne à un seul niveau Grafana :

```sh
kanidm group add-members grafana_viewers alice -D idm_admin
kanidm group list-members grafana_viewers -D idm_admin
```

Pour changer son niveau, retirez d'abord l'ancien groupe :

```sh
kanidm group remove-members grafana_viewers alice -D idm_admin
kanidm group add-members grafana_editors alice -D idm_admin
```

La révocation suit le même principe :

```sh
kanidm group remove-members grafana_editors alice -D idm_admin
```

Les futures applications suivront la convention `<client>_<rôle>`. Utilisez
`kanidm group search <client>` pour découvrir les rôles réellement disponibles.

## Bloquer ou supprimer un compte

Pour bloquer immédiatement les nouvelles authentifications sans supprimer la
personne :

```sh
kanidm person validity expire-at alice now -D idm_admin
```

Pour la réactiver :

```sh
kanidm person validity expire-at alice clear -D idm_admin
```

La suppression envoie la personne dans la corbeille :

```sh
kanidm person delete alice -D idm_admin
kanidm recycle-bin list -D idm_admin
```

Pour restaurer une entrée, utilisez son UUID affiché par la corbeille :

```sh
kanidm recycle-bin get <uuid> -D idm_admin
kanidm recycle-bin revive <uuid> -D idm_admin
kanidm person get alice -D idm_admin
```

La corbeille est une récupération de courte durée et en best effort. Après une
restauration, vérifiez les groupes et réajoutez les appartenances manquantes.

## Vérifier l'intégration OAuth2 Grafana

Les commandes suivantes sont en lecture seule :

```sh
kanidm system oauth2 list -D idm_admin
kanidm system oauth2 get grafana -D idm_admin
curl -fsS https://auth.example.com/oauth2/openid/grafana/.well-known/openid-configuration
```

Kanidm demande normalement un consentement lors du premier accès et lorsque
les scopes demandés changent. Pour cette application interne déjà approuvée par
l'administrateur, désactivez ce consentement après le premier déploiement :

```sh
kanidm system oauth2 disable-consent-prompt grafana -D idm_admin
```

Le provisioner Kanidm actuel ne sait pas encore déclarer ce réglage. La commande
est donc à exécuter une seule fois ; sa valeur est conservée dans la base Kanidm
et dans ses sauvegardes.

Cette commande est la seule modification manuelle prévue sur le client Grafana.
Ne lancez pas `reset-basic-secret`, `delete`, `set-name` ou une modification de
scope : Nix reste propriétaire de sa définition.

## Récupération avec `kanidmd`

`kanidmd` ouvre directement la base. Exécutez-le uniquement sur le nœud Kanidm,
avec le service arrêté et le même paquet que celui du système actif.

Le module NixOS génère `server.toml` dans le store. Retrouvez son chemin après
`-c` dans l'unité :

```sh
sudo systemctl cat kanidm.service
```

Puis remplacez `<server.toml>` par ce chemin exact :

```sh
sudo systemctl stop kanidm.service
sudo -u kanidm kanidmd recover-account -c <server.toml> admin
sudo systemctl start kanidm.service
```

Cette commande produit un nouveau mot de passe : traitez-le immédiatement comme
un secret. Pour `idm_admin`, le fichier SOPS est la source de vérité et le
provisioner réapplique sa valeur au démarrage. Consultez ce fichier ou
modifiez-le puis redéployez ; un `kanidmd recover-account idm_admin` isolé serait
écrasé au redémarrage.

## Sauvegarde et restauration complète

Le serveur produit des sauvegardes en ligne dans
`/var/lib/kanidm/backups`. Le module Restic sauvegarde également
`/var/lib/kanidm`. Vérifiez régulièrement leur présence :

```sh
sudo systemctl status kanidm.service
sudo journalctl -u kanidm.service --since today
sudo ls -lah /var/lib/kanidm/backups
```

Une restauration complète est une opération destructive. Utilisez exactement
la même version de Kanidm que celle ayant produit la sauvegarde, arrêtez le
service et conservez une copie de l'état actuel avant de lancer :

```sh
sudo systemctl stop kanidm.service
sudo -u kanidm kanidmd database restore -c <server.toml> <backup>
sudo systemctl start kanidm.service
```

Après restauration, vérifiez les personnes, groupes et clients OAuth2 avant de
rouvrir les accès applicatifs.

## Sources officielles

- [Comptes et groupes](https://kanidm.github.io/kanidm/master/accounts/intro.html)
- [Personnes](https://kanidm.github.io/kanidm/master/accounts/people_accounts.html)
- [Credentials et reset](https://kanidm.github.io/kanidm/master/accounts/authentication_and_credentials.html)
- [Contrôle d'accès et rôles](https://kanidm.github.io/kanidm/master/access_control/intro.html)
- [Corbeille](https://kanidm.github.io/kanidm/master/recycle_bin.html)
- [Sauvegarde et restauration](https://kanidm.github.io/kanidm/master/backup_and_restore.html)
