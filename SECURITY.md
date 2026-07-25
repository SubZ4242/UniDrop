# Sicherheitsmodell

## Aktueller Umfang

Der aktuelle Prototyp enthaelt den bestaetigten Discovery-Test und einen ersten
Transfer-MVP. Standardmaessig ist Forwarding deaktiviert. Wenn es explizit in
`gateway-macos/config/discovery-test.toml` aktiviert wird, beantwortet der
Mac-Gateway-Dienst `/Ask`, nimmt `/Upload` entgegen und streamt das
AirDrop-CPIO/GZip-Archiv an den konfigurierten Windows-Receiver weiter.

Der Windows-Receiver ist noch kein Tray-Client. Er ist ein schlanker .NET-8
HTTP-Dienst fuer den ersten End-to-End-Test.

## Schutzwerte und Vertrauensgrenzen

Zu schützen sind:

- Verfügbarkeit und unveränderte Funktion des nativen `sharingd`;
- lokale Account- und AirDrop-Validierungsdaten;
- Mac-Dateisystem und Benutzerkonto;
- private TLS-Schlüssel des Tests;
- Begrenzung des Testservers auf AWDL.

Nicht vertrauenswürdig sind sämtliche HTTP-Anfragen und Bonjour-Peers auf AWDL.
Auch ein AirDrop-kompatibler Sender gilt vor einer späteren Pairing- und
Transferauthentifizierung nicht als autorisiert.

## Maßnahmen im Discovery-Test

- `sharingd`, SIP, Systemdateien, Firewall und Netzwerkeinstellungen werden
  nicht verändert.
- Der TCP-Listener bindet an die konkrete link-lokale Adresse von `awdl0`.
  Eine Loopback-Gegenprobe muss mit `ECONNREFUSED` enden.
- Die Bonjour-Registrierung ist auf Interface-Index 20 (`awdl0`) begrenzt.
- Ein eigenes Runtime-TLS-Schlüsselpaar wird mit Modus 0600 erzeugt und durch
  `.gitignore` vom Repository ausgeschlossen.
- `/Discover` begrenzt sowohl Content-Length- als auch Chunked-Anfragen auf
  1 MiB.
- Ohne aktiviertes Forwarding werden `/Ask`, `/Upload` und unbekannte
  POST-Pfade mit HTTP 503 abgewiesen.
- Bei aktiviertem Forwarding wird `/Ask` nur angenommen, wenn `/health` des
  Windows-Receivers erreichbar ist.
- `/Upload` wird nicht vollstaendig in den Arbeitsspeicher geladen, sondern in
  Chunked-Form an Windows weitergereicht.
- Der Windows-Receiver extrahiert Dateien mit bereinigten Dateinamen und
  flacht Pfade ab, um Pfad-Traversal zu verhindern.
- Debug-Logs enthalten nur Anfragegröße und Plist-Feldnamen, keine Werte,
  Account-Kennungen, Kontakt-Hashes oder Validierungsdatensätze.
- Der Benutzer-`launchd`-Job ist flüchtig und besitzt keine installierte plist.
- Stopp und Fehlerbehandlung entfernen die eigene Bonjour-Registrierung und
  beenden den eigenen `dns-sd`-Kindprozess.

## Verbleibende Risiken

- Das selbstsignierte TLS-Zertifikat authentifiziert keinen Peer und ist nicht
  für einen Produktionsdienst geeignet.
- Der Service ist absichtlich für AirDrop-Peers in Funkreichweite sichtbar.
- Bonjour- und HTTP-Parser können trotz Größenlimits unerwartete Eingaben
  erhalten; der Prozess läuft deshalb ohne erhöhte Rechte.
- Die gemeinsame physische BLE-/AWDL-Identität kann iOS-Deduplizierung oder
  unerwartete Interaktion mit `sharingd` auslösen.
- Bei einer AWDL-Adressrotation besteht während des kontrollierten Neuaufbaus
  ein kurzes Sichtbarkeitsfenster.
- Der Transfer-MVP nutzt fuer Mac-zu-Windows noch HTTP. Er darf nur in einem
  vertrauenswuerdigen LAN oder ueber eine explizit konfigurierte private
  Verbindung getestet werden.
- Das Pairing-Token wird nicht im Repository gespeichert. Wenn
  `WINDROP_PAIRING_TOKEN` gesetzt ist, sendet der Mac es als Header an Windows;
  langfristig muss dies durch TLS mit gegenseitiger Authentifizierung ersetzt
  werden.
- Der Windows-Receiver speichert das eingehende Archiv temporaer auf Disk, bevor
  er extrahiert. Das ist fuer den MVP akzeptabel, aber noch nicht der gewuenschte
  konstante Streaming-Endzustand.

## Vor produktiver Nutzung zwingend

Vor produktiver Nutzung muessen mindestens gegenseitiges Pairing,
TLS-Authentifizierung, zufaellige Transfer-IDs, Anzahl-/Groessenlimits,
Annahme-Timeouts, sichere Dateirechte, vollstaendige Streaming-Backpressure,
garantierte temporaere Bereinigung und Windows-Tray-UI implementiert und
getestet sein. Zugangsdaten, Tokens und private Schluessel duerfen nicht
eingecheckt werden.
