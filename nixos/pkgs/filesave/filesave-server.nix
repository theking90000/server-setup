{
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:

let
  sources = {
    "x86_64-linux" = {
      # FileSave-1.0.1-Server-linux64, réhébergé après la perte de l'ancien
      # lien. Ce fichier est le binaire tel qu'il tourne en production, donc
      # déjà passé par autoPatchelfHook : son interpréteur ELF pointe vers un
      # chemin du store. Le hook le repatche au build, les bibliothèques
      # requises restant les mêmes (libgcc_s + glibc).
      url = "https://wd40.theking90000.be/files/9efc8884-e563-4131-89dc-9004d9b246e3";
      sha256 = "sha256-9woHJA+PMueCkUBUcpMjL7a6qQHkRbiJpZhdFe6rGKg=";
    };
  };

  system = stdenv.hostPlatform.system;

  sourceData = sources.${system} or (throw "Unsupported system architecture: ${system}.");

in
stdenv.mkDerivation rec {
  pname = "filesave-server";
  version = "1.0.1";

  src = fetchurl {
    # L'URL ne porte plus de nom de fichier : on nomme la source
    # explicitement pour que le chemin du store reste lisible et stable.
    name = "${pname}-${version}-bin";
    url = sourceData.url;
    sha256 = sourceData.sha256;
  };

  dontUnpack = true;

  nativeBuildInputs = [ autoPatchelfHook ];

  buildInputs = [ stdenv.cc.cc.lib ];

  installPhase = ''
    install -m755 -D $src $out/bin/${pname}
  '';

  meta = {
    description = "Filesave server";
    platforms = builtins.attrNames sources; # On ne supporte que ce qu'on a défini
  };
}
