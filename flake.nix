{
  description = "Server-Setup Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-25.11-darwin";
    colmena.url = "github:zhaofengli/colmena";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    rust-storage-streamer = {
      url = "github:theking90000/rust-storage-streamer";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-darwin,
      colmena,
      sops-nix,
      rust-storage-streamer,
      ...
    }:
    {
      nixosModules.default = {
        imports = [
          sops-nix.nixosModules.sops
          rust-storage-streamer.nixosModules.default
          ./nixos/modules
        ];
      };

      # On exporte tes fonctions utilitaires (ops.nix, services.nix)
      # lib = import ./nixos/lib;

      # On package ton script d'infection pour pouvoir le lancer n'importe où
      # Support multi-architecture (Linux & macOS)
      packages =
        nixpkgs.lib.genAttrs
          [
            "x86_64-linux"
            "aarch64-linux"
            "x86_64-darwin"
            "aarch64-darwin"
          ]
          (
            system:
            let
              isMac = nixpkgs.lib.hasSuffix "-darwin" system;
              pkgs = if isMac then nixpkgs-darwin.legacyPackages.${system} else nixpkgs.legacyPackages.${system};
              scripts = import ./scripts { inherit pkgs; };
            in
            scripts
            // {
              default = scripts.infect;
            }
          );

      checks.x86_64-linux = import ./checks.nix {
        inherit self nixpkgs colmena;
      };
    };
}
