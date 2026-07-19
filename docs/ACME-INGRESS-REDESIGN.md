# Refonte ACME et ingress

Statut : **implémenté** (rewrite complet, sans couche de compatibilité).
Ce document reste la référence de conception ; la procédure de bascule de
production est décrite dans [ACME-CUTOVER.md](ACME-CUTOVER.md).

Écarts entre cette proposition et l'implémentation, vérifiés contre le
module `security.acme` de NixOS 26.05 :

- il n'existe pas de target `acme-finished-<nom>` : l'unité de référence
  des consommateurs est `acme-<nom>.service` (bootstrap autosigné,
  `RemainAfterExit`), le renouvellement réel étant
  `acme-order-renew-<nom>.service` ;
- `cert.pem` est un symlink vers `fullchain.pem` après émission réelle ;
  `fullchain` est le champ canonique de l'API ;
- le bootstrap autosigné est toujours actif (`preliminarySelfsigned` a
  été supprimé en amont) ;
- les claims distinguent `reloadServices` (rechargement natif) de
  `restartServices` (postRun `try-restart`) : les consommateurs
  `LoadCredential` ne relisent leurs credentials qu'au redémarrage ;
- seule la stratégie `coverage` est implémentée (question 1 tranchée) ;
  `issuer` reste hors périmètre ;
- les ingress sont HTTPS uniquement (question 5 tranchée) ;
- l'apex rejoint le wildcard de premier niveau de son groupe
  (question 3 tranchée) ;
- deux entrées ingress peuvent partager un hôte avec des routes
  distinctes ; seuls les doublons hôte + chemin + mode sont rejetés.

## 1. Résumé de la proposition

Le modèle actuel centralise l'émission des certificats sur un nœud, puis les
copie par SSH et rsync vers les consommateurs. Il fonctionne, mais ajoute un
second système de distribution, de démarrage et de rechargement au-dessus du
module ACME natif de NixOS. Une indisponibilité du certificat peut alors faire
échouer l'activation de services sans rapport direct avec son renouvellement.

La cible proposée est plus locale et déclarative :

1. chaque service déclare seulement les noms DNS qu'il consomme ;
2. chaque ingress HTTPS produit automatiquement la même déclaration ;
3. un résolveur pur choisit l'émetteur ACME et le groupe de certificat ;
4. chaque nœud émet uniquement les groupes dont il a besoin ;
5. les consommateurs reçoivent des chemins calculés et stables ;
6. NixOS gère l'émission, le bootstrap, le renouvellement et les rechargements ;
7. `cert-syncer`, son tag, ses clés SSH et ses unités disparaissent.

Les certificats ne deviennent donc pas des objets à déclarer manuellement. Ils
restent un résultat dérivé des intentions des services et des politiques ACME.

```text
intentions des services ─┐
                         ├─> claims ─> résolution ─> groupes ACME locaux
intentions des ingress ──┘                    │              │
                                              │              └─> security.acme.certs
                                              ├─> chemins calculés des certificats
                                              └─> configuration Nginx calculée
```

## 2. Problèmes du modèle actuel

### 2.1 Certificats

`nixos/modules/security/acme.nix` remplit actuellement plusieurs rôles :

- sélection d'un nœud `acme-issuer` ;
- émission ACME avec `security.acme` ;
- exposition en lecture par `rrsync` ;
- synchronisation par SSH sur les autres nœuds ;
- génération de certificats temporaires avec `minica` ;
- orchestration des dépendances et rechargements systemd.

Cette combinaison crée plusieurs états partiellement indépendants : certificat
valide chez l'émetteur, copie locale, clé SSH, timer de synchronisation, droits
Unix et ordre d'activation. Elle élargit aussi le rayon d'impact : une erreur de
copie ou un certificat absent peut casser l'activation de Nginx, Kanidm ou d'un
autre consommateur.

### 2.2 Ingress

L'API actuelle accepte `url` ou `domain + path`, un backend, quelques options
génériques et une chaîne Nginx libre. Le compilateur :

