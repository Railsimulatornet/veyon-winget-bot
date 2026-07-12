# Veyon → WinGet Bot (Automatischer PR-Ersteller)

Dieses Repository enthält einen kleinen Bot, der automatisch prüft, ob es eine neue **Veyon**-Version gibt oder ob ein bereits veröffentlichtes Veyon-Release-Asset unter derselben URL ersetzt wurde. Falls eine WinGet-Aktion nötig ist, erstellt der Bot automatisch einen Pull Request für `microsoft/winget-pkgs`.

Hintergrund: Die Veyon-Entwickler erstellen nicht immer zeitnah einen WinGet-Pull-Request. Außerdem können ersetzte Release-Assets dazu führen, dass der im WinGet-Manifest gespeicherte SHA256-Hash nicht mehr zum aktuellen Installer passt. Damit mein eigener **Veyon WinGet Updater** zuverlässig und ohne Umgehung der Hashprüfung arbeiten kann, übernimmt dieser Bot den PR-Prozess automatisiert.

## Was macht der Bot?

- Prüft regelmäßig die stabilen Veyon-Releases auf GitHub.
- Ermittelt die tatsächliche Windows-Installer-Version aus den Dateinamen, einschließlich Zwischenbuilds wie `4.10.2.21`.
- Verlangt standardmäßig passende win32- und win64-Installer.
- Prüft, ob die Version bereits als Manifest in `microsoft/winget-pkgs` existiert.
- Wenn das Manifest bereits existiert:
  - liest der Bot die aktuellen SHA256-Digests der GitHub-Release-Assets,
  - vergleicht URL und Hash pro Architektur mit dem bestehenden WinGet-Manifest,
  - erkennt dadurch nachträglich ersetzte Installer,
  - erstellt bei einer Abweichung eine Korrektur-PR für dieselbe Version.
- Wenn die Version noch nicht vorhanden ist:
  - erzeugt der Bot die WinGet-Manifeste mit `wingetcreate`,
  - setzt **ReleaseNotesUrl** und **ReleaseDate**,
  - erstellt eine neue Versions-PR.
- Vor dem Submit prüft ein Guard:
  - Version und Installer-URLs,
  - win32-/win64-Vollständigkeit,
  - aktuelle SHA256-Hashes,
  - `ReleaseNotesUrl` und `ReleaseDate`.
- Erkennt bereits offene PRs, damit keine Duplikate erstellt werden.
- Synchronisiert den eigenen `winget-pkgs`-Fork vor dem Submit.
- Sendet E-Mail-Benachrichtigungen beim Start und Abschluss.

## Sicherheit

Die WinGet-Hashprüfung wird nicht umgangen. Wenn Veyon ein Release-Asset unter derselben URL ersetzt, erstellt der Bot stattdessen eine reguläre Korrektur-PR, die weiterhin die Validierungs- und Review-Prozesse von `microsoft/winget-pkgs` durchläuft.

## Wie oft läuft das?

Standardmäßig alle **5 Minuten** per GitHub Actions Schedule (UTC).

## Ablauf

1. Stabile Releases und Windows-Assets ermitteln.
2. Bestehendes WinGet-Manifest laden.
3. Aktuelle Asset-Digests mit den Manifest-Hashes vergleichen.
4. Bei neuer Version oder Hashabweichung Manifeste mit `wingetcreate` erzeugen.
5. Guard ausführen.
6. PR erstellen.
7. End-Mail mit Status und Link zum Workflow-Run versenden.

## Benötigte Secrets (GitHub Actions)

Diese Secrets müssen in den Repository Settings hinterlegt werden:

- `WINGET_CREATE_GITHUB_TOKEN` (Classic PAT mit `public_repo` für `wingetcreate` und PR-Erstellung)
- `MAIL_SERVER`
- `MAIL_PORT`
- `MAIL_USERNAME`
- `MAIL_PASSWORD`
- `MAIL_FROM`
- `MAIL_TO`

> Niemals Passwörter oder Tokens in Dateien oder Commits ablegen.

## Manuell ausführen

In GitHub unter **Actions** → Workflow auswählen → **Run workflow**.

## Hinweis

Da dieses Repository öffentlich ist, werden Secrets ausschließlich über GitHub Actions Secrets genutzt. ;-)
