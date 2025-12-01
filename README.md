# Server Setup

Ce dépot contient des scripts et des configurations pour automatiser la mise en place et la gestion de serveurs.

## Infecter les serveurs avec NixOS

Setup testé : OVH VPS sous Debian 11.
Clé ssh installée dans l'utilisateur debian. (/home/debian/.ssh/authorized_keys)

Infection via Ansible : (changer inventory.ini avec l'IP du serveur cible)

```
cd infection && ansible-playbook -i  inventory.ini infra/infect.yml
```

## Configuer les serveurs

Configurer group_vars/all.yml et inventory.ini

```
# group_vars/all.yml
admin_keys:
  - "ssh-ed25519 AAA"

ansible_keys:
  - "ssh-ed25519 AAA"
```

```
cd setup && ansible-playbook -i inventory.ini infra/setup.yml
```

## Appliquer les configs NixOS

Aller dans `config`

configurer `inventory.ini`

```
[vps_ovh]
vps1 ansible_host=X.X.X.X vpn_ip=10.100.0.1
```

Générer les clés wireguard en local

```
ansible-playbook -i inventory.ini wireguard-keygen.yml
```

Uploader et regénérer les configs

```
ansible-playbook -i inventory.ini config.yml
```
