<#
Submit-VeyonWingetUpdate.ps1
Compact CI script for Veyon -> WinGet.
Detects the real Windows installer version from Veyon GitHub release assets, including intermediate builds like 4.10.2.21.
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
        [AllowNull()][string]$Reason
    )
    Out-Gha "needsUpdate" $NeedsUpdate
    Out-Gha "version" $Version
    Out-Gha "tag" $Tag
    Out-Gha "notesUrl" $NotesUrl
    Out-Gha "releaseDate" $ReleaseDate
    Out-Gha "existingPrUrl" $ExistingPrUrl
    Out-Gha "reason" $Reason
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
            if ($x.Asset.updated_at) { $dates += [DateTimeOffset]$x.Asset.updated_at }
            elseif ($x.Asset.created_at) { $dates += [DateTimeOffset]$x.Asset.created_at }
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

function Head-Code {
    param([string]$Url)
    $r = Invoke-WebRequest -Uri $Url -Method Head -SkipHttpErrorCheck -TimeoutSec 30
    return [int]$r.StatusCode
}

function In-Winget {
    param([string]$V)
    foreach ($branch in @("master","main")) {
        $url = "https://raw.githubusercontent.com/microsoft/winget-pkgs/$branch/manifests/v/VeyonSolutions/Veyon/$V/VeyonSolutions.Veyon.installer.yaml"
        $code = Head-Code $url
        if ($code -eq 200) { Write-Host "Bereits in winget-pkgs vorhanden ($branch): $V"; return $true }
        if ($code -ne 404) { throw "Unerwarteter HTTP-Status $code für $url" }
    }
    return $false
}

function Existing-Pr {
    param([string]$V)
    $q = 'repo:microsoft/winget-pkgs is:pr is:open in:title "New version: ' + $PackageId + ' version ' + $V + '"'
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
    param([string]$OutDir, [string]$V)
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

    Write-Host "Guard OK: Installer URLs passen zur effektiven Version $V"
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

if ($CheckOnly) {
    Write-Host "CheckOnly aktiv - es wird nur geprüft, ob eine neue PR nötig ist."
    $res = Resolve-Set
    $set = $res.Selected
    $reason = "Ausgewählte einreichbare Version: $($set.VersionText) aus Release $($set.Tag)."
    if ($res.HighestDetected.VersionText -ne $set.VersionText) {
        $reason = "Höchste erkannte Version $($res.HighestDetected.VersionText) wurde nicht ausgewählt, weil sie unvollständig ist. $reason"
    }

    if (In-Winget $set.VersionText) {
        Out-Check "false" $set.VersionText $set.Tag $set.ReleaseNotesUrl $set.ReleaseDate "" "$reason Version ist bereits in winget-pkgs vorhanden."
        exit 0
    }

    $pr = Existing-Pr $set.VersionText
    if ($pr) {
        Out-Check "false" $set.VersionText $set.Tag $set.ReleaseNotesUrl $set.ReleaseDate $pr.html_url "$reason Es existiert bereits eine offene PR: $($pr.html_url)"
        exit 0
    }

    Out-Check "true" $set.VersionText $set.Tag $set.ReleaseNotesUrl $set.ReleaseDate "" "$reason Version ist noch nicht in winget-pkgs vorhanden und es wurde keine offene PR gefunden."
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

if (In-Winget $v) { Write-Host "Keine PR nötig. Version $v ist bereits vorhanden."; exit 0 }
$pr = Existing-Pr $v
if ($pr) { Write-Host "Keine PR nötig. Bereits offene PR gefunden: $($pr.html_url)"; exit 0 }

$tempBase = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$outDir = Join-Path $tempBase ("wingetcreate-" + $PackageId + "-" + $v)
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$args = @("update", $PackageId, "--version", $v, "--urls") + $urls + @("--release-notes-url", $set.ReleaseNotesUrl, "--release-date", $set.ReleaseDate, "--out", $outDir)
& wingetcreate @args
if ($LASTEXITCODE -ne 0) { throw "wingetcreate update fehlgeschlagen (ExitCode $LASTEXITCODE)." }

Guard $outDir $v

if ($NoSubmit) { Write-Host "NoSubmit aktiv - Manifeste liegen hier: $outDir"; exit 0 }

$versionManifest = Find-Manifest $outDir "version"
if (-not $versionManifest) { throw "Submit fehlgeschlagen: version Manifest fehlt." }
$manifestDir = Split-Path -Parent $versionManifest
Submit-WithRetry $manifestDir "New version: $PackageId version $v"

exit 0
