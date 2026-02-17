{ stdenv, pkgs, ... }:

let
  serverSrc = fetchGit {
    url = "git@github.com:theking90000/belgian-rail-data.git";
    rev = "fdbc3846e88993c56485acea30b8979010ca2c10";
  };

  nodeDependencies = (pkgs.callPackage "${serverSrc}/default.nix" { }).nodeDependencies;
in
stdenv.mkDerivation {
  pname = "belgian-rail-data";
  version = "2.0.0";
  src = serverSrc;

  buildInputs = [
    pkgs.bun
    pkgs.python3
  ];

  buildPhase = ''
    echo "Installing bun dependencies..."
    ln -s ${nodeDependencies}/lib/node_modules ./node_modules
    export PATH="${nodeDependencies}/bin:$PATH"
    bun install --no-save
    bun build --outfile belgian-rail-data --compile ./src/main.ts 
  '';

  installPhase = ''
    mkdir -p $out/bin
    install -m755 -D $src/belgian-rail-data $out/bin/belgian-rail-data
  '';
}
