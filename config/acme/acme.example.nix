{
  infra.acme = {
    email = "";
    dnsProvider = "ovh";
    dnsCredentials = ''
      OVH_ENDPOINT=ovh-eu
      OVH_APPLICATION_KEY=
      OVH_APPLICATION_SECRET=
      OVH_CONSUMER_KEY=
    '';
  };
}
