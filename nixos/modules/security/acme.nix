# -------------------------------------------------------------------------
# acme.nix — Émission locale des certificats TLS via ACME (Let's Encrypt)
#
# Chaque nœud émet lui-même les certificats dont ses services ont besoin,
# avec le module natif `security.acme` de NixOS (challenge DNS-01). Il n'y
# a plus de nœud émetteur central ni de synchronisation de clés privées.
#
# Options :
#   - infra.acme.issuers.<nom>  : politique d'émission (correspondances
#     DNS, email, provider DNS, serveur ACME, type de clé, profil)
#   - infra.acme.claims.<nom>   : intention d'un consommateur local — les
#     noms DNS utilisés, le scope de partage de clé, les services à
#     recharger (`reloadServices`) ou redémarrer (`restartServices`)
#   - infra.acme.claims.<nom>.certificate : résultat calculé en lecture
#     seule (nom du groupe, chemins fullchain/chain/key, unités systemd)
#   - infra.acme.plan           : plan d'émission calculé (diagnostic)
#
# Résolution : chaque claim est routé vers un émetteur par la lib pure
# `acme` (hôte exact prioritaire, sinon suffixe le plus long), puis
# regroupé par (émetteur, scope, niveau de couverture) en groupes de
# certificats aux noms stables. Les ambiguïtés et conflits échouent à
# l'évaluation, avant tout déploiement.
#
# Renouvellement : `reloadServices` utilise le rechargement natif ;
# `restartServices` force un vrai redémarrage via postRun — indispensable
# pour les consommateurs LoadCredential, car systemd ne relit les
# credentials qu'au redémarrage du service, jamais lors d'un reload.
#
# Secrets : credentials DNS par émetteur dans secrets/acme.json sous
# `issuers.<nom>.dnsCredentials` (format env-file lego). Seuls les
# émetteurs réellement utilisés par des claims locaux sont déchiffrés.
# -------------------------------------------------------------------------
{
  config,
  lib,
  acme,
  ...
}:

let
  cfg = config.infra.acme;
  outerConfig = config;
  types = lib.types;

  issuerSubmodule = types.submodule {
    options = {
      match = {
        suffixes = lib.mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Sous-arbres DNS couverts : chaque suffixe couvre son apex et tous ses descendants.";
        };
        hosts = lib.mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Noms exacts routés vers cet émetteur, prioritaires sur les suffixes.";
        };
      };

      email = lib.mkOption {
        type = types.str;
        description = "Adresse email du compte ACME.";
      };

      dnsProvider = lib.mkOption {
        type = types.str;
        description = "Fournisseur DNS lego pour le challenge DNS-01 (ex: ovh, cloudflare).";
      };

      dnsCredentialsFile = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Chemin runtime des credentials DNS (sinon SOPS: issuers.<nom>.dnsCredentials).";
      };

      server = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "URL du serveur ACME (null = Let's Encrypt production).";
      };

      keyType = lib.mkOption {
        type = types.str;
        default = "ec256";
        description = "Type de clé des certificats émis.";
      };

      profile = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Profil ACME demandé au serveur (null = défaut du serveur).";
      };

      dnsResolver = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Résolveur DNS utilisé pour vérifier la propagation du challenge.";
      };
    };
  };

  claimSubmodule = types.submodule (
    {
      name,
      config,
      ...
    }:
    {
      options = {
        names = lib.mkOption {
          type = types.listOf types.str;
          description = "Noms DNS consommés par ce claim.";
        };

        consumer = {
          kind = lib.mkOption {
            type = types.enum [
              "service"
              "ingress"
            ];
            default = "service";
            description = "Nature du consommateur.";
          };
          scope = lib.mkOption {
            type = types.str;
            description = "Scope de partage de la clé privée ; fait partie du nom du groupe.";
          };
        };

        coverage = lib.mkOption {
          type = types.enum [
            "exact"
            "wildcard"
          ];
          default = "exact";
          description = "Couverture X.509 : nom exact, ou promotion vers le wildcard du niveau.";
        };

        group = lib.mkOption {
          type = types.str;
          default = "acme";
          description = "Groupe Unix autorisé à lire la clé privée du groupe de certificat.";
        };

        reloadServices = lib.mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Unités rechargées après un renouvellement réel (try-reload-or-restart).";
        };

        restartServices = lib.mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Unités redémarrées après un renouvellement réel — requis pour LoadCredential.";
        };

        certificate = lib.mkOption {
          readOnly = true;
          type = types.attrs;
          description = "Résultat calculé : nom du groupe, chemins des fichiers et unités systemd.";
          defaultText = lib.literalMD "calculé depuis `infra.acme.issuers` et le claim";
          default =
            let
              r = acme.resolveClaim {
                issuers = outerConfig.infra.acme.issuers;
                claimName = name;
                claim = { inherit (config) names consumer coverage; };
              };
            in
            {
              inherit (r) directory unit renewUnit;
              name = r.certName;
              # cert.pem est un symlink vers fullchain.pem après émission
              # réelle ; `fullchain` est le champ canonique.
              certificate = "${r.directory}/cert.pem";
              fullchain = "${r.directory}/fullchain.pem";
              chain = "${r.directory}/chain.pem";
              key = "${r.directory}/key.pem";
              combined = "${r.directory}/full.pem";
            };
        };
      };
    }
  );

  # ── Pipeline de résolution ────────────────────────────────────────────
  resolvedList = lib.mapAttrsToList (n: c: {
    claimName = n;
    claim = c;
    res = acme.tryResolveClaim {
      issuers = cfg.issuers;
      claimName = n;
      claim = { inherit (c) names consumer coverage; };
    };
  }) cfg.claims;

  claimErrors = lib.concatMap (x: x.res.errors) resolvedList;
  okList = lib.filter (x: x.res.ok) resolvedList;
  byCert = lib.groupBy (x: x.res.value.certName) okList;

  groupInfo =
    certName: members:
    let
      issuerName = (lib.head members).res.value.issuer;
      identifiers = lib.unique (lib.concatMap (m: m.res.value.identifiers) members);
      exact = lib.filter (i: !acme.isWildcardName i) identifiers;
      wild = lib.filter acme.isWildcardName identifiers;
      domain = if exact != [ ] then lib.head (lib.naturalSort exact) else lib.head (lib.naturalSort wild);
    in
    {
      inherit
        certName
        issuerName
        identifiers
        domain
        members
        ;
      issuer = cfg.issuers.${issuerName};
      extraDomainNames = lib.naturalSort (lib.remove domain identifiers);
      unixGroups = lib.unique (map (m: m.claim.group) members);
      reload = lib.unique (lib.concatMap (m: m.claim.reloadServices) members);
      restart = lib.unique (lib.concatMap (m: m.claim.restartServices) members);
      bases = lib.unique (map acme.baseName identifiers);
    };

  groupList = lib.mapAttrsToList groupInfo byCert;

  groupErrors = lib.concatMap (
    g:
    lib.optional (lib.length g.unixGroups > 1)
      "infra.acme: claims of certificate group '${g.certName}' disagree on `group` (${lib.concatStringsSep ", " g.unixGroups})"
    ++
      lib.optional (lib.length g.bases > 1)
        "infra.acme: certificate group '${g.certName}' mixes distinct coverage bases (${lib.concatStringsSep ", " g.bases}); sanitized domain names collide, rename one of them"
  ) groupList;

  usedIssuerNames = lib.unique (
    map (g: g.issuerName) (lib.filter (g: g.issuer.dnsCredentialsFile == null) groupList)
  );

  credentialsPath =
    issuerName: issuer:
    if issuer.dnsCredentialsFile != null then
      issuer.dnsCredentialsFile
    else
      "/run/secrets/acme/issuers/${issuerName}/dns-credentials";
