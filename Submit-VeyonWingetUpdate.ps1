<#
Submit-VeyonWingetUpdate.ps1

Flow (robust):
  1) wingetcreate update -> schreibt Manifeste lokal (kein PR)
  2) Guard: Prüft, dass defaultLocale ReleaseNotesUrl + ReleaseDate enthält
  3) wingetcreate submit -> erstellt PR (nur wenn Guard OK)

CI/CD:
  - Empfohlen: WINGET_CREATE_GITHUB_TOKEN als Env-Var (kein --token im Log)
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$Version,

  [string]$PackageId = "VeyonSolutions.Veyon",
  [string]$Repo      = "veyon/veyon",

  [switch]$NoSubmit,
  [switch]$ForceTokenSetup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-WingetCreateAuth {
  # CI/CD: Wenn Token als Env-Var gesetzt ist, NICHT interaktiv einloggen.
  if (-not $ForceTokenSetup -and $env:WINGET_CREATE_GITHUB_TOKEN -and $env:WINGET_CREATE_GITHUB_TOKEN.Trim().Length -gt 0) {
    Write-Host "CI token detected (WINGET_CREATE_GITHUB_TOKEN). Skipping 'wingetcreate token -s'."
    return
  }

  # Lokal: einmalig token -s, danach Stamp-Datei.
  $stampDir  = Join-Path $env:LOCALAPPDATA "WingetCreate"
  $stampFile = Join-Path $stampDir "token_setup_done.txt"

  if ($ForceTokenSetup) {
    Write-Host "ForceTokenSetup aktiv: führe 'wingetcreate token -s' aus ..."
  } elseif (Test-Path -Path $stampFile -PathType Leaf) {
    Write-Host "Token-Setup bereits durchgeführt (Stamp-Datei vorhanden): $stampFile"
    return
  }

  New-Item -ItemType Directory -Path $stampDir -Force | Out-Null
  Write-Host "Starte einmaliges GitHub-Login für wingetcreate (wingetcreate token -s) ..."
  & wingetcreate token -s
  if ($LASTEXITCODE -ne 0) { throw "wingetcreate token -s fehlgeschlagen (ExitCode $LASTEXITCODE)." }

  "OK $(Get-Date -Format s)" | Out-File -FilePath $stampFile -Encoding utf8 -Force
  Write-Host "Token-Setup abgeschlossen. Stamp-Datei: $stampFile"
}

function Get-VeyonReleaseFromGitHub {
  param(
    [Parameter(Mandatory = $true)] [string]$Repo,
    [Parameter(Mandatory = $true)] [string]$Tag
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
    [Parameter(Mandatory = $true)] [string]$Root,
    [Parameter(Mandatory = $true)] [string]$ManifestType
  )

  $files = Get-ChildItem -Path $Root -Recurse -File -Filter "*.yaml"
  foreach ($f in $files) {
    $txt = Get-Content -Path $f.FullName -Raw
    if ($txt -match "(?m)^\s*ManifestType:\s*$ManifestType\s*$") { return $f.FullName }
  }
  return $null
}

function Assert-ReleaseMetadataPresent {
  param(
    [Parameter(Mandatory = $true)] [string]$DefaultLocalePath
  )

  $txt = Get-Content -Path $DefaultLocalePath -Raw

  if ($txt -notmatch "(?m)^\s*ReleaseNotesUrl:\s*\S+\s*$") {
    throw "Guard fehlgeschlagen: ReleaseNotesUrl fehlt im defaultLocale Manifest: $DefaultLocalePath"
  }

  if ($txt -notmatch "(?m)^\s*ReleaseDate:\s*\d{4}-\d{2}-\d{2}\s*$") {
    throw "Guard fehlgeschlagen: ReleaseDate fehlt/ist ungültig (YYYY-MM-DD) im defaultLocale Manifest: $DefaultLocalePath"
  }
}

# --- Start ---
Ensure-WingetCreateAuth

# Version 4.10.1.0 -> Tag v4.10.1
$verObj = [version]$Version
$tag3   = "v{0}.{1}.{2}" -f $verObj.Major, $verObj.Minor, $verObj.Build
$tag4   = "v$Version"

try { $rel = Get-VeyonReleaseFromGitHub -Repo $Repo -Tag $tag3; $tagUsed = $tag3 }
catch { $rel = Get-VeyonReleaseFromGitHub -Repo $Repo -Tag $tag4; $tagUsed = $tag4 }

$ReleaseNotesUrl = $rel.html_url
$ReleaseDate     = ([DateTimeOffset]$rel.published_at).UtcDateTime.ToString("yyyy-MM-dd")

$assetX86 = $rel.assets | Where-Object { $_.name -match 'win32-setup\.exe$' } | Select-Object -First 1
$assetX64 = $rel.assets | Where-Object { $_.name -match 'win64-setup\.exe$' } | Select-Object -First 1
if (-not $assetX86 -or -not $assetX64) { throw "Konnte win32/win64 Setup-Assets im GitHub Release $tagUsed nicht finden." }

$UrlX86 = $assetX86.browser_download_url
$UrlX64 = $assetX64.browser_download_url

$prTitle = "New version: $PackageId version $Version"

# 1) Erst lokal generieren (kein PR)
$outDir = Join-Path ($env:RUNNER_TEMP ?? $env:TEMP) ("wingetcreate-" + $PackageId + "-" + $Version)
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

Write-Host "Generating manifests to: $outDir"
& wingetcreate update $PackageId `
  --version $Version `
  --urls $UrlX86 $UrlX64 `
  --release-notes-url $ReleaseNotesUrl `
  --release-date $ReleaseDate `
  --out $outDir

if ($LASTEXITCODE -ne 0) { throw "wingetcreate update (generate) fehlgeschlagen (ExitCode $LASTEXITCODE)." }

# 2) Guard: Prüfen, ob defaultLocale ReleaseNotesUrl + ReleaseDate enthält
$defaultLocale = Find-ManifestFileByType -Root $outDir -ManifestType "defaultLocale"
if (-not $defaultLocale) { throw "Guard fehlgeschlagen: defaultLocale Manifest nicht gefunden unter $outDir" }

Assert-ReleaseMetadataPresent -DefaultLocalePath $defaultLocale
Write-Host "Guard OK: ReleaseNotesUrl + ReleaseDate vorhanden in $defaultLocale"

# 3) Submit (nur wenn gewünscht)
if ($NoSubmit) {
  Write-Host "NoSubmit aktiv – kein PR wird erstellt. Manifeste liegen hier: $outDir"
  exit 0
}

$versionManifest = Find-ManifestFileByType -Root $outDir -ManifestType "version"
if (-not $versionManifest) { throw "Submit fehlgeschlagen: version Manifest nicht gefunden unter $outDir" }

Write-Host "Submitting manifest: $versionManifest"
# Token kommt in CI/CD aus WINGET_CREATE_GITHUB_TOKEN (empfohlen), kein --token nötig.
& wingetcreate submit --prtitle $prTitle --no-open $versionManifest

exit $LASTEXITCODE