- accepte une URL HTTP, mais active toujours `forceSSL` ;
- reconstruit manuellement les chemins dans `/var/lib/acme` ;
- active implicitement ACME pour chaque domaine ;
- force `proxyWebsockets = true` pour tous les services ;
- mélange le chemin public, le proxy, les blocages métier et des détails Nginx ;
- ne possède pas de modèle explicite pour les hôtes wildcard ou les préfixes de
  chemin composables.

L'implicite « une URL HTTPS produit un ingress et son certificat » est utile et
doit rester. En revanche, le certificat exact et les réglages Nginx ne doivent
pas être devinés par des heuristiques cachées.

## 3. Principes et invariants

La refonte doit respecter les invariants suivants :

- un module métier exprime un endpoint public, pas un certificat concret ;
- le dépôt de déploiement privé choisit les comptes et fournisseurs ACME, mais
  ne déclare ni chemins de secrets, ni unités systemd, ni détails SOPS ;
- le même nom DNS ne peut être routé que vers un seul émetteur ;
- la résolution est déterministe et vérifiable pendant l'évaluation Nix ;
- un consommateur peut lire le résultat de son claim sans connaître les autres
  claims ni `/var/lib/acme` ;
- l'ajout d'un service ne renomme pas les certificats existants ;
- la perte temporaire de DNS ou d'ACME ne remplace pas un certificat valide et
  ne bloque pas les services déjà actifs ;
- les frontends redondants ont le même plan logique, mais un état ACME local et
  indépendant ;
- une abstraction stable couvre les concepts d'infra ; les détails avancés
  restent des fragments du module Nginx natif ;
- les ambiguïtés et conflits échouent à l'évaluation, avant un déploiement.

## 4. Routage vers les émetteurs ACME

### 4.1 Configuration proposée

Le dépôt privé configure des politiques d'émission, et non des certificats :

```nix
infra.acme.issuers = {
  primary = {
    match = {
      suffixes = [ "app.example.com" ];
      hosts = [ ];
    };

    email = "admin@example.com";
    dnsProvider = "ovh";
    server = null; # serveur ACME par défaut de NixOS
    keyType = "ec256";
    profile = "classic";
    packing = "coverage";
  };

  secondary = {
    match = {
      suffixes = [ "other.example.net" ];
      hosts = [ "special.example.org" ];
    };

    email = "infra@example.net";
    dnsProvider = "cloudflare";
    packing = "issuer";
  };
};
```

Un suffixe `app.example.com` couvre l'apex et tous ses descendants :

- `app.example.com` ;
- `git.app.example.com` ;
- `bucket.s3.app.example.com` ;
- toute autre profondeur.

Ce vocabulaire est volontairement différent de `*.app.example.com`. Un
sélecteur décrit un sous-arbre DNS ; un wildcard X.509 ne couvre qu'un seul
label. Accepter `*.app.example.com` comme alias de migration est envisageable,
mais la forme canonique doit rester `suffixes = [ "app.example.com" ]`.

### 4.2 Règles de résolution

Pour chaque nom demandé :

1. une correspondance exacte de `hosts` est prioritaire ;
2. sinon le suffixe correspondant le plus long est choisi ;
3. deux correspondances de même priorité sont une erreur ;
4. l'absence de correspondance est une erreur ;
5. les noms d'un même claim doivent tous résoudre vers le même émetteur.

Le résolveur doit être une fonction pure, probablement dans
`nixos/lib/acme.nix`, injectée comme `acme` dans `_module.args`. Il dépend
uniquement des politiques et du claim en entrée. Il ne lit jamais la
configuration finale de `security.acme.certs`, afin d'éviter les récursions de
modules.

### 4.3 Comptes et secrets

Chaque émetteur définit l'adresse ACME, l'email, le type de clé, le profil et
les credentials DNS à employer. La déclaration SOPS et le chemin d'exécution
restent dans le module public. Une organisation possible est :

