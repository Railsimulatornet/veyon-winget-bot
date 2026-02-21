<#
Submit-VeyonWingetUpdate.ps1

CI/CD:
  - Nutzt WINGET_CREATE_GITHUB_TOKEN (kein interaktives Login).
Lokal:
  - Führt einmalig "wingetcreate token -s" aus und legt eine Stamp-Datei ab.

Nutzung:
  .\Submit-VeyonWingetUpdate.ps1 -Version 4.10.1.0
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$Version,

  [string]$PackageId = "VeyonSolutions.Veyon",
  [string]$Repo      = "veyon/veyon",

  [switch]$NoSubmit,
  [switch]$ForceTokenSetup,

  [string]$OutDir = (Join-Path $PWD "winget-manifests")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-WingetCreateAuth {
  # CI/CD: Wenn Token als Env-Var gesetzt ist, NICHT interaktiv einloggen.
  # (Empfohlen für CI/CD: WINGET_CREATE_GITHUB_TOKEN) :contentReference[oaicite:3]{index=3}
  if (-not $ForceTokenSetup -and $env:WINGET_CREATE_GITHUB_TOKEN -and $env:WINGET_CREATE_GITHUB_TOKEN.Trim().Length -gt 0) {
    Write-Host "CI token detected (WINGET_CREATE_GITHUB_TOKEN). Skipping 'wingetcreate token -s'."
    return
  }

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
  if ($LASTEXITCODE -ne 0) {
    throw "wingetcreate token -s ist fehlgeschlagen (ExitCode $LASTEXITCODE)."
  }

  "OK $(Get-Date -Format s)" | Out-File -FilePath $stampFile -Encoding utf8 -Force
  Write-Host "Token-Setup abgeschlossen. Stamp-Datei geschrieben: $stampFile"
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

Ensure-WingetCreateAuth

# Veyon: Version 4.10.1.0 -> Tag v4.10.1
$verObj = [version]$Version
$tag3   = "v{0}.{1}.{2}" -f $verObj.Major, $verObj.Minor, $verObj.Build
$tag4   = "v$Version"

try {
  $rel = Get-VeyonReleaseFromGitHub -Repo $Repo -Tag $tag3
  $tagUsed = $tag3
}
catch {
  $rel = Get-VeyonReleaseFromGitHub -Repo $Repo -Tag $tag4
  $tagUsed = $tag4
}

# ReleaseNotesUrl + ReleaseDate (für Manifest defaultLocale) :contentReference[oaicite:4]{index=4}
$ReleaseNotesUrl = $rel.html_url
$ReleaseDate     = ([DateTimeOffset]$rel.published_at).UtcDateTime.ToString("yyyy-MM-dd")

$assetX86 = $rel.assets | Where-Object { $_.name -match 'win32-setup\.exe$' } | Select-Object -First 1
$assetX64 = $rel.assets | Where-Object { $_.name -match 'win64-setup\.exe$' } | Select-Object -First 1

if (-not $assetX86 -or -not $assetX64) {
  throw "Konnte win32/win64 Setup-Assets im GitHub Release $tagUsed nicht finden."
}

$UrlX86 = $assetX86.browser_download_url
$UrlX64 = $assetX64.browser_download_url

Write-Host "PackageId       : $PackageId"
Write-Host "Version         : $Version"
Write-Host "GitHub Tag      : $tagUsed"
Write-Host "ReleaseDate     : $ReleaseDate"
Write-Host "ReleaseNotesUrl : $ReleaseNotesUrl"
Write-Host "Installer x86   : $UrlX86"
Write-Host "Installer x64   : $UrlX64"

$prTitle = "New version: $PackageId version $Version"

$args = @(
  "update", $PackageId,
  "--version", $Version,
  "--urls", $UrlX86, $UrlX64,
  "--release-notes-url", $ReleaseNotesUrl,
  "--release-date", $ReleaseDate,
  "--prtitle", $prTitle
)

if ($NoSubmit) {
  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
  $args += @("--out", $OutDir)
  Write-Host "Hinweis: -NoSubmit aktiv, Manifeste werden lokal geschrieben nach: $OutDir"
} else {
  $args += @("--submit")
}

& wingetcreate @args
exit $LASTEXITCODE
