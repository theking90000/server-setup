{ pkgs }:

let
  templateFiles = builtins.path {
    path = ../template;
    name = "server-setup-template";
  };
in
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
        echo "    3. Edit config/*.nix — set URLs, credentials (search for CHANGEME)"
        echo "    4. nix develop"
        echo "    5. Run './scripts/infect.sh' for each VPS"
        echo "    6. just deploy"
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
      echo "  2. Edit config/ files — replace all CHANGEME values"
      echo "  3. nix develop"
      echo "  4. Run './scripts/infect.sh -i <ssh-key> <user>@<ip>' for each VPS"
      echo "  5. just deploy             # full deployment"
      echo "  6. just deploy --on vps1   # single node"
    '';
  };
}