```text
secrets/acme.json
└── issuers
    ├── primary
    │   └── dnsCredentials
    └── secondary
        └── dnsCredentials
```

Seuls les secrets des émetteurs réellement utilisés sur le nœud doivent être
déchiffrés. Le simple nom logique d'un émetteur ou un jeu de credentials
différent ne garantit pas à lui seul un compte ACME distinct : avec le module
NixOS et Lego, l'identité du compte dépend notamment du serveur, de l'email et
du type de clé. Cette propriété doit être testée et documentée, sans inventer
une séparation que le client ACME ne fournit pas.

## 5. Claims réutilisables

### 5.1 Intention déclarée par un service

Un service qui consomme directement un certificat déclare un claim :

```nix
infra.acme.claims.kanidm = {
  names = [ "auth.app.example.com" ];

  consumer = {
    kind = "service";
    scope = "kanidm";
  };

  reloadServices = [ "kanidm.service" ];
};
```

Un ingress HTTPS génère son claim automatiquement. Le module applicatif ne
doit pas répéter le domaine dans `infra.acme`.

Les claims sont matérialisés localement : un claim ingress n'existe que sur un
nœud `web-server`, et un claim de service direct seulement sur le nœud qui
active ce service. Une contribution métier peut rester calculée depuis la
topologie complète, mais elle ne doit pas provoquer l'émission du certificat
sur un nœud qui ne le consomme pas.

`consumer.scope` fait partie de la clé de regroupement. Il évite qu'une clé
privée destinée à Nginx soit partagée par défaut avec Kanidm, une base de
données ou un autre service. Valeurs recommandées :

- ingress : `kind = "ingress"`, `scope = "nginx"` ;
- service direct : `kind = "service"`, scope propre au service ;
- partage explicite : même scope choisi consciemment par les consommateurs.

### 5.2 Résultat calculé

Le module ACME complète chaque claim avec une option en lecture seule :

```nix
config.infra.acme.claims.kanidm.certificate = {
  name = "acme-primary-service-kanidm-auth-app-example-com";
  directory = "/var/lib/acme/acme-primary-service-kanidm-auth-app-example-com";
  certificate = "/var/lib/acme/acme-primary-service-kanidm-auth-app-example-com/cert.pem";
  fullchain = "/var/lib/acme/acme-primary-service-kanidm-auth-app-example-com/fullchain.pem";
  chain = "/var/lib/acme/acme-primary-service-kanidm-auth-app-example-com/chain.pem";
  key = "/var/lib/acme/acme-primary-service-kanidm-auth-app-example-com/key.pem";
  combined = "/var/lib/acme/acme-primary-service-kanidm-auth-app-example-com/full.pem";
  unit = "acme-acme-primary-service-kanidm-auth-app-example-com.service";
};
```

Les noms exacts restent à valider contre les sorties du module NixOS 26.05,
mais l'API doit utiliser des termes non ambigus : `fullchain`, `chain` et `key`
plutôt que `certPublic` et `certPrivate`.

Un consommateur peut alors utiliser le résultat paresseusement :

```nix
let
  cert = config.infra.acme.claims.kanidm.certificate;
in
{
  systemd.services.kanidm.serviceConfig.LoadCredential = [
    "tls_chain:${cert.fullchain}"
    "tls_key:${cert.key}"
  ];
}
```

Il n'est pas nécessaire d'exposer une API publique `acme.resolve { ... }` aux
modules applicatifs. Une option calculée est plus simple à consommer et reste
inspectable dans la configuration évaluée.

### 5.3 Ordre d'évaluation

Pour éviter une boucle de points fixes, l'implémentation suit strictement ces
couches :

1. configuration des émetteurs ;
2. fonctions pures de résolution ;
3. claims et résultats calculés en lecture seule ;
4. regroupement des claims par `certificate.name` ;
5. génération de `security.acme.certs` et des consommateurs.

Une option en lecture seule `infra.acme.plan` peut exposer le plan final pour
les tests et le diagnostic. Les services ne doivent pas la consommer.

