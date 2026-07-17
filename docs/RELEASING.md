# Flurfunk releasen

Die Release-Pipeline (`.github/workflows/release.yml`) läuft automatisch,
sobald ein `v*`-Tag gepusht wird, der auf `main` liegt. Sie:

1. prüft, dass der Tag auf `main` liegt und zur Version in
   `src/shared/version.odin` passt,
2. legt das GitHub-Release als Pre-Release an,
3. baut **Linux x86_64** (Server + Client, inkl. Headless-Tests:
   Audio-DSP, Protokoll-Smoke, Persistenz) und **macOS arm64**
   (Server + Client + `Flurfunk.app`, signiert und — mit Apple-Secrets —
   notarisiert),
4. hängt die Artefakte ans Release, veröffentlicht es und ergänzt
   `SHA256SUMS.txt`,
5. aktualisiert das AUR-Paket `flurfunk-bin` und (falls
   `HOMEBREW_TAP_TOKEN` gesetzt) die Homebrew-Tap-Formula.

Die Audio-Bibliotheken (opus, rnnoise, speexdsp) werden in der CI statisch
eingelinkt (`packaging/ci/build-audio-deps.sh`) — die Binaries brauchen
auf Linux nur glibc + libX11, auf macOS nur die System-Frameworks.

## Einmalige Einrichtung

### 1. Repo umbenennen

```sh
gh repo rename flurfunk --repo maxischmaxi/ping
git remote set-url origin git@github.com:maxischmaxi/flurfunk.git
```

GitHub leitet die alte URL weiter; Secrets und Actions bleiben erhalten.

### 2. AUR-Schlüssel hinterlegen

Der SSH-Schlüssel liegt unter `~/.ssh/aur_flurfunk` (privat) bzw.
`~/.ssh/aur_flurfunk.pub` (öffentlich); der private Teil ist bereits als
Secret `AUR_SSH_PRIVATE_KEY` im Repo hinterlegt.

Auf <https://aur.archlinux.org> → **My Account** → Feld **SSH Public
Key** → Inhalt von `~/.ssh/aur_flurfunk.pub` eintragen und speichern.

Mehr ist nicht nötig: Der erste Push der Pipeline legt die Paketbasis
`flurfunk-bin` im AUR automatisch an.

### 3. Homebrew-Tap (optional, empfohlen)

Siehe [HOMEBREW.md](HOMEBREW.md) — einmalig Tap-Repo anlegen; mit dem
Secret `HOMEBREW_TAP_TOKEN` aktualisiert die Pipeline die Formula selbst.

### 4. macOS-Signierung und Notarisierung (optional, empfohlen)

Ohne Apple-Secrets signiert die Pipeline ad-hoc — die App läuft, aber
Gatekeeper zeigt beim ersten Start eine Warnung (Nutzer: Rechtsklick →
„Öffnen", oder `xattr -d com.apple.quarantine`). Damit macOS uns als
verifizierten Entwickler erkennt:

1. **Apple Developer Program** beitreten (developer.apple.com, 99 USD/Jahr).
2. **Developer-ID-Zertifikat** erstellen: developer.apple.com →
   Certificates → „Developer ID Application". Den Certificate Signing
   Request erzeugt die Schlüsselbundverwaltung
   (Zertifikatsassistent → „Zertifikat einer Zertifizierungsinstanz
   anfordern"). Zertifikat herunterladen, in den Schlüsselbund
   importieren, dann **mitsamt privatem Schlüssel** als `.p12` mit
   Passwort exportieren.
3. **App-spezifisches Passwort** für die Notarisierung anlegen:
   account.apple.com → Anmeldung & Sicherheit → App-spezifische Passwörter.
4. **Team-ID** ablesen: developer.apple.com → Membership.
5. Secrets setzen:
   ```sh
   base64 -w0 zertifikat.p12 | gh secret set MACOS_CERT_P12 --repo maxischmaxi/flurfunk
   gh secret set MACOS_CERT_PASSWORD --repo maxischmaxi/flurfunk   # .p12-Passwort
   gh secret set APPLE_ID            --repo maxischmaxi/flurfunk   # Apple-ID-Mail
   gh secret set APPLE_TEAM_ID       --repo maxischmaxi/flurfunk
   gh secret set APPLE_APP_PASSWORD  --repo maxischmaxi/flurfunk   # app-spezifisch
   ```

Ab dann werden alle macOS-Binaries mit Developer ID + Hardened Runtime
signiert und `Flurfunk.app` notarisiert und gestapelt — keine
Gatekeeper-Warnung mehr.

## Secrets-Übersicht

| Secret | Pflicht | Zweck | Status |
|--------|---------|-------|--------|
| `AUR_SSH_PRIVATE_KEY` | für AUR | Push nach aur.archlinux.org | ✅ gesetzt |
| `AUR_USERNAME` / `AUR_EMAIL` | für AUR | Commit-Autor der AUR-Commits | ✅ gesetzt |
| `HOMEBREW_TAP_TOKEN` | optional | Formula im Tap aktualisieren | ⬜ |
| `MACOS_CERT_P12` / `MACOS_CERT_PASSWORD` | optional | Developer-ID-Signierung | ⬜ |
| `APPLE_ID` / `APPLE_TEAM_ID` / `APPLE_APP_PASSWORD` | optional | Notarisierung | ⬜ |

## Ein Release durchführen

1. Version in `src/shared/version.odin` setzen (muss zum Tag passen).
2. Änderungen committen und auf `main` pushen.
3. Tag setzen und pushen:
   ```sh
   git tag v0.1.0
   git push origin main v0.1.0
   ```
4. Pipeline beobachten: `gh run watch` oder im Actions-Tab.

Fertig — Binaries liegen im GitHub-Release, AUR und (falls eingerichtet)
Homebrew ziehen nach.

## App-Icon

Quelle liegt unter `assets/icon/` (`flurfunk.svg` = Full-Bleed für
Linux/README/Fenster-Icon, `flurfunk-macos.svg` = Big-Sur-Variante mit
Rand und Schatten). Nach Änderungen `assets/icon/generate.sh` ausführen —
das rendert die PNGs neu und packt `packaging/macos/flurfunk.icns`
(braucht `rsvg-convert` und `python3`). Alle Artefakte sind eingecheckt;
die CI rendert nichts selbst.

## Bekannte Lücken / nächste Schritte

- **macOS Intel / Linux ARM**: bewusst ausgelassen (MVP). Bei Bedarf
  weitere Build-Jobs analog ergänzen.
- **DMG**: Für Nicht-Homebrew-Nutzer wäre ein `.dmg` mit Drag-and-Drop
  nach `/Applications` die rundere Auslieferung (`hdiutil create`).
