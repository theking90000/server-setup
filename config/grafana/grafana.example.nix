{
  # Nom de l'utilisateur admin pour se connecter au web
  user = "admin";

  # Mot de passe pour se connecter au web (à changer impérativement)
  password = "admin";

  # URL d'accès à Grafana
  # Configurera le serveur interne grafana pour qu'il suppose cette URL.
  # Par défaut grafana écoute sur le réseau virtuel wireguard
  # Pour le rendre accessible, il faudra tagger au moins un noeud avec le tag 'web-server'
  # Ce qui configurera automatiquement le reverse proxy Nginx ainsi que les certificats TLS via Let's Encrypt
  url = "https://grafana.example.com";
}