## 6. Wildcards X.509 et regroupement

### 6.1 Ne pas confondre DNS, Nginx et X.509

Les trois niveaux n'ont pas la même sémantique :

| Entrée | Sémantique |
|---|---|
| sélecteur `suffixes = [ "app.example.com" ]` | apex et descendants à toute profondeur |
| certificat `*.app.example.com` | exactement un label avant `app.example.com` |
| `server_name *.app.example.com` de Nginx | peut aussi accepter plusieurs labels |

Le compilateur doit rendre ces différences explicites. Il ne doit jamais
supposer qu'un wildcard X.509 couvre un sous-arbre DNS entier.

### 6.2 Identifiants nécessaires

En mode de couverture automatique :

| Claim | Identifiant X.509 possible |
|---|---|
| `app.example.com` | `app.example.com` |
| `git.app.example.com` | `*.app.example.com` |
| `bucket.s3.app.example.com` | `*.s3.app.example.com` |
| ingress explicite `*.s3.app.example.com` | `*.s3.app.example.com` |

Un même certificat SAN peut techniquement contenir
`app.example.com`, `*.app.example.com` et `*.s3.app.example.com`. La question
n'est donc pas la validité X.509, mais le rayon d'impact et la stabilité.

Les services directs utilisent un nom exact par défaut. Ils ne sont pas
promus automatiquement vers un wildcard large, même si un ingress possède ce
wildcard. Un partage exige le même scope explicite.

### 6.3 Stratégies de regroupement

Le regroupement est une politique de l'émetteur, pas une déclaration de
certificat :

- `packing = "coverage"` — valeur proposée par défaut. Un groupe stable par
  niveau de couverture X.509 et par scope. L'apex peut être associé au wildcard
  de son niveau. Le rayon d'impact reste limité ;
- `packing = "issuer"` — un groupe par émetteur et scope contenant tous les
  identifiants nécessaires. Il réduit le nombre de certificats, mais un nom
  invalide peut bloquer tout le renouvellement du groupe et la clé a un rayon
  d'usage plus large.

Il ne faut pas implémenter de bin-packing ou de sharding automatique. Lorsqu'un
groupe dépasse la limite du profil ACME, l'évaluation doit échouer et demander
de passer à `coverage` ou de séparer la politique. Les limites ne doivent pas
être codées comme une constante universelle : elles dépendent du serveur et du
profil ACME.

Les noms de groupes doivent être calculés à partir de l'émetteur, du scope et
de la couverture, jamais de leur position dans une liste. Ajouter un claim ne
doit pas renommer un certificat déjà déployé.

### 6.4 Limites de sécurité

Un wildcard large couvre cryptographiquement tous les noms de son niveau,
même si les services sensibles sont configurés avec un certificat exact. Pour
une isolation réelle, il faut aussi séparer les zones DNS, par exemple :

```text
*.apps.example.com     ingress applicatifs
auth.example.com       identité
db.example.com         base de données
```

Le regroupement réduit la pression sur les limites ACME, mais ne doit pas
transformer une optimisation opérationnelle en partage implicite de clés.

## 7. Nouvelle API ingress

### 7.1 Forme simple

Le cas courant reste court :

```nix
infra.ingress.gitea = {
  url = cfg.url;
  proxyTo = "http://10.100.0.2:3000";
};
```

La normalisation produit un endpoint, une route `/` et, si l'URL est HTTPS, un
claim ACME de scope `nginx`. Le schéma de l'URL est effectif :

- `https://` active TLS, le claim et la redirection HTTP vers HTTPS ;
- `http://` ne crée pas de claim et ne force pas TLS.

Le schéma du backend appartient à `proxyTo`. Il remplace `backendTls` et évite
une combinaison incohérente entre une adresse et un booléen séparé.

### 7.2 Forme avancée

