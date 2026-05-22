<#
Submit-VeyonWingetUpdate.ps1

Flow:

 1) Resolve the real Veyon Windows installer version from GitHub release assets.
    This also supports cases where Veyon publishes an intermediate Windows build
    as an additional asset inside an older release tag, for example:
    veyon-4.10.2.21-win64-setup.exe inside release tag v4.10.2.

 2) Skip safely if the effective version already exists in winget-pkgs
    or if an open PR for that exact version already exists.

 3) wingetcreate update -> writes manifests locally, no PR yet.

 4) Guard:
    - defaultLocale must contain ReleaseNotesUrl
    - installer or defaultLocale must contain ReleaseDate
    - installer URLs must match the effective Veyon installer version

 5) wingetcreate submit -> creates PR only if Guard is OK

CI/CD:

 - Recommended: WINGET_CREATE_GITHUB_TOKEN as Env-Var
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

function Get-GitHubHeaders {
    $headers = @{
        "User-Agent" = "wingetcreate-veyon-update"
        "Accept"     = "application/vnd.github+json"
    }

    if ($env:WINGET_CREATE_GITHUB_TOKEN -and $env:WINGET_CREATE_GITHUB_TOKEN.Trim().Length -gt 0) {
        $headers["Authorization"] = "Bearer $($env:WINGET_CREATE_GITHUB_TOKEN)"
    }

    return $headers
}

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

function Convert-ToSafeVersion {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $match = [regex]::Match($Text, '(?i)(\d+\.\d+\.\d+(?:\.\d+)?)')
    if (-not $match.Success) {
        return $null
    }

    try {
        return [version]$match.Groups[1].Value
    }
    catch {
        return $null
    }
}

function Get-VersionTextFromAssetName {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$AssetName
    )

    if ([string]::IsNullOrWhiteSpace($AssetName)) {
        return $null
    }

    $match = [regex]::Match(
        $AssetName,
        '(?i)^veyon-(\d+\.\d+\.\d+(?:\.\d+)?)-win(?:32|64)-setup\.exe$'
    )

    if ($match.Success) {
        return $match.Groups[1].Value
    }

    return $null
}

function Get-ArchitectureFromAssetName {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$AssetName
    )

    if ([string]::IsNullOrWhiteSpace($AssetName)) {
        return $null
    }

    $match = [regex]::Match(
        $AssetName,
        '(?i)^veyon-\d+\.\d+\.\d+(?:\.\d+)?-win(32|64)-setup\.exe$'
    )

    if ($match.Success) {
        return "win$($match.Groups[1].Value)"
    }

    return $null
}

function Get-VeyonReleaseFromGitHub {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repo,

        [Parameter(Mandatory = $true)]
        [string]$Tag
    )

    $headers = Get-GitHubHeaders
    $uri = "https://api.github.com/repos/$Repo/releases/tags/$Tag"
    return Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 30
}

function Get-VeyonStableReleasesFromGitHub {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repo
    )

    $headers = Get-GitHubHeaders
    $uri = "https://api.github.com/repos/$Repo/releases?per_page=100"
    $releases = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 30

    $stableReleases = @(
        foreach ($release in $releases) {
            if ($release.draft -or $release.prerelease) {
                continue
            }

            $tagVersionMatch = [regex]::Match(
                [string]$release.tag_name,
                '(?i)^v?(\d+\.\d+\.\d+(?:\.\d+)?)$'
            )

            if (-not $tagVersionMatch.Success) {
                continue
            }

            $tagVersionObj = Convert-ToSafeVersion -Text $tagVersionMatch.Groups[1].Value
            if ($null -eq $tagVersionObj) {
                continue
            }

            [pscustomobject]@{
                Release        = $release
                Tag            = [string]$release.tag_name
                TagVersionText = $tagVersionMatch.Groups[1].Value
                TagVersionObj  = $tagVersionObj
            }
        }
    )

    return $stableReleases
}

