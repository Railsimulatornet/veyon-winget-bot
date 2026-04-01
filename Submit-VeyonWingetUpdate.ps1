<#
Submit-VeyonWingetUpdate.ps1

Flow (robust):

 1) wingetcreate update -> schreibt Manifeste lokal (kein PR)

 2) Guard:
    - defaultLocale muss ReleaseNotesUrl enthalten
    - installer muss ReleaseDate enthalten
    - fallback-kompatibel: ReleaseDate wird auch im defaultLocale akzeptiert,
      falls sich das Toolverhalten künftig ändern sollte

 3) wingetcreate submit -> erstellt PR (nur wenn Guard OK)

CI/CD:

 - Empfohlen: WINGET_CREATE_GITHUB_TOKEN als Env-Var (kein --token im Log)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$PackageId = "VeyonSolutions.Veyon",
    [string]$Repo = "veyon/veyon",
    [switch]$NoSubmit,
    [switch]$ForceTokenSetup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-WingetCreateAuth {
    if (-not $ForceTokenSetup -and $env:WINGET_CREATE_GITHUB_TOKEN -and $env:WINGET_CREATE_GITHUB_TOKEN.Trim().Length -gt 0) {
        Write-Host "CI token detected (WINGET_CREATE_GITHUB_TOKEN). Skipping 'wingetcreate token -s'."
        return
    }

    $stampDir = Join-Path $env:LOCALAPPDATA "WingetCreate"
    $stampFile = Join-Path $stampDir "token_setup_done.txt"

    if ($ForceTokenSetup) {
        Write-Host "ForceTokenSetup aktiv: führe 'wingetcreate token -s' aus ..."
    }
    elseif (Test-Path -Path $stampFile -PathType Leaf) {
        Write-Host "Token-Setup bereits durchgeführt (Stamp-Datei vorhanden): $stampFile"
        return
    }

    New-Item -ItemType Directory -Path $stampDir -Force | Out-Null

    Write-Host "Starte einmaliges GitHub-Login für wingetcreate (wingetcreate token -s) ..."
    & wingetcreate token -s

    if ($LASTEXITCODE -ne 0) {
        throw "wingetcreate token -s fehlgeschlagen (ExitCode $LASTEXITCODE)."
    }

    "OK $(Get-Date -Format s)" | Out-File -FilePath $stampFile -Encoding utf8 -Force
    Write-Host "Token-Setup abgeschlossen. Stamp-Datei: $stampFile"
}

function Get-VeyonReleaseFromGitHub {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repo,

        [Parameter(Mandatory = $true)]
        [string]$Tag
    )

    $headers = @{
        "User-Agent" = "wingetcreate-veyon-update"
        "Accept"     = "application/vnd.github+json"
    }

    $uri = "https://api.github.com/repos/$Repo/releases/tags/$Tag"
    return Invoke-RestMethod -Uri $uri -Headers $headers
}

function Find-ManifestFileByType {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$ManifestType
    )

    $files = Get-ChildItem -Path $Root -Recurse -File -Filter "*.yaml"
    foreach ($f in $files) {
        $txt = Get-Content -Path $f.FullName -Raw
        if ($txt -match "(?m)^\s*ManifestType:\s*$ManifestType\s*$") {
            return $f.FullName
        }
    }

    return $null
}

function Test-ManifestField {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Regex
    )

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        return $false
    }

    $txt = Get-Content -Path $Path -Raw
    return ($txt -match $Regex)
}

function Assert-ReleaseMetadataPresent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DefaultLocalePath,

        [Parameter(Mandatory = $true)]
        [string]$InstallerPath
    )

    $hasReleaseNotesUrl = Test-ManifestField `
        -Path $DefaultLocalePath `
        -Regex "(?m)^\s*ReleaseNotesUrl:\s*\S+\s*$"

    if (-not $hasReleaseNotesUrl) {
        throw "Guard fehlgeschlagen: ReleaseNotesUrl fehlt im defaultLocale Manifest: $DefaultLocalePath"
    }

    $hasReleaseDateInInstaller = Test-ManifestField `
        -Path $InstallerPath `
        -Regex "(?m)^\s*ReleaseDate:\s*\d{4}-\d{2}-\d{2}\s*$"

    $hasReleaseDateInDefaultLocale = Test-ManifestField `
        -Path $DefaultLocalePath `
        -Regex "(?m)^\s*ReleaseDate:\s*\d{4}-\d{2}-\d{2}\s*$"

    if (-not $hasReleaseDateInInstaller -and -not $hasReleaseDateInDefaultLocale) {
        throw "Guard fehlgeschlagen: ReleaseDate fehlt/ist ungültig (YYYY-MM-DD). Weder im installer Manifest noch im defaultLocale Manifest gefunden. Installer: $InstallerPath | defaultLocale: $DefaultLocalePath"
    }
}