```nix
infra.ingress.myapp = {
  endpoint = {
    scheme = "https";
    host = "app.example.com";
    basePath = "/prefix";
  };

  routes = {
    main = {
      path = "/";
      match = "prefix";
      nginx.proxyPass = "http://127.0.0.1:3000";
    };

    websocket = {
      path = "/ws";
      match = "prefix";
      nginx = {
        proxyPass = "http://127.0.0.1:3000";
        extraConfig = ''
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection "upgrade";
          proxy_read_timeout 600s;
        '';
      };
    };

    metrics = {
      path = "/metrics";
      match = "prefix";
      nginx.return = "404";
    };
  };

  nginx.extraConfig = ''
    client_max_body_size 2G;
  '';
};
```

Les chemins de route sont relatifs à `basePath`. L'exemple produit
`/prefix/`, `/prefix/ws` et `/prefix/metrics`. Le module applicatif peut donc
protéger ses endpoints métier sans connaître le préfixe choisi au déploiement.

La version initiale ne doit fournir que les concepts stables suivants :

- endpoint : schéma, hôte et préfixe public ;
- route : chemin relatif et correspondance `exact` ou `prefix` ;
- proxy simple : `proxyTo` ;
- transmission du chemin : `forwardPath = "preserve"` par défaut ou
  `"strip-prefix"` ;
- fragment Nginx natif pour tous les besoins avancés.

Il ne faut pas ajouter des booléens génériques comme `websockets`,
`requestBuffering` ou `responseBuffering`. Ces noms perdent les détails utiles
et recréent progressivement une seconde API Nginx. Le sous-attribut `nginx`
reprend, autant que possible, le sous-module `services.nginx.virtualHosts.*.locations.*`
de NixOS. Les headers, timeouts, limites de corps, retours, authentifications ou
réécritures restent donc exprimés dans leur vocabulaire natif.

Le compilateur possède toutefois les champs structurels : clé finale de la
location, `serverName`, écoute, certificat et câblage ACME. Un fragment libre
ne peut pas les remplacer.

### 7.3 Ingress wildcard

```nix
infra.ingress.s3 = {
  endpoint = {
    scheme = "https";
    host = "*.s3.app.example.com";
    basePath = "/";
  };

  routes.main = {
    path = "/";
    match = "prefix";
    nginx = {
      proxyPass = "http://127.0.0.1:3232";
      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Bucket $infra_subdomain;
      '';
    };
  };
};
```

Pour rester aligné avec le wildcard X.509, le compilateur génère un nom de
serveur regex limité à un label :

```nginx
server_name ~^(?<infra_subdomain>[^.]+)\.s3\.app\.example\.com$;
```

Il n'utilise pas directement `server_name *.s3.app.example.com`, car Nginx
peut alors accepter des profondeurs non couvertes par le certificat. La capture
`$infra_subdomain` devient disponible dans le fragment métier.

### 7.4 Conflits rejetés

L'évaluation doit notamment rejeter :

- deux routes pour le même hôte, chemin normalisé et mode de correspondance ;
- un même hôte déclaré à la fois en HTTP et HTTPS ;
- une URL, un hôte, un schéma ou un chemin invalide ;
- `..`, un chemin relatif ou une composition sortant de `basePath` ;
- plusieurs backends d'une même route avec des schémas différents ;
- un hôte HTTPS sans émetteur correspondant ;
- un wildcard ingress sans identifiant X.509 exact correspondant ;
- des sélecteurs ACME ambigus ;
- un claim multi-noms réparti entre plusieurs émetteurs ;
- un fragment Nginx qui tente de remplacer un champ possédé par le compilateur.

Les priorités entre hôtes exacts et wildcards ainsi que l'ordre des routes
doivent être déterministes et couverts par des tests.

## 8. Exécution et renouvellement

Chaque nœud matérialise uniquement les groupes référencés par ses claims
locaux. Les deux frontends peuvent demander les mêmes groupes avec les mêmes
credentials DNS ; ils conservent cependant des comptes, clés, certificats et
timers locaux.

Le module public génère :

- les secrets SOPS nécessaires aux émetteurs locaux ;
- `security.acme.certs` ;
- `security.acme.maxConcurrentRenewals = 1` pour sérialiser localement les
  opérations DNS ;
