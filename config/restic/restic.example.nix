{
  infra.restic = {
    repository = "s3:https://s3.filebase.com/XXX";
    password = "";
    env = ''
      AWS_ACCESS_KEY_ID=XXX
      AWS_SECRET_ACCESS_KEY=XXX
      AWS_DEFAULT_REGION=us-east-1
    '';
  };
}
