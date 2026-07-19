# -------------------------------------------------------------------------
# acme.nix — Gestion des certificats TLS via ACME (Let's Encrypt)
#
# Configure un émetteur ACME sur le noeud taggé `acme-issuer` et un
# mécanisme de synchronisation rsync des certificats vers les autres
# noeuds via l'utilisateur `cert-syncer`.
#
# Options :
#   - infra.acme.email              : email de contact Let's Encrypt
#   - infra.acme.domains            : liste des domaines à certifier
#   - infra.acme.dnsProvider        : fournisseur DNS (fallback global)
#   - infra.acme.dnsCredentials     : credentials DNS (env vars, secret)
#   - infra.acme.certSyncerPrivateKey : clé privée SSH pour cert-syncer
#   - infra.acme.certSyncerPublicKey  : clé publique SSH pour cert-syncer
#
# Si `acme-issuer` activé : exécute le challenge DNS, stocke les certs,
#   autorise le compte cert-syncer à les lire via rrsync.
# Sinon : planifie un timer systemd qui rsync les certificats depuis
#   les noeuds taggés `acme-issuer`, avec fallback minica si échec.
# -------------------------------------------------------------------------
{
  config,
  pkgs,
  lib,
  services,
  ops,
  ...
}:

let
  cfg = config.infra.acme;
  tag = "acme-issuer";
  isIssuer = services.hasTag tag;
  issuerHosts = services.getHostsByTag tag;
  hasDomains = cfg.domains != [ ];

  useSopsDnsCredentials =
    isIssuer && hasDomains && cfg.dnsCredentials == null && cfg.dnsCredentialsFile == null;
  useSopsSyncerPrivateKey =
    !isIssuer
    && issuerHosts != [ ]
    && cfg.certSyncerPrivateKey == null
    && cfg.certSyncerPrivateKeyFile == null;

  getVal = local: global: if local != null then local else global;
  certName = domain: lib.replaceStrings [ "*" ] [ "_" ] domain;

  dnsCredentialsPath =
    if cfg.dnsCredentialsFile != null then
      cfg.dnsCredentialsFile
    else if cfg.dnsCredentials != null then
      "/var/lib/secrets/acme/dnsCredentials"
    else
      "/run/secrets/acme/dns-credentials";
  certSyncerPrivateKeyPath =
    if cfg.certSyncerPrivateKeyFile != null then
      cfg.certSyncerPrivateKeyFile
    else if cfg.certSyncerPrivateKey != null then
      "/var/lib/secrets/syncer.key"
    else
      "/run/secrets/acme/syncer-private-key";

  certSyncerPublicKey =
    if cfg.certSyncerPublicKey != null then
      cfg.certSyncerPublicKey
    else if cfg.certSyncerPublicKeyFile != null then
      builtins.readFile cfg.certSyncerPublicKeyFile
    else
      null;

  missingDnsCredentials = lib.any (
    domain:
    getVal domain.dnsProvider cfg.dnsProvider != null
    && domain.credentialsFile == null
    && cfg.dnsCredentialsFile == null
    && cfg.dnsCredentials == null
  ) cfg.domains;