function Get-InstallerAssetCandidatesFromRelease {
    param(
        [Parameter(Mandatory = $true)]
        $Release
    )

    $items = @()

    foreach ($asset in $Release.assets) {
        $versionText = Get-VersionTextFromAssetName -AssetName ([string]$asset.name)
        if ([string]::IsNullOrWhiteSpace($versionText)) {
            continue
        }

        $versionObj = Convert-ToSafeVersion -Text $versionText
        if ($null -eq $versionObj) {
            continue
        }

        $arch = Get-ArchitectureFromAssetName -AssetName ([string]$asset.name)
        if ([string]::IsNullOrWhiteSpace($arch)) {
            continue
        }

        $items += [pscustomobject]@{
            Release     = $Release
            Tag         = [string]$Release.tag_name
            VersionText = $versionText
            VersionObj  = $versionObj
            Arch        = $arch
            Asset       = $asset
            Name        = [string]$asset.name
            Url         = [string]$asset.browser_download_url
        }
    }

    return $items
}

function New-InstallerAssetSet {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$CandidatesForVersion
    )

    $first = $CandidatesForVersion | Select-Object -First 1

    $assetX86 = $CandidatesForVersion |
        Where-Object { $_.Arch -eq "win32" } |
        Sort-Object Name |
        Select-Object -First 1

    $assetX64 = $CandidatesForVersion |
        Where-Object { $_.Arch -eq "win64" } |
        Sort-Object Name |
        Select-Object -First 1

    if (-not $assetX64) {
        return $null
    }

    $dateSources = @()
    if ($assetX86) {
        if ($assetX86.Asset.updated_at) { $dateSources += [DateTimeOffset]$assetX86.Asset.updated_at }
        elseif ($assetX86.Asset.created_at) { $dateSources += [DateTimeOffset]$assetX86.Asset.created_at }
    }

    if ($assetX64) {
        if ($assetX64.Asset.updated_at) { $dateSources += [DateTimeOffset]$assetX64.Asset.updated_at }
        elseif ($assetX64.Asset.created_at) { $dateSources += [DateTimeOffset]$assetX64.Asset.created_at }
    }

    if ($dateSources.Count -gt 0) {
        $releaseDate = ($dateSources | Sort-Object UtcDateTime -Descending | Select-Object -First 1).UtcDateTime.ToString("yyyy-MM-dd")
    }
    else {
        $releaseDate = ([DateTimeOffset]$first.Release.published_at).UtcDateTime.ToString("yyyy-MM-dd")
    }

    return [pscustomobject]@{
        Tag             = $first.Tag
        Release         = $first.Release
        VersionText     = $first.VersionText
        VersionObj      = $first.VersionObj
        ReleaseNotesUrl = [string]$first.Release.html_url
        ReleaseDate     = $releaseDate
        AssetX86        = $assetX86
        AssetX64        = $assetX64
    }
}

