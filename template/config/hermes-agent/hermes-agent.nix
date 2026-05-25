{ ... }:
{
  infra.hermes-agent = {
    # memoryLimit = "2G";        # Limite mémoire (défaut: 2G)
    # cpuQuota = "200%";         # Quota CPU, null = pas de limite (défaut: 200%)
    # allowedPorts = [ 53 80 443 ];  # Ports sortants autorisés, [] = tous
  };
}
