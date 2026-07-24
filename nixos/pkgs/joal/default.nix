{
  lib,
  stdenvNoCC,
  fetchurl,
  jre_headless,
  makeWrapper,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "joal";
  version = "2.1.37";

  src = fetchurl {
    url = "https://github.com/anthonyraymond/joal/releases/download/${finalAttrs.version}/joal.tar.gz";
    hash = "sha256-B4lwzlO71pyacjLGEX6L10fqzULC5vhOC5enIrrcLrg=";
  };

  # La release 2.1.37 précède qBittorrent 5.2.2. Ce profil est généré
  # automatiquement par JOAL et épinglé au commit du 2026-07-15.
  qbittorrentProfile = fetchurl {
    url = "https://raw.githubusercontent.com/anthonyraymond/joal/90e710ba01ac6a8665eb352a612ce4e9581483c8/resources/clients/qbittorrent-5.2.2.client";
    hash = "sha256-ma5utCXVfs8JW+xjbREO/zBUwEchVdkR/xUHfXJWt9U=";
  };

  sourceRoot = ".";
  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    install -Dm444 jack-of-all-trades-${finalAttrs.version}.jar \
      "$out/share/joal/jack-of-all-trades.jar"
    install -dm755 "$out/share/joal/clients"
    install -m444 clients/*.client "$out/share/joal/clients/"
    install -m444 "$qbittorrentProfile" \
      "$out/share/joal/clients/qbittorrent-5.2.2.client"

    makeWrapper ${jre_headless}/bin/java "$out/bin/joal" \
      --add-flags "-jar $out/share/joal/jack-of-all-trades.jar"

    runHook postInstall
  '';

  meta = {
    description = "Open source command-line RatioMaster with an optional WebUI";
    homepage = "https://github.com/anthonyraymond/joal";
    license = lib.licenses.asl20;
    mainProgram = "joal";
    platforms = lib.platforms.unix;
  };
})
