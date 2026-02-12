{
  # URL du repository Restic (ex: "s3:https://s3.filebase.com/XXX")
  # Dossier, ssh, sftp, ... sont aussi supportés
  # voir: https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html
  repository = "s3:https://s3.filebase.com/XXX";

  # Mot de passe de chiffrement du repository
  password = "";

  # Variables d'environnement nécessaires pour accéder au repository
  env = ''
    AWS_ACCESS_KEY_ID=XXX
    AWS_SECRET_ACCESS_KEY=XXX
    AWS_DEFAULT_REGION=us-east-1
  '';
}
