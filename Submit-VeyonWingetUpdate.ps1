<#
Submit-VeyonWingetUpdate.ps1

Flow:

 1) Read all stable Veyon GitHub releases.
 2) Detect real Windows installer versions from asset filenames:
      veyon-4.10.2.21-win64-setup.exe
      veyon-4.10.3.0-win32-setup.exe
      veyon-4.10.3.0-win64-setup.exe

 3) Intermediate versions are supported, but only if the asset version belongs
    to the release base:
      Release v4.10.2 -> allowed: 4.10.2.0, 4.10.2.21
      Release v4.10.3 -> allowed: 4.10.3.0, 4.10.3.x
      Release v4.3.1  -> not allowed: 4.99.0.171

 4) Automatic PR creation requires win32 and win64 setup assets by default.
    This avoids wingetcreate update failures caused by a different number of
    installer URLs compared to the existing manifest.

 5) CheckOnly mode is used by GitHub Actions to decide whether a PR is needed.

 6) Before submitting, the script tries to sync the authenticated user's
    microsoft/winget-pkgs fork with upstream. This prevents wingetcreate submit
    failures caused by an outdated fork.

CI/CD:

 - Recommended: WINGET_CREATE_GITHUB_TOKEN as Env-Var.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [string]$Version = "",

    [string]$PackageId = "VeyonSolutions.Veyon",
    [string]$Repo = "veyon/veyon",

    [switch]$CheckOnly,
    [switch]$NoSubmit,
    [switch]$ForceTokenSetup,
    [switch]$AllowSingleArchitecture,
    [switch]$SkipForkSync
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-ActionOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        $Value = ""
    }

    if ($env:GITHUB_OUTPUT) {
        "$Name=$Value" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    }
}

function Write-CheckOutputs {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NeedsUpdate,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Version,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Tag,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$NotesUrl,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$ReleaseDate,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$ExistingPrUrl,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Reason
    )

    Write-ActionOutput -Name "needsUpdate" -Value $NeedsUpdate
    Write-ActionOutput -Name "version" -Value $Version
    Write-ActionOutput -Name "tag" -Value $Tag
    Write-ActionOutput -Name "notesUrl" -Value $NotesUrl
    Write-ActionOutput -Name "releaseDate" -Value $ReleaseDate
    Write-ActionOutput -Name "existingPrUrl" -Value $ExistingPrUrl
    Write-ActionOutput -Name "reason" -Value $Reason
}

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

function Invoke-GitHubRest {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Get", "Post")]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Body = $null
    )

    $headers = Get-GitHubHeaders

    if ($null -ne $Body) {
        $jsonBody = $Body | ConvertTo-Json -Depth 20
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -ContentType "application/json" -Body $jsonBody -TimeoutSec 60
    }

    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -TimeoutSec 60
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

function Convert-ToVersionText4 {
    param(
        [Parameter(Mandatory = $true)]
        [version]$VersionObject
    )

    if ($VersionObject.Build -lt 0) {
        throw "Version muss mindestens drei Segmente enthalten: $VersionObject"
    }

    if ($VersionObject.Revision -ge 0) {
        return "{0}.{1}.{2}.{3}" -f $VersionObject.Major, $VersionObject.Minor, $VersionObject.Build, $VersionObject.Revision
    }

    return "{0}.{1}.{2}.0" -f $VersionObject.Major, $VersionObject.Minor, $VersionObject.Build
}

function Get-VersionTextFromTag {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tag
    )

    $match = [regex]::Match($Tag, '(?i)^v?(\d+\.\d+\.\d+(?:\.\d+)?)$')
    if ($match.Success) {
        return $match.Groups[1].Value
    }

    return $null
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

function Test-AssetVersionBelongsToReleaseBase {
    param(
        [Parameter(Mandatory = $true)]
        [version]$AssetVersion,

        [Parameter(Mandatory = $true)]
        [version]$ReleaseTagVersion
    )

    return (
        $AssetVersion.Major -eq $ReleaseTagVersion.Major -and
        $AssetVersion.Minor -eq $ReleaseTagVersion.Minor -and
        $AssetVersion.Build -eq $ReleaseTagVersion.Build
    )
}

