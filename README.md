# Server Setup

Ce dépot contient des scripts et des configurations pour automatiser la mise en place et la gestion de serveurs.

Chaque serveur est une installation d'un VPS OVH sous Debian 11, la clé SSH est installée dans l'utilisateur debian.

## 1. Configurer l'inventaire

Configurer `inventory/group_vars` et `inventory/hosts.ini` avec les informations des serveurs.

```
# inventory/hosts.ini
[vps]
vps1 ansible_host=51.X.X.X ansible_user=root hostname=vps-ddXXXXXX vpn_ip=10.0.0.1
```

```
# inventory/group_vars/all.yml
admin_keys:
  - "ssh-ed25519 AAAA"
ansible_keys:
  - "ssh-ed25519 AAAA"
```

## 2. Infecter les serveurs avec NixOS

```sh
ansible-playbook playbooks/00-infect.yml
```

## 3. Configurer NixOS (bootstrap)

```sh
ansible-playbook playbooks/10-bootstrap.yml
```

Générer des clés Wireguard pour chaque serveur.

```sh
ansible-playbook playbooks/11-wireguard-keygen.yml
```

## 4. Appliquer les configurations NixOS !

Configurer les secrets serveurs dans `inventory/host_vars/<hostname>/secrets.yml`.

```yaml
server_secrets:
  grafana-admin-password: "votre_mot_de_passe_securise"

  restic-password: "votre_mot_de_passe_securise"
  restic-repo-url: "s3:s3.amazonaws.com/mon-bucket-restic/mon-repo"
  restic-s3-env: |
    AWS_ACCESS_KEY_ID="votre_access_key_id"
    AWS_SECRET_ACCESS_KEY="votre_secret_access_key"
    AWS_DEFAULT_REGION="us-east-1"
```

Le contenu du dossier `nixos/modules` sera appliqué aux serveurs.
Le fichier `loader.nix` est le point d'entrée de la configuration NixOS. Le VPN Wireguard est automatiquement configuré entre les serveurs.

```sh
ansible-playbook playbooks/02-deploy.yml
```
