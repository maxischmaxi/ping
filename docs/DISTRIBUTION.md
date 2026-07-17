# Weitere Distributionskanäle

Aktuell released Flurfunk auf **GitHub Releases**, **AUR** und
**Homebrew (Tap)**. Diese Liste sammelt Kanäle, über die wir zusätzlich
distributieren sollten oder könnten — grob nach Aufwand/Nutzen sortiert.

## Hohe Priorität (viel Reichweite, überschaubarer Aufwand)

| Kanal | Zielgruppe | Aufwand | Notizen |
|-------|-----------|---------|---------|
| **GHCR / Docker Hub** (Server-Image) — ✅ Docker Hub seit v0.1.1 (`maxischmaxi/flurfunk-server`) | Self-Hoster, Homelabs, NAS | gering | `flurfunk-server` ist ein statisch-freundliches Single-Binary — ideal für ein Mini-Image (`FROM debian:stable-slim` oder distroless). Docker-Compose-Beispiel dazu; öffnet die Tür zu Unraid/CasaOS/Portainer-Katalogen. |
| **Flathub** (Flatpak, Client) — 🔶 Bundle als Release-Asset, Einreichung vorbereitet (docs/FLATHUB.md) | Linux-Desktop generell, auch immutable Distros (Steam Deck, Silverblue) | mittel | Der wichtigste Linux-Desktop-Kanal neben AUR. Braucht Manifest (JSON/YAML), App-ID `dev.jeschek.flurfunk`, AppStream-Metadaten + Icon. Audio läuft über PipeWire/Pulse-Portal problemlos. |
| **homebrew-core** | macOS-Nutzer ohne Tap | mittel | Erst sinnvoll, wenn das Projekt „notable" ist (Stars). Muss aus Quellcode bauen — siehe [HOMEBREW.md](HOMEBREW.md), Weg 2. |

## Mittlere Priorität

| Kanal | Zielgruppe | Aufwand | Notizen |
|-------|-----------|---------|---------|
| **AppImage** | Linux ohne Paketmanager-Zugriff | gering | Ein portables File, gut als zusätzliches Release-Asset. Tooling: `appimagetool`/`linuxdeploy`. Danach Eintrag auf AppImageHub. |
| **Nixpkgs** | NixOS / Nix-Nutzer (wachsend, technikaffin) | mittel | Derivation aus Quellcode (Odin ist in nixpkgs). PR gegen NixOS/nixpkgs; danach `nix run nixpkgs#flurfunk`. |
| **Fedora COPR** | Fedora/RHEL-Familie | mittel | Inoffizielles „AUR von Fedora". RPM-Spec schreiben, COPR baut automatisch pro Release. |
| **openSUSE OBS** | openSUSE, kann aber für viele Distros bauen | mittel | Der Open Build Service erzeugt aus einer Spec Pakete für openSUSE, Fedora, Debian, Ubuntu gleichzeitig — ein Kanal, viele Distros. |
| **Snapcraft** | Ubuntu-Nutzer | mittel | Reichweite auf Ubuntu hoch; Audio/Mikrofon-Interfaces (`audio-record`) müssen deklariert werden. Flatpak zuerst — beides parallel lohnt erst später. |

## Niedrige Priorität / später

| Kanal | Zielgruppe | Aufwand | Notizen |
|-------|-----------|---------|---------|
| **MacPorts** | macOS-Minderheit neben brew | gering | Portfile ähnlich einfach wie AUR; lohnt, sobald Nachfrage da ist. |
| **Debian/Ubuntu-Repo (eigenes APT-Repo oder PPA)** | Server-Admins | mittel | Für `flurfunk-server` auf Debian-Servern interessant; eigenes APT-Repo (z. B. via `aptly`/Cloudsmith) ist flexibler als ein PPA. |
| **Winget / Scoop / Chocolatey** | Windows | — | Erst relevant, wenn der Windows-Port existiert (raylib/miniaudio können es; Voice-Backend testen). Winget zuerst — offiziell und ohne Hosting-Aufwand. |
| **Gentoo GURU / Void / Alpine / FreeBSD Ports / pkgsrc** | Nischen-Distros | gering–mittel | Meist von der Community gepflegt, sobald ein Projekt Nutzer hat. Nicht aktiv anstoßen, aber PRs willkommen heißen. |

## Nicht sinnvoll

- **F-Droid / App Stores (mobil)** — es gibt keinen mobilen Client.
- **npm / PyPI / crates.io** — falsche Ökosysteme (keine Library).

## Empfohlene Reihenfolge

1. **Server-Container auf GHCR** — geringster Aufwand, größter Nutzen für
   Self-Hoster (die Kernzielgruppe).
2. **Flathub** — der Linux-Desktop-Standard neben Arch.
3. **AppImage als Release-Asset** — quasi gratis im bestehenden Workflow.
4. **OBS oder COPR** — deckt die RPM-Welt ab.
5. **homebrew-core + Nixpkgs**, sobald Sichtbarkeit (Stars) da ist.
