# Écrire un module `server-setup`

Ce guide décrit le contrat complet d'un module public ou privé. Le principe
central est simple : **un service possède toute sa configuration dans son
module**. Le même fichier déclare son activation, ses secrets SOPS, son réseau,
ses ACL, son ingress, ses sauvegardes, ses métriques, ses dashboards et son SSO.

Les modules transversaux (`nginx`, `prometheus`, `grafana`, `restic`, `kanidm`)
ne connaissent pas chaque application. Ils agrègent les contributions que les
modules applicatifs publient dans les options `infra.*`.

## 1. Avant de créer un module

Un nouveau module est justifié si le service a sa propre responsabilité de
déploiement. Ne créez pas :

- un adaptateur séparé pour ses secrets ;
- un fichier par intégration (`myapp-grafana.nix`, `myapp-backup.nix`, etc.) ;
- une abstraction générique utilisée par un seul service ;
- un tag si l'activation est déjà naturellement exprimée par une liste de
  cibles, comme `infra.rcloneSync.mounts.<name>.targetNodes`.

Choisissez ensuite son emplacement :

| Emplacement | Usage |
|---|---|
| `nixos/modules/applications/` | Application réutilisable |
| `nixos/modules/monitoring/` | Collecte ou visualisation |
| `nixos/modules/network/` | Réseau, montage ou transport |
| `nixos/modules/security/` | Identité, certificats ou contrôle d'accès |
| `nixos/modules/backup/` | Mécanisme de sauvegarde |
| `<repo-prive>/modules/` | Service propre à une seule infrastructure |

Un module public est ajouté au `default.nix` de sa catégorie. Un module privé
est importé par le `flake.nix` privé. Les deux suivent exactement le même
contrat.

## 2. Le modèle de flotte

### 2.1 Tags

Le dépôt privé attribue les rôles dans `inventory/nodes.nix` :

```nix
vps1 = {
  publicIp = "203.0.113.10";
  vpnIp = "10.100.0.1";
  tags = [
    "web-server"
    "applications/myapp"
  ];
};
```

Chaque tag doit être enregistré par un module, même si aucun nœud ne l'utilise
encore :

```nix
{ infra.registeredTags = [ "applications/myapp" ]; }
```

`nodes.nix` refuse à l'évaluation tout tag inconnu. La convention est
`applications/<nom>` pour une application et un nom de rôle court pour une
fonction de flotte (`web-server`, `backup`, `grafana`, etc.).

### 2.2 Helpers injectés

Un module reçoit les helpers par `_module.args` :

```nix
{ config, lib, pkgs, services, ops, ... }:
```

| Helper | Résultat |
|---|---|
| `services.hasTag tag` | Le nœud courant possède le tag |
| `services.getHostsByTag tag` | Noms de tous les nœuds portant le tag |
| `services.getVpnIpsByTag tag` | IP WireGuard de ces nœuds |
| `services.getVpnIp` | IP WireGuard du nœud courant |
| `ops.mkSecretKeys` | Compatibilité historique pour `deployment.keys` |

Pour un nouveau module, SOPS est le chemin normal. `ops.mkSecretKeys` sert
uniquement à préserver les anciennes options texte et les tests existants.

### 2.3 Portée locale et effets inter-nœuds

Chaque nœud NixOS est évalué avec la topologie complète. Une déclaration faite
pendant l'évaluation d'un nœud peut donc alimenter un agrégateur installé sur un
autre nœud.

| Contribution | Garde correcte |
|---|---|
| Service, paquet, systemd, ACL, chemin de backup | `lib.mkIf enabled` |
| Télémétrie dérivée de `getHostsByTag` | Aucune garde ; une liste vide est neutre |
| Dashboard | Présence globale : `getHostsByTag tag != [ ]` |
| Ingress | URL configurée et backends VPN non vides |
| Client SSO | Présence globale de l'application et de Kanidm |

Erreur classique : entourer un dashboard avec `services.hasTag tag`. Grafana ne
le verra alors que si Grafana et l'application sont sur le même nœud.

## 3. Squelette recommandé

Ce squelette montre toutes les responsabilités possibles. Supprimez simplement
les blocs inutiles au service.