# --- Start ---

Ensure-WingetCreateAuth

# Version 4.10.2.0 -> bevorzugt Tag v4.10.2, fallback v4.10.2.0
$verObj = [version]$Version
$tag3 = "v{0}.{1}.{2}" -f $verObj.Major, $verObj.Minor, $verObj.Build
$tag4 = "v$Version"

try {
    $rel = Get-VeyonReleaseFromGitHub -Repo $Repo -Tag $tag3
    $tagUsed = $tag3
}
catch {
    $rel = Get-VeyonReleaseFromGitHub -Repo $Repo -Tag $tag4
    $tagUsed = $tag4
}

$ReleaseNotesUrl = $rel.html_url
$ReleaseDate = ([DateTimeOffset]$rel.published_at).UtcDateTime.ToString("yyyy-MM-dd")

$assetX86 = $rel.assets | Where-Object { $_.name -match 'win32-setup\.exe$' } | Select-Object -First 1
$assetX64 = $rel.assets | Where-Object { $_.name -match 'win64-setup\.exe$' } | Select-Object -First 1

if (-not $assetX86 -or -not $assetX64) {
    throw "Konnte win32/win64 Setup-Assets im GitHub Release $tagUsed nicht finden."
}

$UrlX86 = $assetX86.browser_download_url
$UrlX64 = $assetX64.browser_download_url

$prTitle = "New version: $PackageId version $Version"

# 1) Erst lokal generieren (kein PR)
$tempBase = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$outDir = Join-Path $tempBase ("wingetcreate-" + $PackageId + "-" + $Version)

New-Item -ItemType Directory -Path $outDir -Force | Out-Null

Write-Host "Generating manifests to: $outDir"

& wingetcreate update $PackageId `
    --version $Version `
    --urls $UrlX86 $UrlX64 `
    --release-notes-url $ReleaseNotesUrl `
    --release-date $ReleaseDate `
    --out $outDir

if ($LASTEXITCODE -ne 0) {
    throw "wingetcreate update (generate) fehlgeschlagen (ExitCode $LASTEXITCODE)."
}

# 2) Guard
$defaultLocale = Find-ManifestFileByType -Root $outDir -ManifestType "defaultLocale"
if (-not $defaultLocale) {
    throw "Guard fehlgeschlagen: defaultLocale Manifest nicht gefunden unter $outDir"
}

$installerManifest = Find-ManifestFileByType -Root $outDir -ManifestType "installer"
if (-not $installerManifest) {
    throw "Guard fehlgeschlagen: installer Manifest nicht gefunden unter $outDir"
}

Assert-ReleaseMetadataPresent -DefaultLocalePath $defaultLocale -InstallerPath $installerManifest

Write-Host "Guard OK: ReleaseNotesUrl vorhanden in $defaultLocale"
Write-Host "Guard OK: ReleaseDate vorhanden in $installerManifest oder fallback im defaultLocale"

# 3) Submit
if ($NoSubmit) {
    Write-Host "NoSubmit aktiv - kein PR wird erstellt. Manifeste liegen hier: $outDir"
    exit 0
}

$versionManifest = Find-ManifestFileByType -Root $outDir -ManifestType "version"
if (-not $versionManifest) {
    throw "Submit fehlgeschlagen: version Manifest nicht gefunden unter $outDir"
}

# WICHTIG:
# Für Multi-File-Manifeste nicht die einzelne *.yaml submitten,
# sondern den Versionsordner mit allen Manifestdateien.
$manifestDir = Split-Path -Parent $versionManifest

if (-not (Test-Path -Path $manifestDir -PathType Container)) {
    throw "Submit fehlgeschlagen: Manifest-Verzeichnis nicht gefunden: $manifestDir"
}

Write-Host "Submitting manifest directory: $manifestDir"

# Kein abschließender Backslash anhängen.
& wingetcreate submit --prtitle $prTitle --no-open $manifestDir

if ($LASTEXITCODE -ne 0) {
    throw "wingetcreate submit fehlgeschlagen (ExitCode $LASTEXITCODE)."
}

exit 0
