# Flurfunk auf Homebrew veröffentlichen

Homebrew kennt zwei Wege: einen **eigenen Tap** (sofort machbar, volle
Kontrolle) und **homebrew-core** (das offizielle Verzeichnis, mit
Aufnahmekriterien). Für den Start nimmst du den Tap — homebrew-core kommt
später, wenn das Projekt Sichtbarkeit hat.

## Weg 1: Eigener Tap (empfohlen für den Start)

Ein „Tap" ist nichts weiter als ein GitHub-Repo mit dem Namen
`homebrew-<name>`, das Formeln enthält. Nutzer binden ihn mit
`brew tap maxischmaxi/tap` ein.

### Schritt 1: Tap-Repo anlegen (einmalig)

```sh
gh repo create maxischmaxi/homebrew-tap --public \
  --description "Homebrew-Tap für Flurfunk"
git clone git@github.com:maxischmaxi/homebrew-tap.git
mkdir -p homebrew-tap/Formula
```

Der Repo-Name **muss** `homebrew-tap` heißen, damit `brew tap
maxischmaxi/tap` funktioniert (brew ergänzt das `homebrew-`-Präfix).

### Schritt 2: Release abwarten

Die Formula verweist auf das macOS-Tarball des GitHub-Releases. Es muss
also erst ein Release existieren (Tag `v0.1.0` pushen, Pipeline laufen
lassen — siehe [RELEASING.md](RELEASING.md)).

### Schritt 3: Formula erzeugen

Die SHA256 des macOS-Tarballs steht in der Datei `SHA256SUMS.txt` des
Releases. Dann aus dem Template in diesem Repo die Formula generieren:

```sh
VERSION=0.1.0
SHA=<sha256 von flurfunk-0.1.0-macos-arm64.tar.gz>
sed -e "s/@VERSION@/$VERSION/g" -e "s/@SHA256_MACOS@/$SHA/g" \
  packaging/homebrew/flurfunk.rb.in > homebrew-tap/Formula/flurfunk.rb
```

### Schritt 4: Prüfen und pushen

```sh
cd homebrew-tap
git add Formula/flurfunk.rb
git commit -m "flurfunk 0.1.0"
git push
```

Danach lokal testen (auf einem Mac):

```sh
brew tap maxischmaxi/tap
brew install flurfunk
brew test flurfunk         # führt den --version-Check der Formula aus
brew audit --strict maxischmaxi/tap/flurfunk
```

Nutzer installieren ab jetzt mit einem einzigen Befehl:

```sh
brew install maxischmaxi/tap/flurfunk
```

Beide Binaries (`flurfunk` und `flurfunk-server`) landen in `$PATH`.
Die Audio-Bibliotheken sind statisch eingelinkt — die Formula hat keine
Laufzeit-Abhängigkeiten.

### Schritt 5 (optional, ab dem zweiten Release): Automatisieren

Die Release-Pipeline enthält bereits einen `homebrew`-Job, der die
Formula im Tap automatisch aktualisiert, sobald das Secret
`HOMEBREW_TAP_TOKEN` existiert:

1. Fine-grained Personal Access Token erstellen
   (github.com → Settings → Developer settings → Fine-grained tokens):
   nur Repo `maxischmaxi/homebrew-tap`, Permission „Contents:
   Read and write".
2. Als Secret hinterlegen:
   ```sh
   gh secret set HOMEBREW_TAP_TOKEN --repo maxischmaxi/flurfunk
   ```

Ab dann pflegt jedes Release den Tap selbst; die Schritte 3–4 entfallen.

## Weg 2: homebrew-core (später)

Das offizielle Verzeichnis (`brew install flurfunk` ohne Tap) nimmt nur
Formeln auf, die **aus dem Quellcode bauen** (keine Binary-Downloads) und
eine gewisse Bekanntheit haben (Stars/Forks werden bei der Review
angeschaut; ein „notability check" läuft automatisch).

Wenn es so weit ist:

1. Source-Build-Formula schreiben: `depends_on "odin" => :build` (Odin ist
   in homebrew-core vorhanden), im `install`-Block `./build.sh` bzw. die
   `odin build`-Aufrufe nachbilden, statische Audio-Libs analog zu
   `packaging/ci/build-audio-deps.sh` als `resource`-Blöcke.
2. `brew audit --new --strict flurfunk` muss sauber durchlaufen.
3. Fork von `Homebrew/homebrew-core`, Formula unter `Formula/f/flurfunk.rb`,
   Pull Request. Die Reviewer melden sich mit Änderungswünschen.

Der eigene Tap bleibt daneben bestehen — er darf weiterhin die schnellere
Binary-Variante ausliefern.
