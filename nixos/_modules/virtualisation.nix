{ ... }:
{
  virtualisation = {
    # Adieu Docker
    docker.enable = false;

    # Bonjour Podman
    podman = {
      enable = true;
      # Crée un alias 'docker' -> 'podman' pour ne pas changer tes habitudes
      dockerCompat = true;

      # Pour que les containers puissent se voir via leurs noms (DNS interne)
      defaultNetwork.settings.dns_enabled = true;
    };

    # Et la cerise sur le gâteau :
    # Tu dis à NixOS "utilise Podman pour gérer mes oci-containers déclaratifs"
    oci-containers.backend = "podman";
  };
}
