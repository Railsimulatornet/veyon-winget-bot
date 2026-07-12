<#
Submit-VeyonWingetUpdate.ps1
Compact CI script for Veyon -> WinGet.
Detects the real Windows installer version from Veyon GitHub release assets,
including intermediate builds like 4.10.2.21.
Also detects replaced release assets by comparing their current SHA256 digests
with the existing WinGet installer manifest and creates a correction PR.
#>

[CmdletBinding()]
param(
    [string]$Version = "",
    [string]$PackageId = "VeyonSolutions.Veyon",
    [string]$Repo = "veyon/veyon",
    [switch]$CheckOnly,
    [switch]$NoSubmit,
    [switch]$ForceTokenSetup,
    [switch]$AllowSingleArchitecture,
    [switch]$SkipForkSync,
    [switch]$ForceForkSync
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Out-Gha {
    param([string]$Name, [AllowNull()][string]$Value)
    if ($null -eq $Value) { $Value = "" }
    if ($env:GITHUB_OUTPUT) {
        "$Name=$Value" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    }
}

function Out-Check {
    param(
        [string]$NeedsUpdate,
        [AllowNull()][string]$Version,
        [AllowNull()][string]$Tag,
        [AllowNull()][string]$NotesUrl,
        [AllowNull()][string]$ReleaseDate,
        [AllowNull()][string]$ExistingPrUrl,
        [AllowNull()][string]$Reason,
        [AllowNull()][string]$ChangeType,
        [AllowNull()][string]$ManifestUrl
    )
    Out-Gha "needsUpdate" $NeedsUpdate
    Out-Gha "version" $Version
    Out-Gha "tag" $Tag
    Out-Gha "notesUrl" $NotesUrl
    Out-Gha "releaseDate" $ReleaseDate
    Out-Gha "existingPrUrl" $ExistingPrUrl
    Out-Gha "reason" $Reason
    Out-Gha "changeType" $ChangeType
    Out-Gha "manifestUrl" $ManifestUrl
}

function Headers {
    $h = @{
        "User-Agent" = "veyon-winget-bot"
        "Accept" = "application/vnd.github+json"
    }
    if ($env:WINGET_CREATE_GITHUB_TOKEN -and $env:WINGET_CREATE_GITHUB_TOKEN.Trim().Length -gt 0) {
        $h["Authorization"] = "Bearer $($env:WINGET_CREATE_GITHUB_TOKEN)"
    }
    return $h
}

function GH {
    param(
        [ValidateSet("Get","Post","Patch")]
        [string]$Method,
        [string]$Uri,
        [AllowNull()]$Body = $null
    )
    if ($null -ne $Body) {
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers (Headers) -ContentType "application/json" -Body ($Body | ConvertTo-Json -Depth 20) -TimeoutSec 90
    }
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers (Headers) -TimeoutSec 90
}

function Get-ObjectProperty {
    param([AllowNull()]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function To-Ver {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $m = [regex]::Match($Text, '(\d+\.\d+\.\d+(?:\.\d+)?)')
    if (-not $m.Success) { return $null }
    try { return [version]$m.Groups[1].Value } catch { return $null }
}

function Ver4 {
    param([version]$V)
    if ($V.Build -lt 0) { throw "Version muss mindestens drei Segmente enthalten: $V" }
    if ($V.Revision -ge 0) { return "{0}.{1}.{2}.{3}" -f $V.Major,$V.Minor,$V.Build,$V.Revision }
    return "{0}.{1}.{2}.0" -f $V.Major,$V.Minor,$V.Build
}

function TagVer {
    param([string]$Tag)
    $m = [regex]::Match($Tag, '^v?(\d+\.\d+\.\d+(?:\.\d+)?)$', 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Normalize-Sha256 {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $m = [regex]::Match($Text.Trim(), '^(?:sha256:)?([0-9a-f]{64})$', 'IgnoreCase')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value.ToUpperInvariant()
}

function AssetInfo {
    param($ReleaseEntry, $Asset)
    $name = [string]$Asset.name
    $m = [regex]::Match($name, '^veyon-(\d+\.\d+\.\d+(?:\.\d+)?)-win(32|64)-setup\.exe$', 'IgnoreCase')
    if (-not $m.Success) { return $null }

    $assetVer = To-Ver $m.Groups[1].Value
    if ($null -eq $assetVer) { return $null }

    $tagVer = $ReleaseEntry.TagVersionObj
    if ($assetVer.Major -ne $tagVer.Major -or $assetVer.Minor -ne $tagVer.Minor -or $assetVer.Build -ne $tagVer.Build) {
        Write-Warning "Ignoriere unpassendes Asset '$name' in Release $($ReleaseEntry.Tag): Asset-Version passt nicht zur Release-Basis."
        return $null
    }

    return [pscustomobject]@{
        Tag = $ReleaseEntry.Tag
        Release = $ReleaseEntry.Release
        VersionText = Ver4 $assetVer
        VersionObj = [version](Ver4 $assetVer)
        Arch = "win$($m.Groups[2].Value)"
        Name = $name
        Url = [string]$Asset.browser_download_url
        Asset = $Asset
    }
}

function Get-AssetSets {
    Write-Host "Lese stabile Veyon GitHub Releases: https://api.github.com/repos/$Repo/releases?per_page=100"
    $releases = GH Get "https://api.github.com/repos/$Repo/releases?per_page=100"

    $stable = @()
    foreach ($r in $releases) {
        if ($r.draft -or $r.prerelease) { continue }
        $tagText = TagVer ([string]$r.tag_name)
        if ([string]::IsNullOrWhiteSpace($tagText)) { continue }
        $tagObj = To-Ver $tagText
        if ($null -eq $tagObj) { continue }
        $stable += [pscustomobject]@{ Release=$r; Tag=[string]$r.tag_name; TagVersionText=$tagText; TagVersionObj=$tagObj }
    }

    $candidates = @()
    foreach ($s in $stable) {
        foreach ($a in $s.Release.assets) {
            $info = AssetInfo $s $a
            if ($null -ne $info) { $candidates += $info }
        }
    }

    if ($candidates.Count -eq 0) { throw "Keine gültigen Veyon Windows-Setup-Assets gefunden." }

    $sets = @()
    foreach ($g in ($candidates | Group-Object VersionText)) {
        $items = @($g.Group)
        $x86 = $items | Where-Object Arch -eq "win32" | Select-Object -First 1
        $x64 = $items | Where-Object Arch -eq "win64" | Select-Object -First 1
        $first = $items | Select-Object -First 1
        $dates = @()
        foreach ($x in @($x86,$x64)) {
            if ($null -eq $x) { continue }
            $updatedAt = Get-ObjectProperty $x.Asset "updated_at"
            $createdAt = Get-ObjectProperty $x.Asset "created_at"
            if ($updatedAt) { $dates += [DateTimeOffset]$updatedAt }
            elseif ($createdAt) { $dates += [DateTimeOffset]$createdAt }
        }
        if ($dates.Count -gt 0) {
            $date = ($dates | Sort-Object UtcDateTime -Descending | Select-Object -First 1).UtcDateTime.ToString("yyyy-MM-dd")
        } else {
            $date = ([DateTimeOffset]$first.Release.published_at).UtcDateTime.ToString("yyyy-MM-dd")
        }
        $sets += [pscustomobject]@{
            Tag=$first.Tag
            VersionText=$first.VersionText
            VersionObj=$first.VersionObj
            ReleaseNotesUrl=[string]$first.Release.html_url
            ReleaseDate=$date
            AssetX86=$x86
            AssetX64=$x64
            HasX86=($null -ne $x86)
            HasX64=($null -ne $x64)
            HasBoth=(($null -ne $x86) -and ($null -ne $x64))
        }
    }

    return @($sets | Sort-Object @{Expression={$_.VersionObj};Descending=$true}, @{Expression={$_.ReleaseDate};Descending=$true})
}

function Resolve-Set {
    $sets = Get-AssetSets
    $top = $sets | Select-Object -First 1
    Write-Host "Höchste erkannte Windows-Setup-Version: $($top.VersionText) aus Release $($top.Tag)"
    Write-Host "Architekturen: win32=$($top.HasX86), win64=$($top.HasX64)"

    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        $reqObj = To-Ver $Version
        if ($null -eq $reqObj) { throw "Ungültige Version: $Version" }
        $req = Ver4 $reqObj
        $sel = $sets | Where-Object VersionText -eq $req | Select-Object -First 1
        if (-not $sel) { throw "Angeforderte Version $req wurde nicht als gültiges Windows-Setup-Asset gefunden." }
    } else {
        if ($AllowSingleArchitecture) { $sel = $sets | Where-Object HasX64 | Select-Object -First 1 }
        else { $sel = $sets | Where-Object HasBoth | Select-Object -First 1 }
        if (-not $sel) { throw "Keine einreichbare Version gefunden. Benötigt: win32 und win64." }
    }

    if (-not $sel.HasX64) { throw "Version $($sel.VersionText) hat kein win64 Setup." }
    if (-not $AllowSingleArchitecture -and -not $sel.HasBoth) {
        throw "Version $($sel.VersionText) ist unvollständig. Gefunden: win32=$($sel.HasX86), win64=$($sel.HasX64)."
    }

    return [pscustomobject]@{ Selected=$sel; HighestDetected=$top }
}

function Get-AssetSha256 {
    param($AssetInfo)

    $digestRaw = Get-ObjectProperty $AssetInfo.Asset "digest"
    $digest = Normalize-Sha256 ([string]$digestRaw)
    if ($digest) {
        Write-Host "SHA256 aus GitHub Release API: $($AssetInfo.Name) = $digest"
        return $digest
    }

    Write-Warning "GitHub liefert für '$($AssetInfo.Name)' keinen SHA256-Digest. Datei wird zur Hashprüfung heruntergeladen."
    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("veyon-hash-" + [guid]::NewGuid().ToString("N") + ".exe")
    try {
        Invoke-WebRequest -Uri $AssetInfo.Url -Headers @{ "User-Agent" = "veyon-winget-bot"; "Cache-Control" = "no-cache" } -OutFile $tempFile -TimeoutSec 300
        $hash = (Get-FileHash -LiteralPath $tempFile -Algorithm SHA256).Hash.ToUpperInvariant()
        Write-Host "SHA256 aus Download: $($AssetInfo.Name) = $hash"
        return $hash
    }
    finally {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-CurrentAssetRecords {
    param($Set)

    $records = @()
    foreach ($candidate in @(
        [pscustomobject]@{ Architecture="x86"; Info=$Set.AssetX86 },
        [pscustomobject]@{ Architecture="x64"; Info=$Set.AssetX64 }
    )) {
        if ($null -eq $candidate.Info) { continue }
        $records += [pscustomobject]@{
            Architecture = $candidate.Architecture
            InstallerUrl = [string]$candidate.Info.Url
            InstallerSha256 = Get-AssetSha256 $candidate.Info
            AssetName = [string]$candidate.Info.Name
        }
    }
    return @($records)
}

function Get-WingetInstallerManifest {
    param([string]$V)

    $segments = @($PackageId -split '\.')
    if ($segments.Count -lt 2) { throw "PackageId hat ein unerwartetes Format: $PackageId" }
    $bucket = $PackageId.Substring(0,1).ToLowerInvariant()
    $packagePath = $segments -join '/'

    foreach ($branch in @("master","main")) {
        $url = "https://raw.githubusercontent.com/microsoft/winget-pkgs/$branch/manifests/$bucket/$packagePath/$V/$PackageId.installer.yaml"
        $response = Invoke-WebRequest -Uri ($url + "?t=" + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -Headers @{ "User-Agent" = "veyon-winget-bot"; "Cache-Control" = "no-cache" } -SkipHttpErrorCheck -TimeoutSec 60
        $status = [int]$response.StatusCode
        if ($status -eq 200) {
            Write-Host "Installer-Manifest in winget-pkgs gefunden ($branch): $V"
            return [pscustomobject]@{
                Exists = $true
                Branch = $branch
                Url = $url
                Text = [string]$response.Content
            }
        }
        if ($status -ne 404) { throw "Unerwarteter HTTP-Status $status für $url" }
    }

    return [pscustomobject]@{ Exists=$false; Branch=""; Url=""; Text="" }
}

function Get-ManifestInstallerEntries {
    param([string]$Text)

    $entries = @()
    $current = $null
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*-\s+Architecture:\s*(\S+)\s*$') {
            if ($null -ne $current) { $entries += [pscustomobject]$current }
            $current = [ordered]@{
                Architecture = $matches[1]
                InstallerUrl = ""
                InstallerSha256 = ""
            }
            continue
        }
        if ($null -eq $current) { continue }
        if ($line -match '^\s*InstallerUrl:\s*(\S+)\s*$') {
            $current.InstallerUrl = $matches[1]
            continue
        }
        if ($line -match '^\s*InstallerSha256:\s*([0-9A-Fa-f]{64})\s*$') {
            $current.InstallerSha256 = $matches[1].ToUpperInvariant()
        }
    }
    if ($null -ne $current) { $entries += [pscustomobject]$current }
    return @($entries)
}

function Compare-ManifestWithAssets {
    param(
        [string]$ManifestText,
        [object[]]$ExpectedAssets
    )

    $manifestEntries = @(Get-ManifestInstallerEntries $ManifestText)
    $issues = [System.Collections.Generic.List[string]]::new()

    foreach ($expected in $ExpectedAssets) {
        $actual = $manifestEntries | Where-Object Architecture -eq $expected.Architecture | Select-Object -First 1
        if ($null -eq $actual) {
            $issues.Add("Manifest-Eintrag für $($expected.Architecture) fehlt.")
            continue
        }
        if (-not [string]::Equals([string]$actual.InstallerUrl, [string]$expected.InstallerUrl, [System.StringComparison]::Ordinal)) {
            $issues.Add("InstallerUrl $($expected.Architecture) abweichend: Manifest='$($actual.InstallerUrl)', aktuell='$($expected.InstallerUrl)'.")
        }
        $actualHash = Normalize-Sha256 ([string]$actual.InstallerSha256)
        if (-not $actualHash) {
            $issues.Add("InstallerSha256 für $($expected.Architecture) fehlt oder ist ungültig.")
        } elseif (-not [string]::Equals($actualHash, [string]$expected.InstallerSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            $issues.Add("SHA256 $($expected.Architecture) abweichend: Manifest=$actualHash, aktuell=$($expected.InstallerSha256).")
        }
    }

    return [pscustomobject]@{
        Matches = ($issues.Count -eq 0)
        Issues = @($issues)
        ManifestEntries = $manifestEntries
    }
}

function Existing-Pr {
    param([string]$V)
    $q = "repo:microsoft/winget-pkgs is:pr is:open in:title $PackageId $V"
    Write-Host "Suche nach bestehender offener PR: $q"
    $uri = "https://api.github.com/search/issues?q=$([uri]::EscapeDataString($q))&per_page=10"
    $r = GH Get $uri
    if ($r.total_count -gt 0) { return $r.items | Select-Object -First 1 }
    return $null
}

function Find-Manifest {
    param([string]$Root, [string]$Type)
    foreach ($f in Get-ChildItem -Path $Root -Recurse -File -Filter "*.yaml") {
        $txt = Get-Content $f.FullName -Raw
        if ($txt -match "(?m)^\s*ManifestType:\s*$Type\s*$") { return $f.FullName }
    }
    return $null
}

function Guard {
    param(
        [string]$OutDir,
        [string]$V,
        [object[]]$ExpectedAssets
    )
    $locale = Find-Manifest $OutDir "defaultLocale"
    $installer = Find-Manifest $OutDir "installer"
    if (-not $locale) { throw "Guard fehlgeschlagen: defaultLocale Manifest fehlt." }
    if (-not $installer) { throw "Guard fehlgeschlagen: installer Manifest fehlt." }

    $ltxt = Get-Content $locale -Raw
    $itxt = Get-Content $installer -Raw
    if ($ltxt -notmatch "(?m)^\s*ReleaseNotesUrl:\s*\S+\s*$") { throw "Guard fehlgeschlagen: ReleaseNotesUrl fehlt." }
    if ($itxt -notmatch "(?m)^\s*ReleaseDate:\s*\d{4}-\d{2}-\d{2}\s*$" -and $ltxt -notmatch "(?m)^\s*ReleaseDate:\s*\d{4}-\d{2}-\d{2}\s*$") {
        throw "Guard fehlgeschlagen: ReleaseDate fehlt."
    }

    $urls = @([regex]::Matches($itxt, '(?m)^\s*InstallerUrl:\s*(\S+)\s*$') | ForEach-Object { $_.Groups[1].Value })
    if ($urls.Count -eq 0) { throw "Guard fehlgeschlagen: Keine InstallerUrl gefunden." }
    foreach ($u in $urls) {
        if ($u -match '(?i)veyon-.*-win(?:32|64)-setup\.exe$' -and $u -notmatch [regex]::Escape("veyon-$V-")) {
            throw "Guard fehlgeschlagen: InstallerUrl passt nicht zu $V. URL: $u"
        }
    }
    if (-not ($urls | Where-Object { $_ -match "(?i)veyon-$([regex]::Escape($V))-win64-setup\.exe" })) { throw "Guard fehlgeschlagen: win64 URL fehlt." }
    if (-not $AllowSingleArchitecture -and -not ($urls | Where-Object { $_ -match "(?i)veyon-$([regex]::Escape($V))-win32-setup\.exe" })) { throw "Guard fehlgeschlagen: win32 URL fehlt." }

    $comparison = Compare-ManifestWithAssets -ManifestText $itxt -ExpectedAssets $ExpectedAssets
    if (-not $comparison.Matches) {
        throw ("Guard fehlgeschlagen: generierte Installer-Daten stimmen nicht mit den aktuellen Release-Assets überein. " + ($comparison.Issues -join " | "))
    }

    Write-Host "Guard OK: Installer URLs passen zur effektiven Version $V"
    Write-Host "Guard OK: InstallerSha256 entspricht den aktuellen Veyon Release-Assets"
    Write-Host "Guard OK: ReleaseNotesUrl vorhanden in $locale"
    Write-Host "Guard OK: ReleaseDate vorhanden in $installer oder fallback im defaultLocale"
}

function Login {
    if (-not $env:WINGET_CREATE_GITHUB_TOKEN) { return $null }
    try { return [string](GH Get "https://api.github.com/user").login } catch { return $null }
}

function Sync-Fork {
    param([switch]$Required)
    if ($SkipForkSync) { Write-Host "Fork-Sync übersprungen."; return $false }
    if (-not $env:WINGET_CREATE_GITHUB_TOKEN) { Write-Warning "Fork-Sync übersprungen: Token fehlt."; return $false }

    $login = Login
    if ([string]::IsNullOrWhiteSpace($login)) { if ($Required) { throw "Fork-Sync fehlgeschlagen: Login konnte nicht ermittelt werden." }; return $false }

    $forkFull = "$login/winget-pkgs"
    Write-Host "Prüfe WinGet-Fork: $forkFull"
    try { $fork = GH Get "https://api.github.com/repos/$forkFull" }
    catch { if ($Required) { throw "Fork-Sync fehlgeschlagen: Fork $forkFull nicht lesbar." }; return $false }

    $branch = [string]$fork.default_branch
    if ([string]::IsNullOrWhiteSpace($branch)) { $branch = "master" }
    Write-Host "Synchronisiere WinGet-Fork $forkFull, Branch: $branch"

    try {
        $cmp = GH Get "https://api.github.com/repos/microsoft/winget-pkgs/compare/master...$($login):$branch"
        $ahead = [int]$cmp.ahead_by
        $behind = [int]$cmp.behind_by
        Write-Host "Fork-Status: $($cmp.status), ahead_by=$ahead, behind_by=$behind"
        if ($ahead -eq 0 -and $behind -eq 0) { Write-Host "Fork ist bereits aktuell."; return $true }
        if ($ahead -gt 0 -and -not $ForceForkSync) {
            throw "Fork hat eigene Commits (ahead_by=$ahead). Für Force-Sync -ForceForkSync setzen."
        }
        $up = GH Get "https://api.github.com/repos/microsoft/winget-pkgs/git/ref/heads/master"
        $sha = [string]$up.object.sha
        Write-Host "Setze $forkFull $branch auf upstream/master: $sha"
        GH Patch "https://api.github.com/repos/$forkFull/git/refs/heads/$branch" @{ sha=$sha; force=$true } | Out-Null
        Start-Sleep -Seconds 5
        Write-Host "Fork-Sync per Git refs API abgeschlossen."
        return $true
    }
    catch {
        Write-Warning "Fork-Sync per Git refs API fehlgeschlagen: $($_.Exception.Message)"
        Write-Host "Versuche Fallback über GitHub merge-upstream API."
        try {
            GH Post "https://api.github.com/repos/$forkFull/merge-upstream" @{ branch=$branch } | Out-Null
            Start-Sleep -Seconds 5
            Write-Host "Fork-Sync per merge-upstream API abgeschlossen."
            return $true
        }
        catch {
            if ($Required) { throw "Fork-Sync fehlgeschlagen. Bitte Token-Rechte prüfen oder Fork manuell synchronisieren. Details: $($_.Exception.Message)" }
            Write-Warning "Fork-Sync über merge-upstream API fehlgeschlagen: $($_.Exception.Message)"
            return $false
        }
    }
}

function Submit-WithRetry {
    param([string]$ManifestDir, [string]$Title)
    Sync-Fork | Out-Null
    Write-Host "Submitting manifest directory: $ManifestDir"
    & wingetcreate submit --prtitle $Title --no-open $ManifestDir
    if ($LASTEXITCODE -eq 0) { return }
    Write-Warning "wingetcreate submit fehlgeschlagen (ExitCode $LASTEXITCODE). Retry nach Fork-Sync."
    Sync-Fork -Required | Out-Null
    & wingetcreate submit --prtitle $Title --no-open $ManifestDir
    if ($LASTEXITCODE -ne 0) { throw "wingetcreate submit fehlgeschlagen (ExitCode $LASTEXITCODE)." }
}

function Get-BaseReason {
    param($Resolution)
    $set = $Resolution.Selected
    $reason = "Ausgewählte einreichbare Version: $($set.VersionText) aus Release $($set.Tag)."
    if ($Resolution.HighestDetected.VersionText -ne $set.VersionText) {
        $reason = "Höchste erkannte Version $($Resolution.HighestDetected.VersionText) wurde nicht ausgewählt, weil sie unvollständig ist. $reason"
    }
    return $reason
}

if ($CheckOnly) {
    Write-Host "CheckOnly aktiv - es wird geprüft, ob eine neue Version oder eine Installer-Hash-Korrektur nötig ist."
    $res = Resolve-Set
    $set = $res.Selected
    $reason = Get-BaseReason $res
    $manifest = Get-WingetInstallerManifest $set.VersionText

    if ($manifest.Exists) {
        $expectedAssets = @(Get-CurrentAssetRecords $set)
        $comparison = Compare-ManifestWithAssets -ManifestText $manifest.Text -ExpectedAssets $expectedAssets
        if ($comparison.Matches) {
            Out-Check "false" $set.VersionText $set.Tag $set.ReleaseNotesUrl $set.ReleaseDate "" "$reason Version und Installer-Hashes sind in winget-pkgs aktuell." "none" $manifest.Url
            exit 0
        }

        $hashReason = "Installer-Manifest vorhanden, aber aktuelle Release-Assets weichen ab: " + ($comparison.Issues -join " | ")
        $pr = Existing-Pr $set.VersionText
        if ($pr) {
            Out-Check "false" $set.VersionText $set.Tag $set.ReleaseNotesUrl $set.ReleaseDate $pr.html_url "$reason $hashReason Es existiert bereits eine offene PR: $($pr.html_url)" "installer-hash-correction" $manifest.Url
            exit 0
        }

        Out-Check "true" $set.VersionText $set.Tag $set.ReleaseNotesUrl $set.ReleaseDate "" "$reason $hashReason Eine Korrektur-PR ist nötig." "installer-hash-correction" $manifest.Url
        exit 0
    }

    $pr = Existing-Pr $set.VersionText
    if ($pr) {
        Out-Check "false" $set.VersionText $set.Tag $set.ReleaseNotesUrl $set.ReleaseDate $pr.html_url "$reason Es existiert bereits eine offene PR: $($pr.html_url)" "new-version" ""
        exit 0
    }

    Out-Check "true" $set.VersionText $set.Tag $set.ReleaseNotesUrl $set.ReleaseDate "" "$reason Version ist noch nicht in winget-pkgs vorhanden und es wurde keine offene PR gefunden." "new-version" ""
    exit 0
}

if (-not $ForceTokenSetup -and $env:WINGET_CREATE_GITHUB_TOKEN) {
    Write-Host "CI token detected (WINGET_CREATE_GITHUB_TOKEN). Skipping 'wingetcreate token -s'."
} else {
    & wingetcreate token -s
    if ($LASTEXITCODE -ne 0) { throw "wingetcreate token -s fehlgeschlagen (ExitCode $LASTEXITCODE)." }
}

$res = Resolve-Set
$set = $res.Selected
$v = $set.VersionText
Write-Host "Effektive WinGet-Version: $v"
Write-Host "GitHub Release Tag: $($set.Tag)"
Write-Host "Release Notes: $($set.ReleaseNotesUrl)"
Write-Host "Release Date: $($set.ReleaseDate)"

$urls = @()
if ($set.AssetX86) { Write-Host "Gefundenes win32 Asset: $($set.AssetX86.Name)"; $urls += $set.AssetX86.Url }
if ($set.AssetX64) { Write-Host "Gefundenes win64 Asset: $($set.AssetX64.Name)"; $urls += $set.AssetX64.Url }
if ($urls.Count -eq 0) { throw "Keine Installer-URLs gefunden." }

$manifest = Get-WingetInstallerManifest $v
$expectedAssets = @(Get-CurrentAssetRecords $set)
$changeType = "new-version"
$prTitle = "New version: $PackageId version $v"

if ($manifest.Exists) {
    $comparison = Compare-ManifestWithAssets -ManifestText $manifest.Text -ExpectedAssets $expectedAssets
    if ($comparison.Matches) {
        Write-Host "Keine PR nötig. Version $v und Installer-Hashes sind bereits aktuell."
        exit 0
    }
    $changeType = "installer-hash-correction"
    $prTitle = "Update: $PackageId version $v"
    Write-Warning ("Korrektur derselben Version nötig: " + ($comparison.Issues -join " | "))
}

$pr = Existing-Pr $v
if ($pr) { Write-Host "Keine PR nötig. Bereits offene PR gefunden: $($pr.html_url)"; exit 0 }

$tempBase = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$outDir = Join-Path $tempBase ("wingetcreate-" + $PackageId + "-" + $v)
if (Test-Path $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

Write-Host "Änderungstyp: $changeType"
$args = @("update", $PackageId, "--version", $v, "--urls") + $urls + @("--release-notes-url", $set.ReleaseNotesUrl, "--release-date", $set.ReleaseDate, "--out", $outDir)
& wingetcreate @args
if ($LASTEXITCODE -ne 0) { throw "wingetcreate update fehlgeschlagen (ExitCode $LASTEXITCODE)." }

Guard -OutDir $outDir -V $v -ExpectedAssets $expectedAssets

if ($NoSubmit) { Write-Host "NoSubmit aktiv - Manifeste liegen hier: $outDir"; exit 0 }

$versionManifest = Find-Manifest $outDir "version"
if (-not $versionManifest) { throw "Submit fehlgeschlagen: version Manifest fehlt." }
$manifestDir = Split-Path -Parent $versionManifest
Submit-WithRetry $manifestDir $prTitle

exit 0