```nix
{
  config,
  lib,
  pkgs,
  services,
  ops,
  ...
}:

let
  cfg = config.infra.myapp;
  tag = "applications/myapp";
  enabled = services.hasTag tag;
  port = 8080;
  dataDir = "/var/lib/myapp";

  useSopsPassword =
    enabled && cfg.password == null && cfg.passwordFile == null;
  passwordPath =
    if cfg.passwordFile != null then cfg.passwordFile
    else if cfg.password != null then "/var/lib/secrets/myapp/password"
    else "/run/secrets/myapp/password";
in
{
  options.infra.myapp = {
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL publique de MyApp.";
    };

    password = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Compatibilité : mot de passe injecté par Colmena.";
    };

    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Compatibilité : chemin runtime du mot de passe.";
    };
  };

  config = lib.mkMerge [
    { infra.registeredTags = [ tag ]; }

    (lib.mkIf useSopsPassword {
      sops.secrets."myapp/password" = {
        sopsFile = config.infra.sops.secretsDirectory + "/myapp.json";
        key = "password";
      };
    })

    (lib.mkIf enabled {
      assertions = [{
        assertion = cfg.password == null || cfg.passwordFile == null;
        message = "Set at most one MyApp password source.";
      }];

      deployment.keys = ops.mkSecretKeys "myapp" {
        password = if cfg.passwordFile == null then cfg.password else null;
      } [ "password" ];

      systemd.services.myapp.serviceConfig.LoadCredential = [
        "password:${passwordPath}"
      ];

      services.myapp = {
        enable = true;
        listenAddress = services.getVpnIp;
        inherit port;
      };

      infra.security.acls = [{
        inherit port;
        allowedTags = [ "web-server" ];
        description = "MyApp";
      }];

      infra.backup.paths = [ dataDir ];
    })

    {
      infra.telemetry.myapp = map (host: {
        targets = [ "${host}:9091" ];
        labels = { inherit host; };
      }) (services.getHostsByTag tag);
    }

    (lib.mkIf (cfg.url != null && services.getVpnIpsByTag tag != [ ]) {
      infra.ingress.myapp = {
        url = cfg.url;
        backend = map (ip: "${ip}:${toString port}")
          (services.getVpnIpsByTag tag);
      };
    })

    (lib.mkIf (services.getHostsByTag tag != [ ]) {
      infra.grafana.dashboards = [ ./dashboards/myapp.json ];
    })
  ];
}
```

Le module est lisible de haut en bas : contrat, secrets, configuration locale,
puis contributions globales.

## 4. Réseau et exposition

### 4.1 VPN d'abord

Un service interne écoute sur `services.getVpnIp`. N'utilisez `0.0.0.0` que si
le logiciel ne permet pas mieux et protégez alors explicitement le port. Seul
le nœud `web-server` expose normalement HTTP/HTTPS à Internet.

Le chemin standard est :

```text
Internet -> Nginx public -> backend sur WireGuard -> application
```

### 4.2 ACL

Le module qui ouvre un port déclare aussi qui peut l'atteindre :

```nix
infra.security.acls = [{
  port = 8080;
  proto = "tcp";                 # défaut
  allowedTags = [ "web-server" ];
  allowedIps = [ ];              # exception manuelle seulement
  trustLocalRoot = true;         # défaut
  description = "MyApp HTTP";
}];
```

Les tags sont résolus en IP VPN. Le pare-feu accepte les sources indiquées puis
rejette explicitement les autres connexions sur ce port. Ajoutez aussi l'ACL du
port de métriques pour le tag `prometheus`.

### 4.3 Ingress

Une application publique contribue à `infra.ingress` :

```nix
infra.ingress.myapp = {
  url = cfg.url;                 # ex. https://app.example.com/path
  backend = [ "10.100.0.2:8080" ];
  blockPaths = [ "/metrics" ];
  backendTls = false;
  sslCertificate = null;
};
```

`url` est prioritaire sur `domain` + `path`. Nginx agrège les entrées par
domaine, répartit les backends et associe les certificats ACME. Ne configurez
pas directement le virtual host Nginx depuis le dépôt privé pour une
application standard.

### 4.4 ACME

Le module `acme.nix` possède l'émission et la synchronisation des certificats.
Un module consommateur ne manipule pas les credentials DNS. Il déclare un
ingress ; Nginx contribue les domaines requis et recharge les certificats.

Si un service non-Nginx consomme directement un certificat, ajoutez une entrée
`infra.acme.domains` avec son nom de service et son éventuel `postRun` dans le
module responsable.

## 5. Secrets SOPS

SOPS n'est pas optionnel dans une nouvelle infrastructure. Le module public
principal importe `sops-nix`, et le dépôt privé configure une seule racine :

```nix
infra.sops.secretsDirectory = ./secrets;
```

Le module du service déclare ensuite le fichier, la clé JSON et les permissions
runtime :

