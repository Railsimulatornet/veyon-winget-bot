# Veyon → WinGet Bot (Automatischer PR-Ersteller)

Dieses Repository enthält einen kleinen Bot, der automatisch prüft, ob es eine neue **Veyon**-Version gibt und – falls diese noch nicht im **WinGet-Katalog** (microsoft/winget-pkgs) vorhanden ist – einen Pull Request erstellt.

Hintergrund: Die Veyon-Entwickler erstellen nicht immer zeitnah einen WinGet-Pull-Request. Damit mein eigener **Veyon WinGet Updater** zuverlässig arbeiten kann, übernimmt dieser Bot den PR-Prozess automatisiert.

## Was macht der Bot?
- Prüft regelmäßig die neueste Veyon-Version (GitHub Releases).
- Prüft, ob diese Version bereits als Manifest in `microsoft/winget-pkgs` existiert.
- Wenn **nicht vorhanden**:
  - erzeugt die WinGet-Manifeste mit `wingetcreate`
  - setzt **ReleaseNotesUrl** und **ReleaseDate**
  - prüft (Guard), ob diese Felder wirklich in den Manifesten enthalten sind
  - erstellt anschließend automatisch den Pull Request in `microsoft/winget-pkgs`
- Sendet E-Mail-Benachrichtigungen:
  - wenn ein Update gefunden wurde und der Prozess startet
  - wenn der Prozess fertig ist (success/fail)

## Wie oft läuft das?
- Standardmäßig alle **5 Minuten** per GitHub Actions Schedule (UTC).

## Was passiert bei einer neuen Version?
1. Start-Mail („Update gefunden – PR wird erstellt“)
2. Manifeste werden erzeugt und geprüft (Guard)
3. PR wird erstellt
4. End-Mail mit Status + Link zum Workflow-Run (und ggf. PR-Link)

## Benötigte Secrets (GitHub Actions)
Diese Secrets müssen in den Repository Settings hinterlegt werden:
- `WINGET_CREATE_GITHUB_TOKEN` (PAT für wingetcreate/PR-Erstellung)
- `MAIL_SERVER`
- `MAIL_PORT`
- `MAIL_USERNAME`
- `MAIL_PASSWORD`
- `MAIL_FROM`
- `MAIL_TO`

> Niemals Passwörter oder Tokens in Dateien/Commits ablegen.

## Manuell ausführen
In GitHub unter **Actions** → Workflow auswählen → **Run workflow**.

## Hinweis / Sicherheit
Das Repo ist öffentlich. Secrets werden ausschließlich über GitHub Actions Secrets genutzt. ;-)
