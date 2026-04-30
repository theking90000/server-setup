{
  infra.acme = {
    email = "CHANGEME";
    dnsProvider = "ovh";
    dnsCredentials = ''
      OVH_ENDPOINT=ovh-eu
      OVH_APPLICATION_KEY=CHANGEME
      OVH_APPLICATION_SECRET=CHANGEME
      OVH_CONSUMER_KEY=CHANGEME
    '';
  };
}
