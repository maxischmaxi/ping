# Flurfunk auf Flatpak/Flathub

## Was schon läuft

Die Release-Pipeline baut bei jedem Release ein **Flatpak-Bundle**
(`flurfunk-<version>-x86_64.flatpak`) und hängt es ans GitHub-Release.
Nutzer installieren es ohne Store mit:

```sh
flatpak install --user ./flurfunk-<version>-x86_64.flatpak
flatpak run dev.jeschek.flurfunk
```

Quellen dafür liegen unter `packaging/flatpak/`:

- `dev.jeschek.flurfunk.yml.in` — Manifest-Template (CI setzt Version +
  SHA256 des Linux-Tarballs ein)
- `dev.jeschek.flurfunk.metainfo.xml.in` — AppStream-Metadaten
- `dev.jeschek.flurfunk.desktop` — Desktop-Datei mit Flatpak-App-ID

Sandbox-Rechte (`finish-args`): Netzwerk, X11 + IPC (raylib ist X11),
PulseAudio (Voice), DRI (OpenGL). Mehr braucht die App nicht.

## Warum die Pipeline nicht „zu Flathub deployen" kann

Flathub funktioniert grundlegend anders als Docker Hub oder AUR: Man
pusht keine fertigen Builds. Stattdessen liegt das **Manifest** in einem
Repo unter `github.com/flathub/<app-id>`, und **Flathubs eigene
Build-Infrastruktur** baut daraus für alle Architekturen. Es gibt kein
Token und keine API, mit der eine fremde CI dort etwas veröffentlichen
könnte — die Aufnahme läuft einmalig über einen menschlich geprüften
Pull Request.

## Einmalige Einreichung (das musst du tun)

1. **Screenshot ergänzen**: Flathubs Linter verlangt mindestens einen
   Screenshot in der Metainfo. Screenshot der App öffentlich verfügbar
   machen (z. B. `docs/screenshot.png` im Repo) und in
   `dev.jeschek.flurfunk.metainfo.xml.in` einen `<screenshots>`-Block
   ergänzen.
2. **Konkretes Manifest erzeugen** (Version + SHA einsetzen — die CI tut
   dasselbe; die Werte stehen in der `SHA256SUMS.txt` des Releases):
   ```sh
   sed -e "s/@VERSION@/0.1.1/g" -e "s/@SHA256@/<sha des linux-tarballs>/g" \
     packaging/flatpak/dev.jeschek.flurfunk.yml.in > dev.jeschek.flurfunk.yml
   ```
3. **PR bei Flathub**: <https://github.com/flathub/flathub> forken,
   Branch **von `new-pr` abzweigen** (nicht von master!), das Manifest
   plus Metainfo- und Desktop-Datei einchecken, PR gegen `new-pr`
   stellen. Vorlage/Checkliste:
   <https://docs.flathub.org/docs/for-app-authors/submission>
4. **Review abwarten** (Tage bis Wochen). Wahrscheinliche Rückfragen:
   - *„Bitte aus dem Quellcode bauen"* — Flathub bevorzugt bei
     Open-Source-Apps Source-Builds. Gegenargument: Odin ist in keinem
     Flathub-SDK verfügbar; das Manifest nutzt die offiziellen,
     reproduzierbar per CI gebauten Release-Binaries mit SHA256-Pinning.
     Wird das nicht akzeptiert, wäre der Ausbau ein eigenes
     SDK-Extension-Modul, das den Odin-Compiler baut (machbar, aufwendig).
   - *Verifizierung*: Die App-ID `dev.jeschek.flurfunk` gehört zur Domain
     `jeschek.dev`. Auf Flathub kannst du die App danach als „verified"
     markieren (Settings der App → Token-Datei unter
     `https://jeschek.dev/.well-known/org.flathub.VerifiedApps.txt`).
5. **Nach der Aufnahme**: Flathub legt `github.com/flathub/dev.jeschek.flurfunk`
   an und lädt dich als Maintainer ein. Das Manifest enthält bereits
   `x-checker-data` — Flathubs **external-data-checker** erkennt neue
   GitHub-Releases dann automatisch und stellt Update-PRs, die du nur
   noch mergst. Es sind **keine Secrets und keine Pipeline-Änderungen**
   nötig.

## Lokal testen (auf einem Rechner mit flatpak-builder)

```sh
flatpak install flathub org.freedesktop.Platform//25.08 org.freedesktop.Sdk//25.08
# Manifest wie oben generieren, Metainfo/Desktop-Datei daneben legen, dann:
flatpak-builder --user --force-clean --repo=repo build dev.jeschek.flurfunk.yml
flatpak build-bundle repo flurfunk.flatpak dev.jeschek.flurfunk
flatpak install --user ./flurfunk.flatpak
```