function Resolve-VeyonInstallerAssetSet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repo,

        [Parameter(Mandatory = $true)]
        [string]$RequestedVersion
    )

    $requestedVersionObj = Convert-ToSafeVersion -Text $RequestedVersion
    if ($null -eq $requestedVersionObj) {
        throw "Ungültige Version übergeben: $RequestedVersion"
    }

    $verObj = [version]$RequestedVersion

    $tagCandidates = New-Object System.Collections.Generic.List[string]

    if ($verObj.Build -ge 0) {
        $tagCandidates.Add(("v{0}.{1}.{2}" -f $verObj.Major, $verObj.Minor, $verObj.Build))
    }

    $tagCandidates.Add("v$RequestedVersion")

    $uniqueTags = $tagCandidates | Select-Object -Unique

    Write-Host "Suche passende Veyon-Release-Assets für angeforderte Version: $RequestedVersion"
    Write-Host "Tag-Kandidaten: $($uniqueTags -join ', ')"

    $directCandidates = @()

    foreach ($tag in $uniqueTags) {
        try {
            $release = Get-VeyonReleaseFromGitHub -Repo $Repo -Tag $tag
            $directCandidates += Get-InstallerAssetCandidatesFromRelease -Release $release
        }
        catch {
            Write-Warning "GitHub Release $tag konnte nicht gelesen werden: $($_.Exception.Message)"
        }
    }

    $directMatch = @(
        $directCandidates |
            Where-Object { $_.VersionObj -eq $requestedVersionObj }
    )

    if ($directMatch.Count -gt 0) {
        $set = New-InstallerAssetSet -CandidatesForVersion $directMatch
        if ($set) {
            Write-Host "Passende Installer-Assets für $RequestedVersion gefunden in Release $($set.Tag)."
            return $set
        }

        Write-Warning "Für $RequestedVersion wurden Assets gefunden, aber kein win64 Setup. Fallback auf höchste verfügbare Windows-Installer-Version."
    }

    Write-Warning "Keine direkt passende Windows-Installer-Version für $RequestedVersion gefunden. Scanne stabile Releases nach der höchsten Windows-Setup-Version."

    $stableReleases = Get-VeyonStableReleasesFromGitHub -Repo $Repo
    if (-not $stableReleases -or $stableReleases.Count -eq 0) {
        throw "Es konnten keine stabilen Veyon-Releases über GitHub ermittelt werden."
    }

    $allCandidates = @()

    foreach ($entry in $stableReleases) {
        $allCandidates += Get-InstallerAssetCandidatesFromRelease -Release $entry.Release
    }

    if (-not $allCandidates -or $allCandidates.Count -eq 0) {
        throw "Es konnten keine Windows-Setup-Assets in den stabilen Veyon-Releases gefunden werden."
    }

    $versionGroups = @(
        $allCandidates |
            Group-Object VersionText |
            ForEach-Object {
                $items = @($_.Group)
                $set = New-InstallerAssetSet -CandidatesForVersion $items
                if ($set) {
                    $set
                }
            }
    )

    if (-not $versionGroups -or $versionGroups.Count -eq 0) {
        throw "Es wurden Windows-Setup-Assets gefunden, aber keine Version mit win64 Setup."
    }

    $selected = $versionGroups |
        Sort-Object VersionObj, ReleaseDate -Descending |
        Select-Object -First 1

    Write-Warning "Angeforderte Version $RequestedVersion wird nicht verwendet. Effektive Windows-Installer-Version ist $($selected.VersionText) aus Release $($selected.Tag)."

    return $selected
}

function Test-RawUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    $response = Invoke-WebRequest -Uri $Url -Method Head -SkipHttpErrorCheck -TimeoutSec 30
    return [int]$response.StatusCode
}

function Test-WingetVersionAlreadyPresent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    $rawMaster = "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/v/VeyonSolutions/Veyon/$Version/VeyonSolutions.Veyon.installer.yaml"
    $rawMain   = "https://raw.githubusercontent.com/microsoft/winget-pkgs/main/manifests/v/VeyonSolutions/Veyon/$Version/VeyonSolutions.Veyon.installer.yaml"

    $code = Test-RawUrl -Url $rawMaster
    if ($code -eq 200) {
        Write-Host "Bereits in winget-pkgs vorhanden (master): $Version"
        return $true
    }

    if ($code -ne 404) {
        throw "Unerwarteter HTTP-Status $code für $rawMaster - Abbruch zur Vermeidung von PR-Spam."
    }

    $code2 = Test-RawUrl -Url $rawMain
    if ($code2 -eq 200) {
        Write-Host "Bereits in winget-pkgs vorhanden (main): $Version"
        return $true
    }

    if ($code2 -ne 404) {
        throw "Unerwarteter HTTP-Status $code2 für $rawMain - Abbruch zur Vermeidung von PR-Spam."
    }

    return $false
}

