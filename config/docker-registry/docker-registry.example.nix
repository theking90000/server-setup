{
  infra.dockerRegistry = {
    url = "https://registry.example.com";
    accounts = ''
      user1:hashedpassword
      user2:hashedpassword
    '';
  };
}
