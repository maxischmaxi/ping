# Entwicklung

Server und Client sind komplett in [Odin](https://odin-lang.org)
geschrieben, der Client rendert mit raylib (`vendor:raylib`), Audio läuft
über das in Odin mitgelieferte miniaudio. Monorepo: Server, Client und
gemeinsames Protokoll-Package liegen zusammen.

## Bauen

Voraussetzungen: Odin (getestet mit `dev-2026-07`) im `PATH` sowie für
die Voice-Calls die Systembibliotheken **libopus**, **librnnoise** und
**libspeexdsp** (Arch: `pacman -S opus rnnoise speexdsp`). Der Server
linkt zusätzlich gegen **libcurl** (OAuth-Login; Arch: `curl`, Debian:
`libcurl4-openssl-dev`, macOS: im System enthalten). `build.sh`
kompiliert das miniaudio-`.a` aus dem Odin-Vendor beim ersten Lauf
automatisch (braucht `cc`/`make`).

```sh
./build.sh          # Release → bin/flurfunk-server, bin/flurfunk
./build.sh debug    # Debug-Build
```

Release-Builds in der CI linken die drei Audio-Libs statisch
(`packaging/ci/build-audio-deps.sh`) — lokal wird normal dynamisch gegen
die Systembibliotheken gelinkt.

## Starten (Entwicklung)

```sh
bin/flurfunk-server -port 7788 -data ./flurfunk-data
bin/flurfunk
```

### Server-Flags

| Flag | Default | Bedeutung |
|------|---------|-----------|
| `-port <n>` | `7788` | TCP- und UDP-Port |
| `-data <dir>` | `./flurfunk-data` | Datenverzeichnis |
| `-key <pfad>` | `<data>/master.key` | Ort des Master-Keys (z. B. separater Mount/USB-Stick) |
| `-version` | — | Version ausgeben und beenden |

## Repo-Aufbau

```
src/shared/     Wire-Protokoll (JSON), Framing, Noise-Secure-Channel, Voice-Pakete
src/server/     Server: Auth, Channels/DMs, verschlüsselte Persistenz, Voice-SFU
src/client/     raylib-Client: Slack-Layout, Multi-Server, Rich-Text, Call-UI
src/audio/      Voice-DSP: Opus/RNNoise/Speex-Bindings, Jitter-Buffer, Engine
tests/smoke/    Headless-Protokolltest inkl. UDP-SFU + Profilbilder (frischer Server)
tests/persist/  Persistenz-Test (Server-Neustart gegen Smoke-Datenbestand)
tests/audio/    Headless-DSP-Test (Opus-Roundtrip, FEC/PLC, Jitter, VAD, AEC)
tests/avatar/   Headless-Test der Profilbild-Pipeline (PNG-Export/Crop/Resize)
tests/audiodev/ Geräte-Check mit echter Audio-Hardware (nicht für CI)
assets/fonts/   Inter + Liberation Mono (werden ins Client-Binary eingebettet)
packaging/      CI-Buildscripts, PKGBUILD, Homebrew-Formula, macOS-Bundle
docs/           Release-, Homebrew- und Distributions-Doku
```

## Tests

```sh
odin build tests/smoke -out:bin/smoke
odin build tests/persist -out:bin/persist
odin build tests/audio -out:bin/audiotest
odin build tests/avatar -out:bin/avatartest

bin/audiotest                                            # reine DSP-Pipeline
bin/avatartest                                           # Profilbild-Bake-Kette
bin/flurfunk-server -port 7999 -data /tmp/flurfunk-test &  # frisches Datenverzeichnis!
timeout 30 bin/smoke 127.0.0.1:7999
# Server neu starten (gleiches -data), dann:
timeout 30 bin/persist 127.0.0.1:7999
```

## Sicherheitsmodell

Ziel: Wer den Server-Datenbestand in die Hände bekommt (Backup-Leak,
kompromittierte Platte, neugieriger Hoster), kann **keine einzige Nachricht
lesen** — vergleichbar mit Telegrams Cloud-Chats, bei denen Nachrichten
serverseitig verschlüsselt lagern.

- **Transport:** Noise-Protokoll `XX` (X25519 + ChaCha20-Poly1305 + BLAKE2s,
  `core:crypto/noise`). Der Client pinnt den statischen Server-Schlüssel beim
  ersten Verbinden (TOFU, wie SSH) und schlägt Alarm, wenn er sich ändert.
  Es geht also nie Klartext übers Netz, auch ohne TLS/Zertifikate.
- **Voice (UDP):** Audio läuft nicht über TCP (Head-of-Line-Blocking),
  sondern über UDP auf demselben Port. Jedes Paket ist einzeln
  XChaCha20-Poly1305-verschlüsselt unter einem zufälligen **Call-Key**,
  den der Server über den Noise-Kanal an die Teilnehmer verteilt
  (Nonce aus ssrc + Sequenznummer, Header als AAD). Der Server arbeitet
  als SFU: er verifiziert nur das Poly1305-Tag jedes Pakets
  (Absender-Authentizität, Anti-Spoofing) und leitet die verschlüsselten
  Bytes unverändert weiter. Calls sind flüchtig — nichts davon berührt
  die Platte.
- **Speicherung (at rest):** Jede Nachricht wird mit XChaCha20-Poly1305 unter
  einem zufälligen **Channel-Key** verschlüsselt gespeichert. Channel-Keys
  liegen nur „gewrappt" (verschlüsselt unter dem **Master-Key**) auf der
  Platte. Der Master-Key (`master.key`, 32 Byte, `0600`) kann per `-key` auf
  ein separates Medium gelegt werden — dann sind Datenverzeichnis und
  Schlüssel physisch getrennt. Profilbilder liegen ebenfalls verschlüsselt
  (XChaCha20-Poly1305 unter dem Master-Key, User-ID als AAD) in
  `avatars/<id>.bin` — auch Gesichter sind Daten.
- **Passwörter:** Argon2id (64 MiB, 3 Passes) mit zufälligem Salt.
- **Sitzungen:** zufällige 256-Bit-Tokens.
- **Zugangskontrolle:** Wer sich als erste Person registriert, wird
  Administrator. Der Admin kann die Registrierung schließen — danach
  kommen neue Konten nur über einmalige Einladungscodes (8 Zeichen,
  kryptografisch zufällig, optional befristet) oder vorab angelegte
  Konten herein. Der Invite-Check läuft **vor** dem Argon2-Hashing,
  Fehlversuche kosten den Server praktisch nichts.
- **Brute-Force-Schutz (Fail2ban-Prinzip):** Fehlgeschlagene
  Anmelde-/Registrierungsversuche werden pro IP gezählt; wer das
  konfigurierbare Limit im Zeitfenster reißt, wird temporär gesperrt
  (Default: 5 Fehler / 15 min → 30 min Sperre). Admins können IPs
  zusätzlich manuell sperren (temporär oder permanent, `bans.json`).
  Gesperrte IPs werden am TCP-Accept **vor dem Noise-Handshake**
  verworfen und im UDP-Pfad vor jeglichem Parsen — ein Angreifer kann
  den Server nicht einmal Krypto-Arbeit kosten. Zusätzlich hat jede
  Verbindung vor der Anmeldung ein hartes Request-Budget gegen
  Pre-Auth-Spam.
- **Konten-Verwaltung:** Deaktivierte Konten können sich nicht anmelden,
  ihre Sitzungen und offenen Verbindungen werden sofort beendet.
  Passwort-Resets durch den Admin invalidieren alle Sitzungen des
  betroffenen Kontos. Der letzte aktive Admin ist gegen Degradierung
  und Deaktivierung geschützt.

Bewusste MVP-Grenze: Der laufende Server kann Nachrichten entschlüsseln
(nötig für History an neue Channel-Mitglieder) — wie bei Slack/Telegram-
Cloud-Chats. Echtes Ende-zu-Ende (Client-seitige Schlüssel) ist als Ausbau
möglich, weil das Protokoll die Nachrichtentexte bereits als opake Strings
behandelt.

## Releases

Siehe [RELEASING.md](RELEASING.md) (Pipeline, Secrets, macOS-Signierung),
[HOMEBREW.md](HOMEBREW.md) und [DISTRIBUTION.md](DISTRIBUTION.md).
