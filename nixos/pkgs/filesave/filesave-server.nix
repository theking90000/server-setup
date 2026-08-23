{
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:

let
  sources = {
    "x86_64-linux" = {
      # FileSave-1.0.1-Server-linux64, réhébergé après la perte de l'ancien
      # lien. Artefact amont non patché (interpréteur /lib64), au hash
      # inchangé depuis la première version de ce paquet.
      url = "https://wd40.theking90000.be/files/726cb31b-28fd-4692-bcc4-2b80edf1a758";
      sha256 = "sha256-oG0sbTVYr1zJX+rTW69A4Zv9W8rZEvtZri0l+f116VU=";
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
