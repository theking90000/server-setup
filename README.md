# Server Setup

Ce dépot contient des scripts et des configurations pour automatiser la mise en place et la gestion de serveurs.

## Infecter les serveurs avec NixOS

Setup testé : OVH VPS sous Debian 11.
Clé ssh installée dans l'utilisateur debian. (/home/debian/.ssh/authorized_keys)

Infection via Ansible : (changer inventory.ini avec l'IP du serveur cible)

```
cd infra && ansible-playbook -i  inventory.ini infra/infect.yml
```