```nix
sops.secrets."myapp/api-key" = {
  sopsFile = config.infra.sops.secretsDirectory + "/myapp.json";
  key = "api_key";
  owner = "myapp";
  group = "myapp";
  mode = "0400";
};
```

Le dépôt privé contient uniquement :

```json
{"api_key":"valeur-chiffree-par-sops"}
```

Règles obligatoires :

- le câblage SOPS reste dans le module qui consomme le secret ;
- `config/` ne contient ni `sops.secrets`, ni chemin `/run/secrets`, ni valeur
  secrète ;
- aucun fichier clair n'est créé dans le dépôt ; utilisez `sops fichier.json` ;
- ne lisez jamais une valeur secrète avec `builtins.readFile` ;
- préférez `systemd` `LoadCredential` quand le service l'accepte ;
- renseignez `owner`, `group` et `mode` seulement selon le besoin réel ;
- n'ajoutez une option `password` ou `passwordFile` que pour une compatibilité
  existante ou un besoin de test concret.

`builtins.readFile` reste acceptable pour une **clé publique**, par exemple la
clé publique du cert-syncer.

Quand le service est utilisé sur plusieurs rôles, déclarez le secret sur chaque
nœud qui le consomme. Grafana en est l'exemple : le secret OIDC est nécessaire
sur le nœud Grafana et sur le nœud Kanidm qui provisionne le client.

## 6. Intégrations appartenant au module

### 6.1 Sauvegarde

Le module applicatif publie ses données persistantes :

```nix
infra.backup.paths = [ "/var/lib/myapp" ];
```

Ne sauvegardez pas les caches reproductibles. Vérifiez que le service écrit
réellement dans ce chemin, qu'une restauration est possible et si une pause ou
un dump cohérent est requis. Le module Restic agrège ensuite tous les chemins
sur les nœuds portant le tag `backup`.

### 6.2 Prometheus

Un module publie un job global :

```nix
infra.telemetry.myapp = map (host: {
  targets = [ "${host}:9091" ];
  labels = { inherit host; };
  scheme = "http";
  tls_config = null;
  basic_auth = null;
}) (services.getHostsByTag tag);
```

Les noms d'hôtes WireGuard sont utilisables dans les cibles. Protégez le port
avec une ACL autorisant `prometheus`. N'utilisez `basic_auth` que si le service
l'impose : cette option contient actuellement son mot de passe dans
l'évaluation Nix et ne convient pas à un nouveau secret sensible.

### 6.3 Grafana

Le dashboard JSON vit à côté du module :

```nix
lib.mkIf (services.getHostsByTag tag != [ ]) {
  infra.grafana.dashboards = [ ./dashboards/myapp.json ];
}
```

Le dashboard doit cibler le nom du job Prometheus stable, éviter les UID de
datasource propres à un environnement et rester utile sans modification
manuelle après déploiement.

### 6.4 SSO/Kanidm

Une application compatible OIDC enregistre elle-même son client :

```nix
infra.sso.myapp = {
  displayName = "MyApp";
  serviceTag = tag;
  redirectUris = [ "${cfg.url}/oauth/callback" ];
  landingUrl = cfg.url;
  secretFile = "/run/secrets/sso/myapp-client-secret";
  scopes = [ "openid" "profile" "email" ];
  pkce = true;
  groups.admins.claims.myapp_role = [ "Admin" ];
};
```

Le même module déclare le secret OIDC SOPS et configure son application pour
lire ce fichier. Kanidm agrège `infra.sso`, mais les comptes et appartenances
aux groupes restent administrés dans Kanidm. Voir
[`KANIDM-CLI.md`](KANIDM-CLI.md).

Avant d'ajouter un proxy d'authentification, vérifiez si l'application possède
un support OIDC natif. Le module reste responsable de l'intégration retenue.

## 7. Options privées et paquets

Le dépôt privé ne devrait définir que des choix compréhensibles sans connaître
SOPS ou systemd :

```nix
{
  infra.myapp = {
    url = "https://app.example.com";
    registrationEnabled = false;
  };
}
```

Pour un binaire non présent dans nixpkgs, ajoutez un paquet sous
`nixos/pkgs/<app>/` ou dans le dépôt privé, puis injectez-le par une option de
type `package`. Un binaire précompilé suit le modèle `fetchurl` +
`autoPatchelfHook` + `dontUnpack = true`. N'ajoutez pas un overlay si un simple
`pkgs.callPackage` suffit.

## 8. Modules sans tag

