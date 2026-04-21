{ pkgs }:

{
  infect = pkgs.writeShellApplication {
    name = "infect-server";
    runtimeInputs = [
      pkgs.curl
      pkgs.openssh
    ];
    text = builtins.readFile ./infect.sh;
  };

  adopt-hardware = pkgs.writeShellApplication {
    name = "adopt-hardware";
    runtimeInputs = [
      pkgs.jq
      pkgs.openssh
      pkgs.nix
    ];
    text = builtins.readFile ./adopt-hardware.sh;
  };

  export-ssh-key = pkgs.writeShellApplication {
    name = "export-ssh-key";
    runtimeInputs = [
      pkgs.jq
      pkgs.openssh
      pkgs.nix
      pkgs.gawk
    ];
    text = builtins.readFile ./export-ssh-key.sh;
  };

  generate-key = pkgs.writeShellApplication {
    name = "generate-key";
    runtimeInputs = [
      pkgs.openssh
    ];
    text = builtins.readFile ./generate-key.sh;
  };

  generate-mesh = pkgs.writeShellApplication {
    name = "generate-mesh";
    runtimeInputs = [
      pkgs.jq
      pkgs.wireguard-tools
      pkgs.nix
      pkgs.coreutils
    ];
    text = builtins.readFile ./generate-mesh.sh;
  };
}