- `useACMEHost` pour Nginx quand cette option est applicable ;
- `LoadCredential` ou les chemins calculés pour les services directs ;
- `reloadServices` sur le groupe ACME concerné.

Le modèle natif conserve le certificat existant si un renouvellement échoue et
ne recharge les consommateurs qu'après un succès. Les services applicatifs ne
doivent pas avoir un `Requires=` dur vers une unité de renouvellement ACME.

Le bootstrap autosigné fourni par NixOS est utile pour permettre l'activation
initiale, mais il ne constitue pas un certificat public acceptable pour
Kanidm, une base de données ou un endpoint externe. La migration doit donc
pré-émettre et vérifier les certificats locaux avant de basculer les
consommateurs.

### Pression sur les limites ACME

Cette architecture ne promet pas « un seul compte » ou « une seule requête ».
Elle réduit les requêtes par plusieurs mécanismes plus robustes :

- renouvellement uniquement lorsque nécessaire ;
- jitter des timers natifs ;
- sérialisation locale ;
- wildcards réutilisables pour les ingress d'un même niveau ;
- regroupement SAN optionnel ;
- ajout d'un service sous un wildcard existant sans nouvelle émission.

Les deux frontends restent deux détenteurs indépendants du certificat. C'est
un compromis volontaire : une émission supplémentaire contre la suppression du
syncer et de son point de défaillance. Les limites réelles doivent être
contrôlées par serveur et profil avant le déploiement.

La sérialisation est seulement locale. Deux nœuds peuvent encore présenter en
même temps un challenge pour le même identifiant et demander le même ensemble
exact de SAN. Le jitter réduit cette probabilité sans la supprimer. Avant la
migration, il faut donc vérifier que le provider DNS conserve correctement les
valeurs TXT concurrentes, émettre les premiers certificats séquentiellement et
mesurer l'effet des limites portant sur un ensemble exact d'identifiants. Si ce
comportement n'est pas fiable, un décalage déterministe des fenêtres de
renouvellement par nœud devra faire partie de l'implémentation.

## 9. Migration sans interruption

La suppression du syncer ne doit pas être atomique. La migration proposée est
réversible et se fait par étapes :

### Phase 1 — compilateur pur

- ajouter `nixos/lib/acme.nix` ;
- ajouter les types `issuers`, `claims`, sorties calculées et plan ;
- normaliser l'ancienne et la nouvelle API ingress vers un modèle interne ;
- générer et tester le plan sans modifier les certificats consommés ;
- comparer les domaines, vhosts et routes produits avec le déploiement actuel.

### Phase 2 — émission locale en parallèle

- générer `security.acme.certs` sous de nouveaux noms stables ;
- conserver les chemins issus du syncer dans tous les consommateurs ;
- pré-émettre sur un frontend à la fois ;
- vérifier les permissions, SAN, dates, chaînes et renouvellements ;
- répéter sur le second frontend puis sur les services directs.

De nouveaux noms sont indispensables : le bootstrap natif ne doit jamais
écraser les répertoires encore alimentés par le syncer.

### Phase 3 — bascule des consommateurs

- basculer un frontend vers `useACMEHost`, puis vérifier Nginx et les SNI ;
- basculer le second frontend après observation ;
- basculer Kanidm et les autres services directs avec `LoadCredential` ;
- conserver le syncer et ses anciens certificats pendant une génération pour
  permettre un retour arrière rapide.

### Phase 4 — suppression du modèle historique

- supprimer le tag `acme-issuer` ;
- supprimer utilisateurs, groupes, clés SSH, `rrsync`, timers et unités de
  synchronisation ;
- supprimer le fallback `minica` ;
- supprimer les anciens secrets et générateurs de clés ;
- mettre à jour le template, les scripts de bootstrap et la documentation ;
- nettoyer les anciens répertoires seulement lors d'une opération manuelle
  ultérieure, jamais pendant l'activation NixOS.