in
{
  # Public API
  options.infra.acme = {
    email = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Adresse email utilisée pour l'enregistrement Let's Encrypt.";
    };

    domains = lib.mkOption {
      default = [ ];
      description = "Liste des domaines pour lesquels générer des certificats TLS.";
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            domain = lib.mkOption {
              type = lib.types.str;
              description = "Nom de domaine (ex: example.com, *.example.com).";
            };
            dnsProvider = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Override du fournisseur DNS pour ce domaine spécifique.";
            };
            credentialsFile = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Override du fichier de credentials DNS pour ce domaine.";
            };

            postRun = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Script à exécuter après la synchronisation des certificats (ex: recharger nginx).";
            };

            services = lib.mkOption {
              type = (lib.types.listOf lib.types.str);
              default = [ ];
              description = "Liste de services qui dépendent des certificats. Seront rechargés automatiquement après et ajoutés comme dépendances du service de sync pour s'assurer qu'ils redémarrent après la mise à jour des certs.";
            };
          };
        }
      );
    };

    dnsProvider = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Fournisseur DNS pour le challenge ACME (ex: ovh, cloudflare).";
    };

    dnsCredentials = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Variables d'environnement pour l'authentification au provider DNS.";
    };

    dnsCredentialsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Chemin runtime des credentials DNS ACME.";
    };

    certSyncerPrivateKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Clé privée SSH de l'utilisateur cert-syncer (pour rsync des certificats).";
    };

    certSyncerPrivateKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Chemin runtime de la clé privée SSH du cert-syncer.";
    };

    certSyncerPublicKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Clé publique SSH de l'utilisateur cert-syncer (pour authorized_keys).";
    };

    certSyncerPublicKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Fichier contenant la clé publique SSH du cert-syncer.";
    };
  };

  config = lib.mkMerge [
    # Module contract
    { infra.registeredTags = [ tag ]; }

    (lib.mkIf useSopsDnsCredentials {
      sops.secrets."acme/dns-credentials" = {
        sopsFile = config.infra.sops.secretsDirectory + "/acme.json";
        key = "dnsCredentials";
        owner = "acme";
        group = "acme";
      };
    })

    (lib.mkIf useSopsSyncerPrivateKey {
      sops.secrets."acme/syncer-private-key" = {
        sopsFile = config.infra.sops.secretsDirectory + "/acme-syncer.json";
        key = "privateKey";
        mode = "0400";
      };
    })

    # Local configuration shared by issuers and consumers
    (lib.mkIf hasDomains {
      users.groups.cert-syncer = { };

      users.users.acme = {
        home = "/var/lib/acme";
        createHome = true;
        homeMode = "755";
        group = "acme";
        isSystemUser = true;
      };

      users.groups.acme = { };
    })
    # Local issuer configuration
    (lib.mkIf (isIssuer && hasDomains) {
      assertions = [
        {
          assertion = cfg.email != null;
          message = "infra.acme.email is required on an ACME issuer with configured domains.";
        }
        {
          assertion = !missingDnsCredentials || useSopsDnsCredentials;
          message = "infra.acme.dnsCredentials or a per-domain credentialsFile is required when using a DNS provider.";
        }
        {
          assertion = cfg.dnsCredentials == null || cfg.dnsCredentialsFile == null;
          message = "Set at most one of infra.acme.dnsCredentials or infra.acme.dnsCredentialsFile.";
        }
        {
          assertion = certSyncerPublicKey != null;
          message = "infra.acme.certSyncerPublicKey or infra.acme.certSyncerPublicKeyFile is required on an ACME issuer with configured domains.";
        }
      ];

      deployment.keys = ops.mkSecretKeys "acme" {
        dnsCredentials = if cfg.dnsCredentialsFile == null then cfg.dnsCredentials else null;
      } [ "dnsCredentials" ];

      users.users.cert-syncer = {
        isNormalUser = true;
        group = "cert-syncer";
        openssh.authorizedKeys.keys = lib.mkIf (certSyncerPublicKey != null) [
          ''command="${pkgs.rrsync}/bin/rrsync -ro /var/lib/acme/",restrict ${certSyncerPublicKey}''
        ];
      };

      services.openssh.extraConfig = ''
        Match User cert-syncer
            PasswordAuthentication no
            PubkeyAuthentication yes
      '';

      security.acme = {
        acceptTerms = true;
        defaults.email = cfg.email;

        certs = lib.mkMerge (
          map (certOpts: {
            "${certName certOpts.domain}" = {
              dnsProvider = getVal certOpts.dnsProvider cfg.dnsProvider;
              environmentFile = getVal certOpts.credentialsFile dnsCredentialsPath;

              group = "cert-syncer";

              domain =
                if (lib.hasPrefix "*." certOpts.domain) then
                  (lib.removePrefix "*." certOpts.domain)
                else
                  certOpts.domain;
              extraDomainNames = lib.optional (lib.hasPrefix "*." certOpts.domain) (certOpts.domain);

              postRun = certOpts.postRun;
              reloadServices = certOpts.services;
            };
          }) cfg.domains
        );
      };

      systemd.services = lib.mkMerge (
        builtins.concatMap (
          d:
          let
            name = certName d.domain;
          in
          map (svc: {
            "${svc}" = {
              wants = [ "acme-${name}.service" ];
              after = [ "acme-${name}.service" ];
            };
          }) (d.services)
        ) cfg.domains
      );
    })
    # Local consumer configuration
    (lib.mkIf (!isIssuer && hasDomains && issuerHosts != [ ]) {
      assertions = [
        {
          assertion = cfg.certSyncerPrivateKey == null || cfg.certSyncerPrivateKeyFile == null;
          message = "Set at most one of infra.acme.certSyncerPrivateKey or infra.acme.certSyncerPrivateKeyFile on certificate consumers.";
        }
      ];

      deployment.keys =
        lib.optionalAttrs (cfg.certSyncerPrivateKeyFile == null && cfg.certSyncerPrivateKey != null)
          {
            "syncer.key" = {
              text = cfg.certSyncerPrivateKey;
              destDir = "/var/lib/secrets";
              user = "root";
              group = "root";
              permissions = "0400";
              name = "syncer.key";
            };
          };

      systemd.services = lib.mkMerge [
        {
          "sync-cert@" = {
            description = "Récupérer les certificats pour %i depuis le(s) issuer(s)";
            path = [
              pkgs.rsync
              pkgs.openssh
              pkgs.minica
              pkgs.util-linux
            ];
            serviceConfig.Type = "oneshot";
            serviceConfig.User = "acme";
            serviceConfig.Group = "acme";
            serviceConfig.LoadCredential = [ "ssh-key:${certSyncerPrivateKeyPath}" ];
            wants = [ "network-online.target" ];
            after = [ "network-online.target" ];

            scriptArgs = "%i";

            script = ''
              DOMAIN="$1"
              ISSUERS="${lib.concatStringsSep " " issuerHosts}"

              # On définit une fonction pour faire le boulot
              do_sync() {
                  # Ensure destination directory exists
                  mkdir -p "/var/lib/acme/$DOMAIN"

                  for IP in $ISSUERS; do
                    echo "Attempting to sync $DOMAIN from $IP..."
                    # J'ai ajouté -ro côté serveur dans l'explication, ici c'est le client
                    if rsync -avz --chmod=D750,F640 \
                      -e "ssh -i $CREDENTIALS_DIRECTORY/ssh-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10" \
                      "cert-syncer@$IP:$DOMAIN/" \
                      "/var/lib/acme/$DOMAIN/"; then
                      echo "Successfully synced from $IP"
                      return 0
                    else
                      echo "Failed to sync from $IP"
                    fi
                  done
                  return 1
              }

              # --- LA MAGIE EST ICI ---
              # On utilise un lock file global pour tous les services cert-syncer
              LOCKFILE="/tmp/cert-syncer-global.lock"

              # On utilise un descripteur de fichier (9) pour le lock
              exec 9>"$LOCKFILE"

              echo "Acquiring lock for $DOMAIN..."
              # flock va attendre (bloquer) tant que le fichier est verrouillé par un autre processus
              if flock 9; then
                  echo "Lock acquired. Starting sync for $DOMAIN."

                  # On tente la synchro
                  if do_sync; then
                      echo "Sync done."
                      # Pas besoin d'unlock explicite, ça se fait à la fin du script/fermeture du FD
                      exit 0
                  fi
              else
                  echo "Failed to acquire lock!"
                  exit 1
              fi

              # Si on arrive ici, c'est que le rsync a échoué, on passe au fallback minica
              # (Le lock est toujours actif ici, ce qui est bien pour pas surcharger le CPU si tout fail)

              # Fall back to creating temporary self-signed certificates
              echo "Creating temporary self-signed certificate for $DOMAIN using minica..."
              mkdir -p "/var/lib/acme/$DOMAIN"

              echo "Using minica at $(minica) to generate cert for $DOMAIN"

              cd "/var/lib/acme/$DOMAIN"
              if minica -domains "$DOMAIN" 2>/dev/null; then
                echo "Temporary certificate created for $DOMAIN"
                mv "$DOMAIN/cert.pem" "/var/lib/acme/$DOMAIN/cert.pem" 2>/dev/null || true
                mv "$DOMAIN/key.pem" "/var/lib/acme/$DOMAIN/key.pem" 2>/dev/null || true
                #chmod 640 "/var/lib/acme/$DOMAIN/cert.pem" "/var/lib/acme/$DOMAIN/key.pem"
                #chown acme:acme "/var/lib/acme/$DOMAIN/"*

                # --- LE HACK ---
                # On gruge Nginx en dupliquant le certif auto-signé 
                # pour simuler la fullchain et la chain.
                # Ça évite le crash de Nginx pour fichier manquant.
                cp "/var/lib/acme/$DOMAIN/cert.pem" "/var/lib/acme/$DOMAIN/fullchain.pem"
                cp "/var/lib/acme/$DOMAIN/cert.pem" "/var/lib/acme/$DOMAIN/chain.pem"
                # ---------------

                chown acme:acme "/var/lib/acme/$DOMAIN/"*.pem
                chmod 640 "/var/lib/acme/$DOMAIN/"*.pem
                
                # Optionnel mais propre : on s'assure que le dossier laisse passer nginx
                chmod 750 "/var/lib/acme/$DOMAIN"

                rm -rf "$DOMAIN" 2>/dev/null || true
                echo "Temporary certificate created for $DOMAIN"
                exit 0
              fi

              echo "All sync attempts failed for $DOMAIN"
              exit 1
            '';

          };
        }
        (lib.mkMerge (
          map (d: {
            "sync-cert-reload-${certName d.domain}" = {
              description = "Reload services after certificate sync";
              serviceConfig.Type = "oneshot";
              serviceConfig.User = "root";
              script = ''
                echo "Reloading services for ${d.domain}..."
                ${d.postRun}
                ${"systemctl --no-block try-reload-or-restart ${lib.escapeShellArgs d.services}"}
              '';
              after = [ "sync-cert@${certName d.domain}.service" ];
              wantedBy = [ "sync-cert@${certName d.domain}.service" ];
            };
          }) cfg.domains
        ))
      ];
    })
    # Local consumer scheduling
    (lib.mkIf (!isIssuer && hasDomains && issuerHosts != [ ]) {
      systemd.timers."sync-cert@" = {
        timerConfig = {
          OnBootSec = "1m";
          OnCalendar = "02:00:00";
          Persistent = true;
        };
      };

      # Activate the timer for each domain
      systemd.targets.timers.wants = map (d: "sync-cert@${certName d.domain}.timer") cfg.domains;

      systemd.services = lib.mkMerge (
        builtins.concatMap (
          d:
          let
            syncUnit = "sync-cert@${certName d.domain}.service";
          in
          map (svc: {
            "${svc}" = {
              wants = [ syncUnit ];
              after = [ syncUnit ];
            };
          }) (d.services)
        ) cfg.domains
      );

    })
  ];
}
