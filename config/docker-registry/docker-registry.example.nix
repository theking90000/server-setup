{
  # URL du registre Docker, par exemple "https://registry.example.com"
  url = "https://registry.example.com";

  # Comptes utilisateurs pour le registre Docker, format "username:hashedpassword"
  # Utiliser "htpasswd -nbB username password" pour générer les lignes à ajouter ici
  accounts = ''
    user1:hashedpassword
    user2:hashedpassword
  '';
}