### Exploitation après migration

L'ajout d'un ingress sous une couverture wildcard existante ne renouvelle pas
le certificat. L'introduction d'un nouveau niveau, par exemple
`*.s3.app.example.com`, crée un nouveau groupe. Un contrôle préalable doit
indiquer les groupes nouveaux et exiger leur émission avant l'ouverture de
l'endpoint si un certificat autosigné est inacceptable.

## 10. Fichiers probablement concernés

| Fichier | Modification prévue |
|---|---|
| `nixos/lib/acme.nix` | nouveau résolveur pur, couverture et noms stables |
| `nixos/modules/default.nix` | import du helper et injection dans `_module.args` |
| `nixos/modules/security/acme.nix` | nouveaux types, claims, plan et génération native |
| `nixos/modules/security/default.nix` | mise à jour du contrat de la catégorie |
| `nixos/modules/web/ingress.nix` | API simple/avancée et normalisation |
| `nixos/modules/web/nginx.nix` | compilateur routes/vhosts et claims implicites |
| `nixos/modules/security/kanidm.nix` | claim direct et chemins calculés |
| `nixos/modules/applications/synapse.nix` | claim et vhost spécial sans chemins manuels |
| autres modules applicatifs | migration mécanique `backend` vers `proxyTo` |
| `checks.nix` | tests purs, évaluations synthétiques et régressions |
| `template/config/acme/` | politiques d'émetteurs, sans certificats explicites |
| `template/flake.nix` | suppression finale de la clé du syncer |
| `template/inventory/nodes.nix` | suppression finale du tag `acme-issuer` |
| `template/secrets/README.md` | nouvelle forme des secrets ACME par émetteur |
| `scripts/generate-key.sh` | suppression finale du générateur du syncer |
| `scripts/init-project.sh` | retrait de l'initialisation du syncer |
| `scripts/default.nix` | retrait du paquet et des dépendances correspondantes |
| `scripts/test-sops-project.sh` | retrait des attentes liées à `generate-key` |
| `README.md`, `AGENTS.md`, `docs/*.md`, `template/README.md` | nouveau contrat et procédure de migration |

La compatibilité avec l'ancienne API ingress doit être temporaire et produire
le même modèle normalisé. L'ancienne API ACME et le syncer restent disponibles
uniquement pendant les phases de migration ; ils ne doivent pas devenir deux
chemins permanents.

## 11. Plan de validation

### 11.1 Tests purs

- suffixe : apex, enfant et descendants arbitraires ;
- priorité d'un hôte exact et du suffixe le plus long ;
- rejet des sélecteurs ambigus ou absents ;
- couverture exacte, wildcard d'un niveau et wildcard imbriqué ;
- stratégies `coverage` et `issuer` ;
- limites dépendantes du profil ;
- stabilité du nom d'un groupe après ajout d'un claim ;
- claims calculés en lecture seule, sans récursion d'évaluation ;
- absence de lecture des valeurs d'un service inactif.

### 11.2 Tests ingress synthétiques

- normalisation de l'API courte et de la compatibilité historique ;
- URL HTTP sans ACME et URL HTTPS avec claim ;
- deux routes sous un `basePath` ;
- modes exact et préfixe ;
- conservation et suppression du préfixe transmis ;
- blocage d'un endpoint métier sous un préfixe choisi au déploiement ;
- fusion d'un fragment Nginx natif ;
- wildcard limité à un label et capture `$infra_subdomain` ;
- conflits de vhosts, routes, schémas et upstreams ;
- comportement de Kanidm et du vhost spécial Synapse.

### 11.3 Évaluation et intégration

- `nix flake check --all-systems` sur le dépôt public ;
- évaluation du template avec au moins deux émetteurs ;
- `check-project` — ou le check existant du dépôt privé pendant sa migration —
  puis évaluation Colmena ;
- comparaison du plan des deux frontends ;
- vérification que seuls les secrets ACME locaux sont déclarés ;
- après chaque canary : `systemctl --failed`, journaux ACME et Nginx,
  permissions, puis vérification TLS/SNI avec `openssl s_client` ;
