{ pkgs }:

let
  templateFiles = builtins.path {
    path = ../template;
    name = "server-setup-template";
  };
in
rec {
  infect = pkgs.writeShellApplication {
    name = "infect-server";
    runtimeInputs = [
      pkgs.coreutils
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

  update-nixos-release = pkgs.writeShellApplication {
    name = "update-nixos-release";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.gnused
      pkgs.nix
    ];
    text = builtins.readFile ./update-nixos-release.sh;
  };

  update-sops-keys = pkgs.writeShellApplication {
    name = "update-sops-keys";
    runtimeInputs = [
      pkgs.age
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.jq
      pkgs.nix
      pkgs.openssh
      pkgs.sops
      pkgs.ssh-to-age
    ];
    text = builtins.readFile ./update-sops-keys.sh;
  };

  init-project = pkgs.writeShellApplication {
    name = "init-project";
    runtimeInputs = [
      adopt-hardware
      export-ssh-key
      generate-key
      generate-mesh
      update-sops-keys
      pkgs.findutils
      pkgs.jq
      pkgs.nix
      pkgs.openssl
      pkgs.ripgrep
      pkgs.sops
      pkgs.gnused
    ];
    text = builtins.readFile ./init-project.sh;
  };

  check-project = pkgs.writeShellApplication {
    name = "check-project";
    runtimeInputs = [
      pkgs.colmena
      pkgs.findutils
      pkgs.jq
      pkgs.nix
      pkgs.ripgrep
      pkgs.sops
    ];
    text = builtins.readFile ./check-project.sh;
  };

  deploy-project = pkgs.writeShellApplication {
    name = "deploy-project";
    runtimeInputs = [
      check-project
      init-project
      pkgs.colmena
    ];
    text = builtins.readFile ./deploy-project.sh;
  };

  bootstrap-project = pkgs.writeShellApplication {
    name = "bootstrap-project";
    runtimeInputs = [
      pkgs.rsync
      pkgs.git
    ];
    text = ''
      set -euo pipefail

      if [ $# -lt 1 ]; then
        echo "Usage: bootstrap-project <target-directory>"
        echo ""
        echo "  Creates a new private deployment repo from the server-setup template."
        echo "  The <target-directory> must not exist or must be empty."
        echo ""
        echo "  After creation:"
        echo "    1. cd <target-directory>"
        echo "    2. Edit inventory/nodes.nix — set IPs, tags and SSH key path"
        echo "    3. Edit config/*.nix — set only non-secret infra.* values"
        echo "    4. nix develop"
        echo "    5. Run 'infect-server' for each VPS"
        echo "    6. init-project"
        echo "    7. Fill the encrypted fields reported by init-project"
        echo "    8. deploy-project"
        exit 1
      fi

      if [ -d "$1" ] && [ "$(ls -A "$1" 2>/dev/null)" ]; then
        echo "Error: target directory '$1' exists and is not empty."
        exit 1
      fi

      echo "Creating deployment repo in $1 ..."
      mkdir -p "$1"
      TARGET=$(cd "$1" && pwd)
      TEMPLATE_DIR="${templateFiles}"

      rsync -a "$TEMPLATE_DIR/" "$TARGET/"
      chmod -R u+w "$TARGET"

      cd "$TARGET"
      git init
      git add -A
      git commit -m "Initial commit from server-setup template" --no-verify

      echo ""
      echo "Done! Repository created at $TARGET"
      echo ""
      echo "Next steps:"
      echo "  1. Edit inventory/nodes.nix — replace all CHANGEME values"
      echo "  2. Edit config/ files — set only non-secret infra.* values"
      echo "  3. nix develop"
      echo "  4. Run 'infect-server -i <ssh-key> <user>@<ip>' for each VPS"
      echo "  5. init-project"
      echo "  6. Fill the encrypted fields reported by init-project"
      echo "  7. check-project           # evaluate without deploying"
      echo "  8. deploy-project [host]   # deploy all nodes or one host"
    '';
  };
}
