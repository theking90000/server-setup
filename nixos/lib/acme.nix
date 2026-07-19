# -------------------------------------------------------------------------
# acme.nix — Résolution pure des claims ACME vers les émetteurs
#
# Fournit `acme` via _module.args aux modules importés. Toutes les
# fonctions sont pures : elles reçoivent les politiques d'émetteurs et le
# claim en argument et ne lisent jamais `config`. Les appelants passent
# `config.infra.acme.issuers` explicitement — jamais de closure sur la
# configuration, afin d'éviter toute récursion de modules.
#
#   acme.resolveName issuers name
#     → nom logique de l'émetteur choisi pour un nom DNS.
#       Un hôte exact (`match.hosts`) est prioritaire ; sinon le suffixe
#       correspondant le plus long (`match.suffixes`) est retenu — un
#       suffixe couvre son apex et tous ses descendants.
#
#   acme.tryResolveClaim { issuers, claimName, claim }
#     → { ok, errors, value } où value décrit le groupe de certificat :
#       émetteur, nom stable, identifiants X.509, chemins et unités.
#
#   acme.resolveClaim { issuers, claimName, claim }
#     → comme tryResolveClaim mais lève une erreur d'évaluation.
#
# Couverture (`coverage`) :
#   - "exact"    : un identifiant X.509 exact, un seul nom par claim ;
#   - "wildcard" : chaque nom est promu vers le wildcard de son niveau
#     (`git.x.y` → `*.x.y`) ; l'apex du suffixe rejoint le wildcard de
#     premier niveau (`x.y` → `x.y` + `*.x.y`).
#
# Les noms de groupes (`certNameFor`) dérivent uniquement de l'émetteur,
# du scope et du niveau de couverture : ajouter un claim ne renomme jamais
# un certificat déployé. Ils ne contiennent que [a-z0-9-] (contrainte des
# unités systemd de security.acme) et jamais de point — ils sont donc
# disjoints des anciens répertoires /var/lib/acme/<domaine> du modèle
# cert-syncer.
# -------------------------------------------------------------------------
{ lib, ... }:

let
  # "*.a.b" → "a.b" ; "a.b" → "a.b"
  baseName = lib.removePrefix "*.";

  isWildcardName = lib.hasPrefix "*.";

  # "x.a.b" → "a.b"
  parentOf = name: lib.concatStringsSep "." (builtins.tail (lib.splitString "." name));

  # Labels [a-z0-9-] sans tiret en bordure, au moins deux labels,
  # au plus un "*." de tête.
  validDnsName =
    name:
    let
      base = baseName name;
      label = "[a-z0-9]([a-z0-9-]*[a-z0-9])?";
    in
    !lib.hasInfix "*" base && builtins.match "${label}(\\.${label})+" base != null;

  sanitize = lib.replaceStrings [ "." ] [ "-" ];

  validSlug = slug: builtins.match "[a-z0-9-]+" slug != null;

  matchingIssuers =
    issuers: name:
    let
      base = baseName name;
      matchesOf =
        issuerName: issuer:
        lib.optional (lib.elem name (issuer.match.hosts or [ ])) {
          issuer = issuerName;
          kind = "host";
          suffix = null;
        }
        ++ map (s: {
          issuer = issuerName;
          kind = "suffix";
          suffix = s;
        }) (lib.filter (s: base == s || lib.hasSuffix ".${s}" base) (issuer.match.suffixes or [ ]));
    in
    lib.concatLists (lib.mapAttrsToList matchesOf issuers);

  tryResolveName =
    issuers: name:
    let
      ms = matchingIssuers issuers name;
      hosts = lib.filter (m: m.kind == "host") ms;
      suffixes = lib.filter (m: m.kind == "suffix") ms;
      maxLen = lib.foldl' lib.max 0 (map (m: lib.stringLength m.suffix) suffixes);
      best =
        if hosts != [ ] then hosts else lib.filter (m: lib.stringLength m.suffix == maxLen) suffixes;
      issuerNames = lib.unique (map (m: m.issuer) best);
    in
    if ms == [ ] then
      {
        ok = false;
        errors = [ "no ACME issuer matches '${name}'" ];
        match = null;
      }
    else if lib.length issuerNames > 1 then
      {
        ok = false;
        errors = [
          "ambiguous ACME issuers for '${name}': ${lib.concatStringsSep ", " issuerNames} match with the same priority"
        ];
        match = null;
      }
    else
      {
        ok = true;
        errors = [ ];
        match = lib.head best;
      };

  # Niveau de couverture X.509 d'un nom résolu.
  # `suffix` est le suffixe de l'émetteur retenu (null pour un match hôte,
  # qui reste toujours exact). Précondition : les noms wildcard n'arrivent
  # ici qu'avec coverage = "wildcard" et un match par suffixe
  # (tryResolveClaim rejette les autres combinaisons).
  #
  # Échappatoire future : si la limite « duplicate certificate » de
  # Let's Encrypt devenait un problème (plusieurs frontends commandant le
  # même ensemble exact de SAN), ajouter ici un identifiant supplémentaire
  # par nœud (ex: "<nodeName>.<suffix>") rendrait chaque ensemble unique.
  coverageOf =
    {
      coverage,
      suffix,
    }:
    name:
    if coverage == "exact" || suffix == null then
      {
        label = "exact-${sanitize name}";
        identifiers = [ name ];
      }
    else if isWildcardName name then
      {
        label = "wildcard-${sanitize (baseName name)}";
        identifiers = [ name ];
      }
    else if name == suffix then
      {
        label = "wildcard-${sanitize name}";
        identifiers = [
          name
          "*.${name}"
        ];
      }
    else
      {
        label = "wildcard-${sanitize (parentOf name)}";
        identifiers = [ "*.${parentOf name}" ];
      };

  certNameFor =
    issuer: scope: label:
    "${issuer}-${scope}-${label}";

  tryResolveClaim =
    {
      issuers,
      claimName,
      claim,
    }:
    let
      prefix = "infra.acme.claims.${claimName}";
      names = claim.names;
      coverage = claim.coverage or "exact";
      scope = claim.consumer.scope;

      scopeErrors = lib.optional (!validSlug scope) "${prefix}: consumer.scope '${scope}' must match [a-z0-9-]+";
      emptyErrors = lib.optional (names == [ ]) "${prefix}: names must not be empty";
      invalidNameErrors = lib.concatMap (
        n: lib.optional (!validDnsName n) "${prefix}: invalid DNS name '${n}'"
      ) names;
      validNames = lib.filter validDnsName names;

      exactErrors =
        lib.optional (coverage == "exact" && lib.length names > 1)
          "${prefix}: an exact claim must declare exactly one name (got ${toString (lib.length names)})"
        ++ lib.optional (coverage == "exact" && lib.any isWildcardName names)
          "${prefix}: an exact claim cannot use a wildcard name";

      resolutions = map (n: {
        name = n;
        res = tryResolveName issuers n;
      }) validNames;
      resolutionErrors = lib.concatMap (r: map (e: "${prefix}: ${e}") r.res.errors) resolutions;
      matched = lib.filter (r: r.res.ok) resolutions;

      hostWildcardErrors = lib.concatMap (
        r:
        lib.optional (isWildcardName r.name && r.res.match.suffix == null)
          "${prefix}: wildcard name '${r.name}' requires a suffix-matched issuer, not a hosts match"
      ) matched;

      issuerNames = lib.unique (map (r: r.res.match.issuer) matched);
      multiIssuerErrors =
        lib.optional (lib.length issuerNames > 1)
          "${prefix}: names resolve to several issuers (${lib.concatStringsSep ", " issuerNames}); split the claim";
      issuerSlugErrors = lib.concatMap (
        i: lib.optional (!validSlug i) "${prefix}: issuer name '${i}' must match [a-z0-9-]+"
      ) issuerNames;

      coverages = map (
        r:
        coverageOf {
          inherit coverage;
          inherit (r.res.match) suffix;
        } r.name
      ) matched;
      labels = lib.unique (map (c: c.label) coverages);
      multiGroupErrors =
        lib.optional (lib.length labels > 1)
          "${prefix}: names span several coverage groups (${lib.concatStringsSep ", " labels}); split the claim";

      errors =
        scopeErrors
        ++ emptyErrors
        ++ invalidNameErrors
        ++ exactErrors
        ++ resolutionErrors
        ++ hostWildcardErrors
        ++ multiIssuerErrors
        ++ issuerSlugErrors
        ++ multiGroupErrors;

      value =
        let
          issuer = lib.head issuerNames;
          certName = certNameFor issuer scope (lib.head labels);
        in
        {
          inherit issuer certName;
          identifiers = lib.unique (lib.concatLists (map (c: c.identifiers) coverages));
          directory = "/var/lib/acme/${certName}";
          unit = "acme-${certName}.service";
          renewUnit = "acme-order-renew-${certName}.service";
        };
    in
    {
      ok = errors == [ ];
      inherit errors;
      value = if errors == [ ] then value else null;
    };

  resolveClaim =
    args:
    let
      r = tryResolveClaim args;
    in
    if r.ok then r.value else throw (lib.concatStringsSep "\n" r.errors);

  resolveName =
    issuers: name:
    let
      r = tryResolveName issuers name;
    in
    if r.ok then r.match.issuer else throw (lib.concatStringsSep "\n" r.errors);
in
{
  _module.args.acme = {
    inherit
      isWildcardName
      baseName
      parentOf
      validDnsName
      sanitize
      matchingIssuers
      resolveName
      coverageOf
      certNameFor
      tryResolveClaim
      resolveClaim
      ;
  };
}