- après suppression : absence de toute unité, clé, utilisateur ou secret du
  syncer.

## 12. Critères d'acceptation

La refonte peut être considérée comme terminée lorsque :

- une application HTTPS simple ne déclare que son URL et son backend ;
- un service direct déclare seulement son claim et consomme ses sorties ;
- les certificats exacts, wildcards et SAN sont dérivés de façon déterministe ;
- deux domaines peuvent utiliser des comptes, DNS providers et secrets
  distincts ;
- un ingress wildcard ne peut pas servir un nom non couvert par son certificat ;
- les routes préfixées permettent les réglages Nginx métier sans nouveaux
  booléens génériques ;
- un échec de renouvellement ne casse pas l'activation d'un certificat encore
  valide ;
- les deux frontends fonctionnent sans dépendance de distribution mutuelle ;
- le template ne contient plus aucune notion de syncer ;
- les anciennes options sont supprimées après une période de migration bornée.

## 13. Hors périmètre

Cette proposition ne cherche pas à :

- écrire un client ACME ou un gestionnaire de certificats externe ;
- détecter automatiquement les domaines enregistrables via la Public Suffix
  List ;
- répliquer des clés privées entre nœuds ;
- effectuer un bin-packing dynamique des SAN ;
- remplacer l'API du module Nginx de NixOS ;
- abstraire chaque directive Nginx derrière une option générique ;
- supprimer immédiatement tous les chemins de compatibilité.

## 14. Questions à trancher pendant la revue

1. `coverage` doit-il être le seul mode initial, quitte à ajouter `issuer`
   après retour d'expérience ?
2. Faut-il accepter temporairement `*.example.com` comme alias de sélecteur,
   avec avertissement, ou le rejeter dès le début ?
3. L'apex doit-il être inclus automatiquement dans le même certificat que le
   wildcard de premier niveau, ou seulement lorsqu'un claim le demande ?
4. Un claim de service direct doit-il interdire plusieurs noms par défaut ?
5. Les ingress HTTP doivent-ils rester supportés ou être réservés à une option
   explicite pour éviter une exposition accidentelle ?
6. Le déploiement doit-il refuser automatiquement un nouveau groupe non encore
   émis, ou fournir seulement un rapport de préflight ?
7. Quels champs exacts du sous-module Nginx peuvent être fusionnés sans laisser
   un fragment remplacer la structure possédée par le compilateur ?
8. Faut-il exposer `infra.acme.plan` dans la configuration finale ou seulement
   dans les checks du flake ?
9. La séparation des comptes ACME doit-elle être validée par un test Lego/NixOS
   explicite avant d'exposer plusieurs émetteurs logiques ?
10. Le jitter natif suffit-il pour les frontends redondants avec le provider DNS
    retenu, ou faut-il décaler explicitement leurs fenêtres de renouvellement ?

## 15. Références normatives et opérationnelles

- [RFC 9525 — Service Identity in TLS](https://www.rfc-editor.org/info/rfc9525/)
  pour la portée d'un wildcard X.509 ;
- [Nginx — Server names](https://nginx.org/en/docs/http/server_names.html)
  pour les wildcards, regex et captures nommées ;
- [Nginx — `proxy_pass`](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_pass)
  pour la réécriture des chemins ;
- [Let's Encrypt — Challenge types](https://letsencrypt.org/docs/challenge-types/)
  pour le DNS-01 nécessaire aux wildcards ;
- [Let's Encrypt — Rate limits](https://letsencrypt.org/docs/rate-limits/)
  pour raisonner sur la pression réelle ;
- [Let's Encrypt — Profiles](https://letsencrypt.org/docs/profiles/)
  pour les limites propres à chaque profil ;
- options NixOS `security.acme`, `services.nginx.virtualHosts.*.useACMEHost` et
  `services.nginx.virtualHosts.*.locations` comme primitives d'exécution.
