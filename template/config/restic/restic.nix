{
  infra.restic = {
    repository = "s3:https://CHANGEME";
    password = "CHANGEME";
    env = ''
      AWS_ACCESS_KEY_ID=CHANGEME
      AWS_SECRET_ACCESS_KEY=CHANGEME
      AWS_DEFAULT_REGION=CHANGEME
    '';
  };
}
