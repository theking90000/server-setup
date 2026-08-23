# -------------------------------------------------------------------------
# sonarr.nix — Choix fonctionnels Sonarr
#
# Le module public pose le service, l'écoute sur wg0, l'ACL, l'ingress, le
# SSO, l'exporteur et la sauvegarde. Tout le reste vit dans la base SQLite
# de Sonarr et se fait UNE FOIS à la main : le guide est en bas de fichier.
# -------------------------------------------------------------------------
{ ... }:
{
  infra.sonarr = {
    # URL publique via nginx. Laisser commenté pour un accès réservé au
    # mesh WireGuard (ssh -L 8989:<ip wg0 du nœud>:8989).
    #
    # Avec un nœud `kanidm` dans la flotte, cette URL est automatiquement
    # protégée par oauth2-proxy et Sonarr passe en authentification
    # `External`. Sans nœud `kanidm`, elle est publiée avec le simple
    # formulaire de connexion Sonarr : le déploiement émet un warning.
    # url = "https://CHANGEME";
  };

  # =========================================================================
  # À FAIRE MANUELLEMENT — rien de ce qui suit n'est déclaratif
  # =========================================================================
  #
  # Sonarr stocke indexeurs, download clients, root folders, profils et
  # notifications dans sa base SQLite. Nix ne peut ni les écrire ni les
  # vérifier. Cette liste est l'ordre d'exécution recommandé.
  #
  # -- 1. Avant le premier déploiement ------------------------------------
  #
  #   a) ajouter le tag `applications/sonarr` au nœud voulu dans
  #      inventory/nodes.nix ;
  #   b) `init-project` crée secrets/sonarr.json avec une clé d'API
  #      aléatoire. Pour la relire ensuite : `sops secrets/sonarr.json` ;
  #   c) si le nœud héberge aussi qBittorrent, aligner le montage de la
  #      médiathèque sur le groupe `media` dans
  #      config/rclone-sync/rclone-sync.nix (voir le commentaire là-bas).
  #
  # -- 2. Accès SSO (une fois par utilisateur) ----------------------------
  #
  #   Le groupe Kanidm `sonarr_users` est provisionné automatiquement, mais
  #   les membres ne le sont pas :
  #
  #     kanidm login -D idm_admin
  #     kanidm group add-members sonarr_users <utilisateur> -D idm_admin
  #
  #   Un utilisateur hors du groupe reçoit un 403 après authentification.
  #
  # -- 3. Premier démarrage ------------------------------------------------
  #
  #   Sans SSO : Sonarr demande de créer un compte local à la première
  #   ouverture. Avec SSO : aucune connexion n'est demandée, oauth2-proxy a
  #   déjà tranché.
  #
  #   Vérifier dans System > Status que l'instance est saine, puis dans
  #   Settings > General que l'API Key affichée correspond bien à celle du
  #   fichier chiffré (elle est imposée par variable d'environnement à
  #   chaque démarrage ; une régénération depuis l'UI ne survit pas à un
  #   redémarrage du service).
  #
  # -- 4. Download client (Settings > Download Clients > + > qBittorrent) --
  #
  #   Sur le même nœud que qBittorrent, la WebUI est joignable par le veth
  #   du netns du kill switch :
  #
  #     Host        10.200.0.2
  #     Port        8080
  #     Username    (vide)
  #     Password    (vide)
  #     Category    sonarr
  #
  #   Identifiants vides : le module qBittorrent inscrit 10.200.0.0/30 dans
  #   sa liste de sous-réseaux exemptés d'authentification quand le SSO est
  #   actif. Sans SSO, saisir `admin` et la valeur `webui_password` du
  #   fichier chiffré qbittorrent.
  #
  #   Utiliser une catégorie distincte de celle de Radarr : deux
  #   applications qui se partagent une catégorie se volent les
  #   téléchargements.
  #
  #   Sur un AUTRE nœud : utiliser l'IP wg0 du nœud qBittorrent, et ajouter
  #   `applications/sonarr` aux `allowedTags` de l'ACL WebUI dans le module
  #   public qbittorrent.nix — sinon le pare-feu refuse la connexion.
  #
  # -- 5. Dossiers ---------------------------------------------------------
  #
  #   Créer la racine de la médiathèque avant de l'ajouter dans l'UI :
  #
  #     mkdir -p /mnt/media/Series
  #
  #   puis Settings > Media Management > Root Folders > + > /mnt/media/Series
  #
  #   Le dossier de téléchargement de qBittorrent
  #   (/var/lib/qBittorrent/qBittorrent/downloads) reçoit un setgid vers le
  #   groupe `media` et qBittorrent tourne avec UMask=0002 : Sonarr peut y
  #   lire et y supprimer après import. Les fichiers déjà présents avant le
  #   déploiement gardent leurs anciens droits, les corriger une fois :
  #
  #     chgrp -R media /var/lib/qBittorrent/qBittorrent/downloads
  #     chmod -R g+rwX /var/lib/qBittorrent/qBittorrent/downloads
  #
  # -- 6. Indexeurs, profils, listes --------------------------------------
  #
  #   Settings > Indexers, Settings > Profiles, Series > Import Lists : rien
  #   n'est fourni par l'infrastructure, tout se saisit dans l'UI.
  #
  # -- 7. Notification Jellyfin (facultatif) -------------------------------
  #
  #   Settings > Connect > + > Emby / Jellyfin, avec l'URL interne de
  #   Jellyfin (http://<ip wg0 du nœud jellyfin>:8096) et une clé d'API
  #   Jellyfin, pour déclencher un rafraîchissement de bibliothèque après
  #   chaque import.
  #
  # -- 8. Sauvegarde -------------------------------------------------------
  #
  #   Restic sauvegarde /var/lib/sonarr, plus un instantané SQLite cohérent
  #   déposé dans /var/lib/sonarr/db-backup avant chaque run. Pour
  #   restaurer : arrêter sonarr.service, remettre le fichier db-backup en
  #   place sous le nom sonarr.db dans le dossier de données, supprimer les
  #   éventuels sonarr.db-wal / sonarr.db-shm, redémarrer.
  #
  # -- 9. Limites de stockage à garder en tête -----------------------------
  #
  #   Une médiathèque montée par rclone (chiffrée ou distante) ne supporte
  #   ni lien physique ni renommage atomique : chaque import est une copie
  #   complète à travers le cache VFS. Prévoir l'espace disque local et
  #   éviter d'importer plusieurs gros fichiers en parallèle.
}
