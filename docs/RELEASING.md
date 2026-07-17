# Flurfunk releasen

Die Release-Pipeline (`.github/workflows/release.yml`) läuft automatisch,
sobald ein `v*`-Tag gepusht wird, der auf `main` liegt. Sie:

1. prüft, dass der Tag auf `main` liegt und zur Version in
   `src/shared/version.odin` passt,
2. legt das GitHub-Release als Pre-Release an,
3. baut **Linux x86_64** (Server + Client, inkl. Headless-Tests:
   Audio-DSP, Protokoll-Smoke, Persistenz), **macOS arm64**
   (Server + Client + `Flurfunk.app`, signiert und — mit Apple-Secrets —
   notarisiert) und ein **Flatpak-Bundle** (aus dem Linux-Tarball,
   `packaging/flatpak/`),
4. hängt die Artefakte ans Release, veröffentlicht es und ergänzt
   `SHA256SUMS.txt`,
5. aktualisiert das AUR-Paket `flurfunk-bin`, pusht das
   **Docker-Image** `flurfunk-server` zu Docker Hub (falls
   Docker-Secrets gesetzt) und aktualisiert die Homebrew-Tap-Formula.

Erneuter Lauf für einen bestehenden Tag (z. B. nachdem ein Secret
nachgetragen wurde), ohne den Tag neu zu setzen:

```sh
gh workflow run release.yml --ref v0.1.1
```

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

### 3. Homebrew-Tap (✅ eingerichtet)

Das Tap `maxischmaxi/homebrew-tap` existiert, die Pipeline aktualisiert
die Formula über den Deploy-Key im Secret `HOMEBREW_TAP_SSH_KEY`
(privater Teil: `~/.ssh/tap_flurfunk`). Details: [HOMEBREW.md](HOMEBREW.md).

### 4. Docker Hub (ein Token nötig)

Der `docker`-Job pusht `docker.io/<username>/flurfunk-server` mit den
Tags `<version>` und `latest`. Er überspringt sich selbst, solange die
Secrets fehlen. Einrichtung:

1. Auf <https://hub.docker.com> → **Account Settings → Personal access
   tokens → Generate new token**: Name z. B. `flurfunk-ci`, Berechtigung
   **Read & Write** (Expiration nach Geschmack).
2. Beide Secrets setzen:
   ```sh
   gh secret set DOCKERHUB_USERNAME -R maxischmaxi/flurfunk
   gh secret set DOCKERHUB_TOKEN    -R maxischmaxi/flurfunk
   ```

Ein `docker login` auf dem eigenen Rechner reicht **nicht** — die
Pipeline braucht ein eigenes Token. PATs lassen sich bei Docker Hub
nicht per API erzeugen, nur im Web-UI.

### 5. Flathub (einmalige Einreichung, keine Secrets)

Das Flatpak-**Bundle** baut die Pipeline ohne weitere Einrichtung. Die
Aufnahme in den **Flathub-Store** läuft über einen einmaligen, menschlich
geprüften PR — eine CI kann dort nichts pushen. Schritte und Details:
[FLATHUB.md](FLATHUB.md).

### 6. macOS-Signierung und Notarisierung (optional, empfohlen)

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
| `HOMEBREW_TAP_SSH_KEY` | für Homebrew | Deploy-Key: Formula im Tap aktualisieren | ✅ gesetzt |
| `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` | für Docker | Image-Push zu Docker Hub | ⬜ |
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

Quelle liegt unter `assets/icon/` (`flurfunk.svg` = FF-Monogramm auf
dunkler Kachel für Linux/Fenster-Icon, `flurfunk-macos.svg` = Big-Sur-
Variante mit Rand und Schatten, `flurfunk-mark.svg` = freistehendes
FF-Monogramm ohne Kachel; die README-Wortmarke liegt als
`assets/flurfunk-readme.png`). Nach Änderungen `assets/icon/generate.sh` ausführen —
das rendert die PNGs neu und packt `packaging/macos/flurfunk.icns`
(braucht `rsvg-convert` und `python3`). Alle Artefakte sind eingecheckt;
die CI rendert nichts selbst.

## Bekannte Lücken / nächste Schritte

- **macOS Intel / Linux ARM**: bewusst ausgelassen (MVP). Bei Bedarf
  weitere Build-Jobs analog ergänzen.
- **DMG**: Für Nicht-Homebrew-Nutzer wäre ein `.dmg` mit Drag-and-Drop
  nach `/Applications` die rundere Auslieferung (`hdiutil create`).
