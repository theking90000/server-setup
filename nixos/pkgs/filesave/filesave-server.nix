{
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:

let
  sources = {
    "x86_64-linux" = {
      # FileSave-1.0.1-Server-linux64
      url = "https://wd40.theking90000.be/as/1073193350496";
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