function Get-VeyonStableReleasesFromGitHub {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repo
    )

    $uri = "https://api.github.com/repos/$Repo/releases?per_page=100"

    Write-Host "Lese stabile Veyon GitHub Releases: $uri"

    $releases = Invoke-GitHubRest -Method Get -Uri $uri

    $stableReleases = @(
        foreach ($release in $releases) {
            if ($release.draft -or $release.prerelease) {
                continue
            }

            $tagVersionText = Get-VersionTextFromTag -Tag ([string]$release.tag_name)
            if ([string]::IsNullOrWhiteSpace($tagVersionText)) {
                continue
            }

            $tagVersionObj = Convert-ToSafeVersion -Text $tagVersionText
            if ($null -eq $tagVersionObj) {
                continue
            }

            [pscustomobject]@{
                Release        = $release
                Tag            = [string]$release.tag_name
                TagVersionText = $tagVersionText
                TagVersionObj  = $tagVersionObj
            }
        }
    )

    if (-not $stableReleases -or $stableReleases.Count -eq 0) {
        throw "Es konnten keine stabilen Veyon-Releases über GitHub ermittelt werden."
    }

    return $stableReleases
}

function Get-InstallerAssetCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$StableReleases
    )

    $items = @()

    foreach ($entry in $StableReleases) {
        foreach ($asset in $entry.Release.assets) {
            $assetName = [string]$asset.name

            $assetVersionTextRaw = Get-VersionTextFromAssetName -AssetName $assetName
            if ([string]::IsNullOrWhiteSpace($assetVersionTextRaw)) {
                continue
            }

            $assetVersionObjRaw = Convert-ToSafeVersion -Text $assetVersionTextRaw
            if ($null -eq $assetVersionObjRaw) {
                continue
            }

            if (-not (Test-AssetVersionBelongsToReleaseBase -AssetVersion $assetVersionObjRaw -ReleaseTagVersion $entry.TagVersionObj)) {
                Write-Warning "Ignoriere unpassendes Asset '$assetName' in Release $($entry.Tag): Asset-Version passt nicht zur Release-Basis."
                continue
            }

            $arch = Get-ArchitectureFromAssetName -AssetName $assetName
            if ([string]::IsNullOrWhiteSpace($arch)) {
                continue
            }

            $versionText4 = Convert-ToVersionText4 -VersionObject $assetVersionObjRaw
            $versionObj4 = [version]$versionText4

            $items += [pscustomobject]@{
                Release         = $entry.Release
                Tag             = $entry.Tag
                TagVersionText  = $entry.TagVersionText
                TagVersionObj   = $entry.TagVersionObj
                VersionText     = $versionText4
                VersionObj      = $versionObj4
                Arch            = $arch
                Asset           = $asset
                Name            = $assetName
                Url             = [string]$asset.browser_download_url
            }
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

    $dateSources = @()

    foreach ($candidate in @($assetX86, $assetX64)) {
        if ($null -eq $candidate) {
            continue
        }

        if ($candidate.Asset.updated_at) {
            $dateSources += [DateTimeOffset]$candidate.Asset.updated_at
        }
        elseif ($candidate.Asset.created_at) {
            $dateSources += [DateTimeOffset]$candidate.Asset.created_at
        }
    }

    if ($dateSources.Count -gt 0) {
        $releaseDate = ($dateSources | Sort-Object UtcDateTime -Descending | Select-Object -First 1).UtcDateTime.ToString("yyyy-MM-dd")
    }
    else {
        $releaseDate = ([DateTimeOffset]$first.Release.published_at).UtcDateTime.ToString("yyyy-MM-dd")
    }

    return [pscustomobject]@{
        Tag                  = $first.Tag
        Release              = $first.Release
        VersionText          = $first.VersionText
        VersionObj           = $first.VersionObj
        ReleaseNotesUrl      = [string]$first.Release.html_url
        ReleaseDate          = $releaseDate
        AssetX86             = $assetX86
        AssetX64             = $assetX64
        HasX86               = ($null -ne $assetX86)
        HasX64               = ($null -ne $assetX64)
        HasBothArchitectures = (($null -ne $assetX86) -and ($null -ne $assetX64))
    }
}

function Get-VeyonInstallerAssetSets {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repo
    )

    $stableReleases = Get-VeyonStableReleasesFromGitHub -Repo $Repo
    $candidates = Get-InstallerAssetCandidates -StableReleases $stableReleases

    if (-not $candidates -or $candidates.Count -eq 0) {
        throw "Es konnten keine gültigen Veyon Windows-Setup-Assets gefunden werden."
    }

    $sets = @(
        $candidates |
            Group-Object VersionText |
            ForEach-Object {
                New-InstallerAssetSet -CandidatesForVersion @($_.Group)
            }
    )

    if (-not $sets -or $sets.Count -eq 0) {
        throw "Es konnten keine gültigen Veyon Windows-Installer-Sets gebildet werden."
    }

    return @(
        $sets |
            Sort-Object `
                @{ Expression = { $_.VersionObj }; Descending = $true },
                @{ Expression = { $_.ReleaseDate }; Descending = $true }
    )
}

function Resolve-VeyonInstallerAssetSet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repo,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$RequestedVersion,

        [switch]$AllowSingleArchitecture
    )

    $sets = Get-VeyonInstallerAssetSets -Repo $Repo
    $highestDetected = $sets | Select-Object -First 1

    Write-Host "Höchste erkannte Windows-Setup-Version: $($highestDetected.VersionText) aus Release $($highestDetected.Tag)"
    Write-Host "Architekturen: win32=$($highestDetected.HasX86), win64=$($highestDetected.HasX64)"

    if (-not $highestDetected.HasBothArchitectures -and -not $AllowSingleArchitecture) {
        Write-Warning "Höchste erkannte Version $($highestDetected.VersionText) ist unvollständig. Für automatische PRs werden win32 und win64 benötigt."
    }

    if (-not [string]::IsNullOrWhiteSpace($RequestedVersion)) {
        $requestedVersionObjRaw = Convert-ToSafeVersion -Text $RequestedVersion
        if ($null -eq $requestedVersionObjRaw) {
            throw "Ungültige Version übergeben: $RequestedVersion"
        }

        $requestedVersionText4 = Convert-ToVersionText4 -VersionObject $requestedVersionObjRaw

        $selectedByRequest = $sets |
            Where-Object { $_.VersionText -eq $requestedVersionText4 } |
            Select-Object -First 1

        if (-not $selectedByRequest) {
            throw "Angeforderte Version $requestedVersionText4 wurde nicht als gültiges Windows-Setup-Asset gefunden."
        }

        if (-not $selectedByRequest.HasX64) {
            throw "Angeforderte Version $requestedVersionText4 hat kein win64 Setup."
        }

        if (-not $AllowSingleArchitecture -and -not $selectedByRequest.HasBothArchitectures) {
            throw "Angeforderte Version $requestedVersionText4 ist unvollständig. Gefunden: win32=$($selectedByRequest.HasX86), win64=$($selectedByRequest.HasX64). Automatischer PR wird abgebrochen."
        }

        return [pscustomobject]@{
            Selected        = $selectedByRequest
            HighestDetected = $highestDetected
        }
    }

    $eligibleSets = if ($AllowSingleArchitecture) {
        @($sets | Where-Object { $_.HasX64 })
    }
    else {
        @($sets | Where-Object { $_.HasBothArchitectures })
    }

    if (-not $eligibleSets -or $eligibleSets.Count -eq 0) {
        throw "Es wurde keine einreichbare Veyon-Version gefunden. Erforderlich: win64 plus standardmäßig win32."
    }

    $selected = $eligibleSets | Select-Object -First 1

    if ($selected.VersionText -ne $highestDetected.VersionText) {
        Write-Warning "Die höchste erkannte Version $($highestDetected.VersionText) wird nicht eingereicht. Ausgewählt wurde die höchste vollständige Version $($selected.VersionText)."
    }

    return [pscustomobject]@{
        Selected        = $selected
        HighestDetected = $highestDetected
    }
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

    $query = 'repo:microsoft/winget-pkgs is:pr is:open in:title "New version: ' + $PackageId + ' version ' + $Version + '"'
    $encodedQuery = [uri]::EscapeDataString($query)
    $uri = "https://api.github.com/search/issues?q=$encodedQuery&per_page=10"

    Write-Host "Suche nach bestehender offener PR: $query"
    $result = Invoke-GitHubRest -Method Get -Uri $uri

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
        [string]$Version,

        [switch]$AllowSingleArchitecture
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

    $escapedVersion = [regex]::Escape($Version)
    $hasWin32 = ($installerUrls | Where-Object { $_ -match "(?i)veyon-$escapedVersion-win32-setup\.exe" } | Select-Object -First 1)
    $hasWin64 = ($installerUrls | Where-Object { $_ -match "(?i)veyon-$escapedVersion-win64-setup\.exe" } | Select-Object -First 1)

    if (-not $hasWin64) {
        throw "Guard fehlgeschlagen: win64 InstallerUrl fehlt für Version $Version."
    }

    if (-not $AllowSingleArchitecture -and -not $hasWin32) {
        throw "Guard fehlgeschlagen: win32 InstallerUrl fehlt für Version $Version. Automatische PRs erwarten win32 und win64."
    }

    Write-Host "Guard OK: Installer URLs passen zur effektiven Version $Version"
}

function Get-AuthenticatedGitHubLogin {
    if (-not $env:WINGET_CREATE_GITHUB_TOKEN -or $env:WINGET_CREATE_GITHUB_TOKEN.Trim().Length -eq 0) {
        return $null
    }

    try {
        $user = Invoke-GitHubRest -Method Get -Uri "https://api.github.com/user"
        return [string]$user.login
    }
    catch {
        Write-Warning "GitHub-Benutzer konnte über den Token nicht ermittelt werden: $($_.Exception.Message)"
        return $null
    }
}

function Sync-WingetPkgsFork {
    param(
        [switch]$Required
    )

    if ($SkipForkSync) {
        Write-Host "Fork-Sync übersprungen, weil -SkipForkSync gesetzt ist."
        return $false
    }

    if (-not $env:WINGET_CREATE_GITHUB_TOKEN -or $env:WINGET_CREATE_GITHUB_TOKEN.Trim().Length -eq 0) {
        Write-Warning "Fork-Sync übersprungen: WINGET_CREATE_GITHUB_TOKEN ist nicht gesetzt."
        return $false
    }

    $login = Get-AuthenticatedGitHubLogin
    if ([string]::IsNullOrWhiteSpace($login)) {
        if ($Required) {
            throw "Fork-Sync fehlgeschlagen: GitHub-Login konnte nicht ermittelt werden."
        }

        return $false
    }

    $forkFullName = "$login/winget-pkgs"
    Write-Host "Prüfe WinGet-Fork: $forkFullName"

    try {
        $fork = Invoke-GitHubRest -Method Get -Uri "https://api.github.com/repos/$forkFullName"
    }
    catch {
        $message = $_.Exception.Message
        Write-Warning "WinGet-Fork $forkFullName konnte nicht gelesen werden: $message"
        Write-Warning "Falls der Fork noch nicht existiert, muss wingetcreate ihn beim ersten Submit erstellen oder du legst ihn manuell an."
        return $false
    }

    $branch = [string]$fork.default_branch
    if ([string]::IsNullOrWhiteSpace($branch)) {
        $branch = "master"
    }

    Write-Host "Synchronisiere WinGet-Fork $forkFullName, Branch: $branch"

    try {
        $syncResult = Invoke-GitHubRest `
            -Method Post `
            -Uri "https://api.github.com/repos/$forkFullName/merge-upstream" `
            -Body @{ branch = $branch }

        if ($syncResult.message) {
            Write-Host "Fork-Sync Ergebnis: $($syncResult.message)"
        }
        else {
            Write-Host "Fork-Sync abgeschlossen."
        }

        Start-Sleep -Seconds 5
        return $true
    }
    catch {
        $message = $_.Exception.Message
        Write-Warning "Fork-Sync über GitHub API fehlgeschlagen: $message"

        if ($Required) {
            throw "Fork-Sync fehlgeschlagen. Bitte den Fork $forkFullName manuell mit microsoft/winget-pkgs synchronisieren."
        }

        return $false
    }
}

