# Veyon → WinGet Bot

[![WinGet](https://github.com/Railsimulatornet/veyon-winget-bot/actions/workflows/veyon-winget.yml/badge.svg?branch=main)](https://github.com/Railsimulatornet/veyon-winget-bot/actions/workflows/veyon-winget.yml)
[![Security](https://github.com/Railsimulatornet/veyon-winget-bot/actions/workflows/security-validation.yml/badge.svg?branch=main)](https://github.com/Railsimulatornet/veyon-winget-bot/actions/workflows/security-validation.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[Deutsch](#deutsch) · [English](#english)

## Deutsch

Der Bot prüft stabile Veyon-Releases und erstellt bei Bedarf einen Pull Request für [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs). Er erkennt neue Windows-Versionen und bereits veröffentlichte Installer, die nachträglich unter derselben URL ersetzt wurden.

Damit erhält mein Veyon WinGet Updater passende Manifeste und aktuelle Prüfsummen. Die WinGet-Hashprüfung bleibt aktiv; auch automatisch erstellte PRs durchlaufen die reguläre Validierung und Prüfung bei Microsoft.

### Funktionen

- Tatsächliche Installer-Version aus den Dateinamen ermitteln, auch Zwischenbuilds wie `4.10.2.21`.
- Standardmäßig passende win32- und win64-Installer verlangen.
- Version, URL und SHA256-Digest je Architektur mit dem vorhandenen Manifest vergleichen.
- Neue Versions-PRs oder Hashkorrekturen für eine bestehende Version erstellen.
- `ReleaseNotesUrl` und `ReleaseDate` setzen und vor dem Einreichen prüfen.
- Bereits offene PRs erkennen und Duplikate vermeiden.
- Den eigenen WinGet-Fork vor der Manifest-Erzeugung und dem Einreichen synchronisieren.
- Bei einer nötigen WinGet-Aktion eine Start- und Abschlussmail mit Status senden.

### Voraussetzungen

Der Workflow läuft über GitHub Actions. Die Synchronisierung ist auf den Fork `Railsimulatornet/winget-pkgs` und dessen Branch `master` eingestellt. Eigene Commits auf diesem Branch führen zum Abbruch; sie werden nicht automatisch überschrieben. Änderungen an der Fork-Dokumentation deshalb auf einem eigenen Branch halten.

Für lokale Prüfungen brauchst du PowerShell 7. Die CI verwendet die festgelegte WingetCreate-Version `1.12.13.0` und prüft das heruntergeladene Programm sowie dessen Version.

### Konfiguration

Hinterlege die benötigten Werte in den Repository-Einstellungen unter **Secrets and variables → Actions**:

| Secret | Bedeutung |
| --- | --- |
| `WINGET_CREATE_GITHUB_TOKEN` | Classic PAT mit `public_repo` und `workflow` für Fork-Synchronisierung und PR-Erstellung. Der `workflow`-Scope ist auch für die Übernahme geänderter Upstream-Workflows nötig. |
| `MAIL_SERVER` | SMTP-Server |
| `MAIL_PORT` | SMTP-Port; `465` verwendet SMTPS, andere Ports verwenden STARTTLS |
| `MAIL_USERNAME` | Benutzername für den Mailversand |
| `MAIL_PASSWORD` | Passwort für den Mailversand |
| `MAIL_FROM` | Absenderadresse |
| `MAIL_TO` | Empfängeradresse |

Zugangsdaten gehören in GitHub Actions Secrets. Der Mailversand verlangt TLS und prüft das Serverzertifikat.

### Schnellstart

Nach der Einrichtung der Secrets kannst du den Workflow in GitHub unter **Actions → Veyon -> WinGet PR Automation → Run workflow** starten. Maßgeblich ist der Workflow in [veyon-winget.yml](.github/workflows/veyon-winget.yml).

Eine lokale Prüfung ohne PR-Erstellung startest du im Repository-Ordner:

```powershell
pwsh -NoProfile -NonInteractive -File .\Submit-VeyonWingetUpdate.ps1 -CheckOnly
```

`-CheckOnly` prüft die öffentlichen Release- und Manifestdaten. Es reicht keine PR ein.

### Zeitplan und Ablauf

Der Zeitplan `*/5 * * * *` sieht einen Lauf alle fünf Minuten vor. GitHub Actions kann geplante Läufe verzögert ausführen. Zusätzlich sind ein manueller Start und ein `repository_dispatch` mit dem Ereignistyp `veyon_check_now` vorgesehen.

1. Stabile Veyon-Releases und Windows-Installer ermitteln.
2. Vorhandenes WinGet-Manifest laden und URL sowie Asset-Digests vergleichen.
3. Bei einer nötigen Änderung den eigenen Fork mit `microsoft/winget-pkgs:master` synchronisieren.
4. Die Manifeste mit WingetCreate erzeugen.
5. Version, URLs, Architekturen, SHA256-Hashes und Release-Angaben prüfen.
6. Den Pull Request einreichen und den Abschlussstatus per Mail senden.

### Prüfungen und Sicherheit

Der regelmäßige Check verwendet das lesende, repositorygebundene `GITHUB_TOKEN`. Der WinGet-PAT steht ausschließlich den Jobs für Synchronisierung und Einreichen zur Verfügung. Die Mail-Jobs laufen getrennt und erhalten diesen PAT nicht.

Externe Actions sind auf Commit-SHAs festgelegt. Dependabot prüft sie auf Updates. Der [Prüfworkflow](.github/workflows/security-validation.yml) kontrolliert unter anderem PowerShell-Syntax, Syntax des Mail-Skripts, Action-Referenzen und den lesenden `-CheckOnly`-Aufruf.

### Projektdateien

| Datei | Aufgabe |
| --- | --- |
| [Submit-VeyonWingetUpdate.ps1](Submit-VeyonWingetUpdate.ps1) | Releases vergleichen, Manifeste erstellen und PRs einreichen |
| [.github/workflows/veyon-winget.yml](.github/workflows/veyon-winget.yml) | Zeitplan, getrennte Prüf-, Sync-, Submit- und Mail-Jobs |
| [.github/workflows/security-validation.yml](.github/workflows/security-validation.yml) | Prüfungen für Änderungen am Bot |

### Lizenz

[MIT License](LICENSE). Copyright © 2026 Roman Glos.

## English

The bot checks stable Veyon releases and opens a pull request in [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs) when an update is needed. It detects new Windows versions and previously published installers that have been replaced at the same URL.

This provides matching manifests and current checksums for my Veyon WinGet Updater. WinGet hash verification stays enabled; automatically created PRs still go through Microsoft's regular validation and review.

### Features

- Read the actual installer version from its filename, including intermediate builds such as `4.10.2.21`.
- Require matching win32 and win64 installers by default.
- Compare the version, URL and SHA256 digest for each architecture with the existing manifest.
- Create new version PRs or checksum corrections for an existing version.
- Set `ReleaseNotesUrl` and `ReleaseDate` and validate them before submission.
- Detect open PRs and avoid duplicates.
- Synchronize the WinGet fork before generating manifests and submitting a PR.
- Send start and completion emails with the status when a WinGet action is needed.

### Requirements

The workflow runs in GitHub Actions. Fork synchronization is configured for `Railsimulatornet/winget-pkgs` and its `master` branch. Additional commits on that branch stop the process; they are never overwritten automatically. Keep changes to the fork's documentation on a separate branch.

Local checks require PowerShell 7. CI uses the pinned WingetCreate version `1.12.13.0` and verifies both the downloaded program and its version.

### Configuration

Add these values in the repository settings under **Secrets and variables → Actions**:

| Secret | Purpose |
| --- | --- |
| `WINGET_CREATE_GITHUB_TOKEN` | Classic PAT with `public_repo` and `workflow` for fork synchronization and PR submission. The `workflow` scope also allows synchronization when upstream workflow files change. |
| `MAIL_SERVER` | SMTP server |
| `MAIL_PORT` | SMTP port; `465` uses SMTPS, other ports use STARTTLS |
| `MAIL_USERNAME` | SMTP username |
| `MAIL_PASSWORD` | SMTP password |
| `MAIL_FROM` | Sender address |
| `MAIL_TO` | Recipient address |

Store credentials in GitHub Actions Secrets. Email delivery requires TLS and verifies the server certificate.

### Quickstart

After configuring the secrets, open **Actions → Veyon -> WinGet PR Automation → Run workflow** in GitHub. The workflow is defined in [veyon-winget.yml](.github/workflows/veyon-winget.yml).

To check the public data locally without submitting a PR, run this from the repository directory:

```powershell
pwsh -NoProfile -NonInteractive -File .\Submit-VeyonWingetUpdate.ps1 -CheckOnly
```

`-CheckOnly` checks public release and manifest data. It does not submit a PR.

### Schedule and process

The `*/5 * * * *` schedule requests a run every five minutes. GitHub Actions may delay scheduled runs. Manual runs and a `repository_dispatch` event of type `veyon_check_now` are also supported.

1. Identify stable Veyon releases and Windows installers.
2. Load the existing WinGet manifest and compare URLs and asset digests.
3. If a change is needed, synchronize the fork with `microsoft/winget-pkgs:master`.
4. Generate manifests with WingetCreate.
5. Validate the version, URLs, architectures, SHA256 hashes and release metadata.
6. Submit the pull request and send the completion status by email.

### Checks and security

The regular check uses the read-only, repository-scoped `GITHUB_TOKEN`. The WinGet PAT is available only to the synchronization and submission jobs. Email jobs run separately and do not receive this PAT.

External Actions are pinned to commit SHAs and monitored by Dependabot. The [validation workflow](.github/workflows/security-validation.yml) checks PowerShell syntax, mail script syntax, Action references and the read-only `-CheckOnly` command, among other checks.

### Project files

| File | Purpose |
| --- | --- |
| [Submit-VeyonWingetUpdate.ps1](Submit-VeyonWingetUpdate.ps1) | Compare releases, generate manifests and submit PRs |
| [.github/workflows/veyon-winget.yml](.github/workflows/veyon-winget.yml) | Schedule and separate check, sync, submit and email jobs |
| [.github/workflows/security-validation.yml](.github/workflows/security-validation.yml) | Validate changes to the bot |

### License

[MIT License](LICENSE). Copyright © 2026 Roman Glos.