in
{
  options.infra.acme = {
    issuers = lib.mkOption {
      type = types.attrsOf issuerSubmodule;
      default = { };
      description = "Politiques d'émission ACME du déploiement.";
    };

    claims = lib.mkOption {
      type = types.attrsOf claimSubmodule;
      default = { };
      description = "Intentions locales de consommation de certificats.";
    };

    plan = lib.mkOption {
      readOnly = true;
      internal = true;
      type = types.attrsOf types.attrs;
      description = "Plan d'émission calculé, par groupe de certificat. Diagnostic et tests uniquement.";
      defaultText = lib.literalMD "calculé depuis les claims locaux";
      default = lib.listToAttrs (
        map (g: {
          name = g.certName;
          value = {
            issuer = g.issuerName;
            inherit (g) domain extraDomainNames identifiers;
            group = lib.head g.unixGroups;
            reloadServices = g.reload;
            restartServices = g.restart;
            claims = map (m: m.claimName) g.members;
          };
        }) groupList
      );
    };

  };

  config = lib.mkMerge [
    {
      assertions = map (e: {
        assertion = false;
        message = e;
      }) (claimErrors ++ groupErrors);
    }

    (lib.mkIf (cfg.claims != { }) {
      security.acme = {
        acceptTerms = true;
        # Sérialise localement les opérations DNS ; les nœuds restent
        # indépendants entre eux (jitter natif des timers).
        maxConcurrentRenewals = 1;

        certs = lib.listToAttrs (
          map (g: {
            name = g.certName;
            value = {
              inherit (g) domain extraDomainNames;
              email = g.issuer.email;
              dnsProvider = g.issuer.dnsProvider;
              keyType = g.issuer.keyType;
              environmentFile = credentialsPath g.issuerName g.issuer;
              group = lib.head g.unixGroups;
              reloadServices = g.reload;
              postRun = lib.optionalString (
                g.restart != [ ]
              ) "systemctl --no-block try-restart ${lib.escapeShellArgs g.restart}";
            }
            // lib.optionalAttrs (g.issuer.server != null) { inherit (g.issuer) server; }
            // lib.optionalAttrs (g.issuer.profile != null) { inherit (g.issuer) profile; }
            // lib.optionalAttrs (g.issuer.dnsResolver != null) { inherit (g.issuer) dnsResolver; };
          }) groupList
        );
      };

      # Dépendances douces : les consommateurs démarrent après le bootstrap
      # du certificat (autosigné au premier démarrage), jamais avec un
      # Requires dur vers une unité de renouvellement.
      systemd.services = lib.mkMerge (
        lib.concatMap (
          x:
          map (svc: {
            "${lib.removeSuffix ".service" svc}" = {
              wants = [ x.res.value.unit ];
              after = [ x.res.value.unit ];
            };
          }) (x.claim.reloadServices ++ x.claim.restartServices)
        ) okList
      );
    })

    (lib.mkIf (usedIssuerNames != [ ]) {
      sops.secrets = lib.listToAttrs (
        map (i: {
          name = "acme/issuers/${i}/dns-credentials";
          value = {
            sopsFile = config.infra.sops.secretsDirectory + "/acme.json";
            key = "issuers/${i}/dnsCredentials";
            owner = "acme";
            group = "acme";
          };
        }) usedIssuerNames
      );
    })
  ];
}
