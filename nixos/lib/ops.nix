# -------------------------------------------------------------------------
# ops.nix — Outils de déploiement (secrets, clés)
#
# Fournit `ops` via _module.args aux modules importés.
#
#   ops.mkSecretKeys prefix secrets filterList
#
#     Transforme un attrset de secrets en entrées `deployment.keys`
#     compatibles Colmena. Les secrets sont envoyés directement sur la
#     cible sans passer par le /nix/store.
#
#     - prefix     : sous-dossier dans /var/lib/secrets/ (ex: "grafana")
#     - secrets    : attrset { name = value; ... }
#     - filterList : liste des clés à déployer, ou null pour tout déployer
#
#     Exemple :
#       ops.mkSecretKeys "grafana" config.infra.grafana [ "password" "secret" ]
#       → deployment.keys."grafana-password" = { text = "..."; destDir = "/var/lib/secrets/grafana"; }
# -------------------------------------------------------------------------
{ lib, ... }:
{
  _module.args.ops = {
    mkSecretKeys =
      prefix: secrets: filterList:
      let
        filteredSecrets =
          if filterList == null
          then secrets
          else lib.filterAttrs (n: _: lib.elem n filterList) secrets;
      in
      lib.mapAttrs' (
        name: value:
        lib.nameValuePair "${prefix}-${name}" {
          text = value;
          name = name;
          destDir = "/var/lib/secrets/${prefix}";
          user = "root";
          group = "root";
          permissions = "0400";
        }
      ) filteredSecrets;
  };
}
