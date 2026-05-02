{
  infra.kanidm = {
    url = "https://CHANGEME";

    # ── Users (optionnel) ──
    # users = {
    #   "alice" = {
    #     displayName = "Alice";
    #     isAdmin = true;
    #     email = "alice@example.com";
    #   };
    #   "bob" = {
    #     displayName = "Bob";
    #   };
    # };

    # ── OAuth2/OIDC clients (optionnel, peuplé par les modules ou ici) ──
    # oauth2 = {
    #   gitea = {
    #     displayName = "Gitea";
    #     redirectUris = ["https://git.example.com/user/oauth2/kanidm/callback"];
    #   };
    # };

    # ── LDAPS (optionnel) ──
    # ldapPort = 3636;
  };
}