Un tag n'est pas une obligation technique. `rclone-sync.nix` active chaque
montage selon `targetNodes` :

```nix
infra.rcloneSync.mounts."backup-s3" = {
  mountPoint = "/mnt/backup";
  targetNodes = [ "vps1" ];
  remoteName = "s3-crypt";
};
```

Le module dérive les montages du nœud courant, déclare pour chacun la clé SOPS
dans `secrets/rclone-sync.json`, puis amorce une copie persistante et inscriptible
de `rclone.conf`. Cette exception est justifiée par la granularité naturelle
« montage -> nœuds », pas par une architecture différente.

## 9. Vérification

Avant de considérer le module terminé :

1. ajoutez-le au `default.nix` de sa catégorie ;
2. ajoutez un nœud synthétique ou étendez un check existant dans `flake.nix` ;
3. évaluez le chemin SOPS par défaut, pas uniquement les fallbacks texte ;
4. vérifiez le cas sans tag et le cas avec URL absente ;
5. lancez :

   ```sh
   nix flake check --all-systems
   ```

6. dans une infrastructure privée, lancez `check-project` ;
7. pour un changement risqué, faites d'abord `deploy-project <canari>`, vérifiez
   les unités et les endpoints, puis déployez la flotte.

Une évaluation Nix réussie ne prouve ni la connectivité réseau, ni la validité
d'un credential fournisseur, ni la santé d'un service après activation.

## 10. Checklist complète

### Responsabilité

- [ ] Le service mérite un module distinct.
- [ ] Toutes ses intégrations vivent dans ce même module.
- [ ] Le dépôt privé ne reçoit que des choix fonctionnels.
- [ ] Aucun adaptateur SOPS séparé n'est ajouté.

### Activation et topologie

- [ ] Le tag est nommé et enregistré, ou l'activation sans tag est justifiée.
- [ ] Le bloc local utilise `services.hasTag` ou les cibles du nœud courant.
- [ ] Les contributions inter-nœuds utilisent une garde globale.
- [ ] Les erreurs de configuration importantes ont une assertion lisible.

### Réseau

- [ ] Le service écoute sur l'IP VPN si possible.
- [ ] Chaque port a une ACL et seulement les rôles nécessaires sont autorisés.
- [ ] Le port de métriques est limité à `prometheus`.
- [ ] L'ingress utilise les IP VPN et n'expose pas `/metrics` ou une route admin
      inutilement.
- [ ] Les ports, protocoles et besoins IPv6 sont explicites.

### Secrets

- [ ] Chaque secret possède une déclaration SOPS dans le module.
- [ ] Le fichier JSON, la clé, le propriétaire et le mode sont exacts.
- [ ] Le service lit le secret au runtime, idéalement avec `LoadCredential`.
- [ ] Aucun secret n'entre dans `/nix/store`, les logs ou `config/`.
- [ ] Les fichiers et champs attendus sont connus par `init-project` si le
      module est public et standard.
- [ ] La rotation et le redémarrage nécessaire sont compris.

### Données et exploitation

- [ ] Les chemins persistants utiles contribuent à `infra.backup.paths`.
- [ ] La cohérence d'une restauration a été pensée.
- [ ] Les logs systemd permettent un diagnostic sans exposer de secret.
- [ ] Les mises à jour et migrations de schéma sont anticipées.
- [ ] Les ressources, permissions utilisateur et répertoires d'état sont
      minimaux.

### Observabilité

- [ ] Une cible `infra.telemetry` est publiée si des métriques existent.
- [ ] Les labels et le nom de job sont stables.
- [ ] Un dashboard utile est colocalisé et enregistré globalement.
- [ ] Les alertes réellement actionnables sont prévues au bon endroit.

### SSO et accès

- [ ] Le support OIDC natif a été évalué avant tout proxy.
- [ ] Le client, ses redirect URI, scopes, PKCE, groupes et claims sont
      déclarés par l'application.
- [ ] L'application et Kanidm voient le même secret client au runtime.
- [ ] Le comportement sans Kanidm est explicite.

### Validation

- [ ] Le module est importé et couvert par une évaluation synthétique.
- [ ] `nix flake check --all-systems` réussit.
- [ ] `check-project` réussit dans le dépôt privé.
- [ ] Un déploiement canari vérifie service, ACL, ingress, métriques, dashboard,
      backup et SSO selon ce qui s'applique.

Si une case ne s'applique pas, elle doit pouvoir être écartée en une phrase.
Cette checklist sert à révéler les responsabilités oubliées, pas à fabriquer du
code vide.
