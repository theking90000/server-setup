# Bascule ACME : du cert-syncer à l'émission locale

Procédure manuelle de migration d'un déploiement existant vers le modèle
issuers + claims (émission locale native, suppression du cert-syncer).
La bascule est un big-bang assumé : un peu d'indisponibilité TLS est
possible entre le déploiement d'un nœud et sa première émission réelle
(le bootstrap autosigné de NixOS sert entre-temps).

Les nouveaux groupes de certificats vivent dans
`/var/lib/acme/<émetteur>-<scope>-<couverture>` : ces noms ne contiennent
jamais de point, ils sont donc disjoints des anciens répertoires
`/var/lib/acme/<domaine>` alimentés par le syncer. Rien n'est écrasé, le
retour arrière reste possible pendant toute la procédure.

## 1. Pré-vérifications (sans déploiement)

1. Dépôt public : `nix flake check --all-systems`.
2. Dépôt privé : mettre à jour l'input `infra`, migrer
   `config/acme/acme.nix` vers `infra.acme.issuers`, retirer le tag
   `acme-issuer` de l'inventaire et `certSyncerPublicKeyFile` du flake.
3. `sops secrets/acme.json` : envelopper les credentials DNS existants
   dans la nouvelle forme :

   ```json
   { "issuers": { "primary": { "dnsCredentials": "OVH_ENDPOINT=…" } } }
   ```

4. `check-project` puis `colmena build` : les trois évaluations doivent
   passer. Inspecter le plan par nœud :

   ```sh
   colmena eval -E '{ nodes, ... }: nodes.vps1.config.infra.acme.plan'
   ```

   Attendu pour un domaine plat : un groupe wildcard
   `primary-nginx-wildcard-<domaine>` par frontend, plus un groupe exact
   `primary-kanidm-exact-<auth-domaine>` sur le nœud kanidm, rien sur les
   nœuds sans claim.
5. Supprimer du dépôt privé `secrets/acme-syncer.json` et
   `inventory/keys/syncer.key{,.pub}`.

## 2. Bascule nœud par nœud

Déployer un frontend à la fois : cela sérialise aussi les premières
émissions ACME (mêmes SAN commandés par les deux frontends — la limite
« duplicate certificate » de Let's Encrypt est de 5/semaine).

### Premier frontend

```sh
colmena apply --on vps1
ssh vps1 systemctl --failed
ssh vps1 journalctl -u 'acme-*' -f
```

Attendre le timer ou déclencher l'émission immédiatement :

```sh
ssh vps1 systemctl start acme-order-renew-<groupe-wildcard>.service
ssh vps1 ls -l /var/lib/acme/<groupe-wildcard>/
```

Vérifier depuis l'extérieur que le certificat servi est bien émis par
Let's Encrypt (et non l'autosigné de bootstrap), avec les bons SAN :

```sh
openssl s_client -connect <ip-vps1>:443 -servername git.<domaine> </dev/null \
  | openssl x509 -noout -issuer -dates -ext subjectAltName
```

Répéter avec `-servername <domaine>` (apex) et vérifier la délégation
Matrix le cas échéant : `curl https://<domaine>/.well-known/matrix/server`.

### Second frontend

Même séquence sur vps2, plus le certificat exact de Kanidm :

```sh
ssh vps2 systemctl start acme-order-renew-<groupe-kanidm>.service
ssh vps2 systemctl show -p ActiveEnterTimestamp kanidm   # restart post-émission
openssl s_client -connect <vpn-ip-vps2>:8443 </dev/null \
  | openssl x509 -noout -issuer -ext subjectAltName       # cert exact, clé propre
```

Tester une connexion SSO de bout en bout.

### Nœuds restants

```sh
colmena apply --on rpi1
```

Aucun certificat attendu sur un nœud sans claim ; le déploiement retire
ses unités de synchronisation.

## 3. Vérification du démantèlement

Sur chaque nœud :

```sh
systemctl list-units 'sync-cert*'    # vide
id cert-syncer                       # « no such user »
grep -c cert-syncer /etc/ssh/sshd_config  # 0
```

## 4. Retour arrière

Tant que le nettoyage final n'est pas fait : `git revert` du commit de
migration du dépôt privé (et re-pin de l'ancien input `infra`), puis
redéploiement. Les anciens répertoires `/var/lib/acme/<domaine>` et les
anciens secrets restent récupérables dans l'historique git.

## 5. Nettoyage final (plus tard, manuel uniquement)

Après au moins un cycle de renouvellement réussi (~60 jours), supprimer à
la main les anciens répertoires à points sur chaque nœud :

```sh
rm -rf /var/lib/acme/<domaine> /var/lib/acme/auth.<domaine> …
```

Jamais pendant une activation NixOS.