function Find-ExistingOpenPr {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    $headers = Get-GitHubHeaders

    $query = 'repo:microsoft/winget-pkgs is:pr is:open in:title "New version: ' + $PackageId + ' version ' + $Version + '"'
    $encodedQuery = [uri]::EscapeDataString($query)
    $uri = "https://api.github.com/search/issues?q=$encodedQuery&per_page=10"

    Write-Host "Suche nach bestehender offener PR: $query"
    $result = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 30

    if ($result.total_count -gt 0) {
        return $result.items | Select-Object -First 1
    }

    return $null
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

function Assert-InstallerUrlsMatchVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallerPath,

        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    if (-not (Test-Path -Path $InstallerPath -PathType Leaf)) {
        throw "Guard fehlgeschlagen: installer Manifest nicht gefunden: $InstallerPath"
    }

    $txt = Get-Content -Path $InstallerPath -Raw

    $installerUrls = @(
        [regex]::Matches($txt, '(?m)^\s*InstallerUrl:\s*(\S+)\s*$') |
            ForEach-Object { $_.Groups[1].Value }
    )

    if (-not $installerUrls -or $installerUrls.Count -eq 0) {
        throw "Guard fehlgeschlagen: Keine InstallerUrl im installer Manifest gefunden: $InstallerPath"
    }

    foreach ($url in $installerUrls) {
        if ($url -match '(?i)veyon-.*-win(?:32|64)-setup\.exe$') {
            if ($url -notmatch [regex]::Escape("veyon-$Version-")) {
                throw "Guard fehlgeschlagen: InstallerUrl passt nicht zur effektiven Version $Version. URL: $url"
            }
        }
    }

    Write-Host "Guard OK: Installer URLs passen zur effektiven Version $Version"
}

# --- Start ---

Ensure-WingetCreateAuth

$assetSet = Resolve-VeyonInstallerAssetSet -Repo $Repo -RequestedVersion $Version

$EffectiveVersion = $assetSet.VersionText
$ReleaseNotesUrl = $assetSet.ReleaseNotesUrl
$ReleaseDate = $assetSet.ReleaseDate

Write-Host "Angeforderte Version: $Version"
Write-Host "Effektive WinGet-Version: $EffectiveVersion"
Write-Host "GitHub Release Tag: $($assetSet.Tag)"
Write-Host "Release Notes: $ReleaseNotesUrl"
Write-Host "Release Date: $ReleaseDate"

$urls = @()

if ($assetSet.AssetX86) {
    Write-Host "Gefundenes win32 Asset: $($assetSet.AssetX86.Name)"
    $urls += $assetSet.AssetX86.Url
}
else {
    Write-Warning "Kein win32 Setup für Version $EffectiveVersion gefunden. Es wird nur win64 eingereicht."
}

if ($assetSet.AssetX64) {
    Write-Host "Gefundenes win64 Asset: $($assetSet.AssetX64.Name)"
    $urls += $assetSet.AssetX64.Url
}
else {
    throw "Kein win64 Setup für Version $EffectiveVersion gefunden."
}

if ($urls.Count -eq 0) {
    throw "Keine Installer-URLs gefunden."
}

if (Test-WingetVersionAlreadyPresent -Version $EffectiveVersion) {
    Write-Host "Keine neue PR nötig. Version $EffectiveVersion ist bereits in winget-pkgs vorhanden."
    exit 0
}

$existingPr = Find-ExistingOpenPr -PackageId $PackageId -Version $EffectiveVersion
if ($existingPr) {
    Write-Host "Keine neue PR nötig. Bereits offene PR gefunden: $($existingPr.html_url)"
    exit 0
}

$prTitle = "New version: $PackageId version $EffectiveVersion"

# 1) Erst lokal generieren, kein PR
$tempBase = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$outDir = Join-Path $tempBase ("wingetcreate-" + $PackageId + "-" + $EffectiveVersion)

New-Item -ItemType Directory -Path $outDir -Force | Out-Null

Write-Host "Generating manifests to: $outDir"

$updateArgs = @(
    "update",
    $PackageId,
    "--version",
    $EffectiveVersion,
    "--urls"
)

$updateArgs += $urls

$updateArgs += @(
    "--release-notes-url",
    $ReleaseNotesUrl,
    "--release-date",
    $ReleaseDate,
    "--out",
    $outDir
)

& wingetcreate @updateArgs

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
Assert-InstallerUrlsMatchVersion -InstallerPath $installerManifest -Version $EffectiveVersion

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