function Invoke-WingetCreateSubmitWithForkSync {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestDir,

        [Parameter(Mandatory = $true)]
        [string]$PrTitle
    )

    Sync-WingetPkgsFork | Out-Null

    Write-Host "Submitting manifest directory: $ManifestDir"

    & wingetcreate submit --prtitle $PrTitle --no-open $ManifestDir
    $submitExitCode = $LASTEXITCODE

    if ($submitExitCode -eq 0) {
        return
    }

    Write-Warning "wingetcreate submit ist fehlgeschlagen (ExitCode $submitExitCode). Versuche einmalig einen erneuten Fork-Sync und Submit-Retry."

    Sync-WingetPkgsFork -Required | Out-Null

    & wingetcreate submit --prtitle $PrTitle --no-open $ManifestDir
    $submitExitCode = $LASTEXITCODE

    if ($submitExitCode -ne 0) {
        throw "wingetcreate submit fehlgeschlagen (ExitCode $submitExitCode)."
    }
}

# --- Start ---

if ($CheckOnly) {
    Write-Host "CheckOnly aktiv - es wird nur geprüft, ob eine neue PR nötig ist."

    $resolution = Resolve-VeyonInstallerAssetSet -Repo $Repo -RequestedVersion $Version -AllowSingleArchitecture:$AllowSingleArchitecture
    $assetSet = $resolution.Selected
    $highestDetected = $resolution.HighestDetected

    $reasonParts = @()

    if ($highestDetected.VersionText -ne $assetSet.VersionText) {
        $reasonParts += "Höchste erkannte Version $($highestDetected.VersionText) wurde nicht ausgewählt, weil sie unvollständig ist oder nicht einreichbar ist."
    }

    $reasonParts += "Ausgewählte einreichbare Version: $($assetSet.VersionText) aus Release $($assetSet.Tag)."

    if (Test-WingetVersionAlreadyPresent -Version $assetSet.VersionText) {
        $reasonParts += "Version ist bereits in winget-pkgs vorhanden."

        Write-CheckOutputs `
            -NeedsUpdate "false" `
            -Version $assetSet.VersionText `
            -Tag $assetSet.Tag `
            -NotesUrl $assetSet.ReleaseNotesUrl `
            -ReleaseDate $assetSet.ReleaseDate `
            -ExistingPrUrl "" `
            -Reason ($reasonParts -join " ")

        exit 0
    }

    $existingPr = Find-ExistingOpenPr -PackageId $PackageId -Version $assetSet.VersionText
    if ($existingPr) {
        $reasonParts += "Es existiert bereits eine offene PR: $($existingPr.html_url)"

        Write-CheckOutputs `
            -NeedsUpdate "false" `
            -Version $assetSet.VersionText `
            -Tag $assetSet.Tag `
            -NotesUrl $assetSet.ReleaseNotesUrl `
            -ReleaseDate $assetSet.ReleaseDate `
            -ExistingPrUrl $existingPr.html_url `
            -Reason ($reasonParts -join " ")

        exit 0
    }

    $reasonParts += "Version ist noch nicht in winget-pkgs vorhanden und es wurde keine offene PR gefunden."

    Write-CheckOutputs `
        -NeedsUpdate "true" `
        -Version $assetSet.VersionText `
        -Tag $assetSet.Tag `
        -NotesUrl $assetSet.ReleaseNotesUrl `
        -ReleaseDate $assetSet.ReleaseDate `
        -ExistingPrUrl "" `
        -Reason ($reasonParts -join " ")

    exit 0
}

Ensure-WingetCreateAuth

$resolution = Resolve-VeyonInstallerAssetSet -Repo $Repo -RequestedVersion $Version -AllowSingleArchitecture:$AllowSingleArchitecture
$assetSet = $resolution.Selected

$EffectiveVersion = $assetSet.VersionText
$ReleaseNotesUrl = $assetSet.ReleaseNotesUrl
$ReleaseDate = $assetSet.ReleaseDate

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
    if (-not $AllowSingleArchitecture) {
        throw "Kein win32 Setup für Version $EffectiveVersion gefunden. Automatische PRs erwarten win32 und win64."
    }

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
Assert-InstallerUrlsMatchVersion -InstallerPath $installerManifest -Version $EffectiveVersion -AllowSingleArchitecture:$AllowSingleArchitecture

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

Invoke-WingetCreateSubmitWithForkSync -ManifestDir $manifestDir -PrTitle $prTitle

exit 0
