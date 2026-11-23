[CmdletBinding()]
param([string]$Fixture = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$production = Join-Path $PSScriptRoot '../Submit-VeyonWingetUpdate.ps1'

if ($Fixture) {
    # Each fixture runs the complete, unchanged entry point in a child process.
    # No production credential or HTTP transport is used by that child.
    $env:GITHUB_API_TOKEN = 'offline-checkonly-token'
    $env:WINGET_CREATE_GITHUB_TOKEN = ''
    $global:checkOnly_scenario = $Fixture
    $global:checkOnly_x86Hash = 'A' * 64
    $global:checkOnly_x64Hash = 'B' * 64
    $global:checkOnly_releaseRoot = 'https://github.com/veyon/veyon/releases/download/v4.11.5'

    function global:Invoke-RestMethod {
        param([string]$Method, [string]$Uri, [hashtable]$Headers, [int]$TimeoutSec,
              [AllowNull()]$Body, [AllowNull()][string]$ContentType)
        if ($Method -ne 'Get' -or $null -ne $Body) { throw 'Offline fixture blocked a mutating API request.' }
        if ($Headers.Authorization -ne 'Bearer offline-checkonly-token') { throw 'Unexpected API credential.' }
        if ($Uri -eq 'https://api.github.com/repos/veyon/veyon/releases?per_page=100') {
            return @([pscustomobject]@{
                draft=$false; prerelease=$false; tag_name='v4.11.5'
                html_url='https://github.com/veyon/veyon/releases/tag/v4.11.5'
                published_at='2026-11-20T10:00:00Z'
                assets=@(
                    [pscustomobject]@{ name='veyon-4.11.5.0-win32-setup.exe';
                        browser_download_url="$global:checkOnly_releaseRoot/veyon-4.11.5.0-win32-setup.exe";
                        digest="sha256:$global:checkOnly_x86Hash" },
                    [pscustomobject]@{ name='veyon-4.11.5.0-win64-setup.exe';
                        browser_download_url="$global:checkOnly_releaseRoot/veyon-4.11.5.0-win64-setup.exe";
                        digest="sha256:$global:checkOnly_x64Hash" }
                )
            })
        }
        if ($Uri.StartsWith('https://api.github.com/search/issues?q=repo%3Amicrosoft%2Fwinget-pkgs')) {
            if ($global:checkOnly_scenario -in @('existing-new', 'existing-hash')) {
                return [pscustomobject]@{ total_count=1; items=@([pscustomobject]@{
                    html_url='https://github.com/microsoft/winget-pkgs/pull/999999999'
                }) }
            }
            return [pscustomobject]@{ total_count=0; items=@() }
        }
        throw "Offline fixture blocked an unexpected API request: $Uri"
    }

    function global:Invoke-WebRequest {
        param([string]$Uri, [hashtable]$Headers, [switch]$SkipHttpErrorCheck, [int]$TimeoutSec)
        $path = 'manifests/v/VeyonSolutions/Veyon/4.11.5.0/VeyonSolutions.Veyon.installer.yaml'
        if ($Uri -notin @("https://api.github.com/repos/microsoft/winget-pkgs/contents/${path}?ref=master",
                         "https://api.github.com/repos/microsoft/winget-pkgs/contents/${path}?ref=main")) {
            throw "Offline fixture blocked an unexpected download: $Uri"
        }
        if ($Headers.Authorization -ne 'Bearer offline-checkonly-token') { throw 'Unexpected manifest credential.' }
        if ($global:checkOnly_scenario -eq 'rate-limited') {
            return [pscustomobject]@{ StatusCode=429; Headers=@{'Retry-After'='300'}; Content='' }
        }
        if ($global:checkOnly_scenario -eq 'permission-denied') {
            return [pscustomobject]@{ StatusCode=403; Headers=@{}; Content='' }
        }
        if ($global:checkOnly_scenario -in @('new-version', 'existing-new')) {
            return [pscustomobject]@{ StatusCode=404; Headers=@{}; Content='' }
        }
        $hash = if ($global:checkOnly_scenario -in @('hash-correction', 'existing-hash')) { 'C' * 64 } else { $global:checkOnly_x64Hash }
        $manifest = @"
PackageIdentifier: VeyonSolutions.Veyon
PackageVersion: 4.11.5.0
Installers:
- Architecture: x86
  InstallerUrl: $global:checkOnly_releaseRoot/veyon-4.11.5.0-win32-setup.exe
  InstallerSha256: $global:checkOnly_x86Hash
- Architecture: x64
  InstallerUrl: $global:checkOnly_releaseRoot/veyon-4.11.5.0-win64-setup.exe
  InstallerSha256: $hash
"@
        $encoding = if ($global:checkOnly_scenario -eq 'malformed-manifest') { 'none' } else { 'base64' }
        $content = @{ type='file'; path=$path; encoding=$encoding;
            content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($manifest)) } | ConvertTo-Json
        if ($global:checkOnly_scenario -eq 'invalid-json') { $content = '{invalid-json}' }
        return [pscustomobject]@{ StatusCode=200; Headers=@{}; Content=$content }
    }

    function global:Start-Sleep { throw 'Offline fixture must not sleep.' }
    function global:wingetcreate { throw 'Offline fixture blocked WinGet submission.' }
    function global:git { throw 'Offline fixture blocked Git mutation.' }
    function global:Start-Process { throw 'Offline fixture blocked an external process.' }
    function global:Send-MailMessage { throw 'Offline fixture blocked mail delivery.' }

    & $production -CheckOnly
    exit $LASTEXITCODE
}

function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Read-Outputs {
    param([string]$Path)
    $values = @{}
    $lines = @(Get-Content -LiteralPath $Path -Encoding utf8)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^([A-Za-z][A-Za-z0-9]*)<<(.+)$') { throw 'Unexpected GitHub output format.' }
        $name = $Matches[1]
        $delimiter = $Matches[2]
        if ($values.ContainsKey($name)) { throw "Duplicate output: $name" }
        $parts = [Collections.Generic.List[string]]::new()
        $i++
        while ($i -lt $lines.Count -and $lines[$i] -cne $delimiter) {
            $parts.Add($lines[$i])
            $i++
        }
        if ($i -ge $lines.Count) { throw 'Unterminated GitHub output.' }
        $values[$name] = $parts -join "`n"
    }
    return $values
}

$cases = @(
    @{ name='current'; update='false'; change='none'; existing=$false },
    @{ name='new-version'; update='true'; change='new-version'; existing=$false },
    @{ name='hash-correction'; update='true'; change='installer-hash-correction'; existing=$false },
    @{ name='existing-new'; update='false'; change='new-version'; existing=$true },
    @{ name='existing-hash'; update='false'; change='installer-hash-correction'; existing=$true },
    @{ name='rate-limited'; error='GitHub begrenzt den Manifestabruf' },
    @{ name='permission-denied'; error='HTTP 403' },
    @{ name='malformed-manifest'; error='kein gültiges Installer-Manifest' },
    @{ name='invalid-json'; error='ConvertFrom-Json|JSON' }
)
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('veyon-offline-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary | Out-Null
try {
    foreach ($case in $cases) {
        $output = Join-Path $temporary ($case.name + '.output')
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = [Environment]::ProcessPath
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $PSCommandPath, '-Fixture', $case.name)) {
            $start.ArgumentList.Add($argument)
        }
        $start.Environment['GITHUB_OUTPUT'] = $output
        $start.Environment['GITHUB_API_TOKEN'] = 'offline-checkonly-token'
        $start.Environment['WINGET_CREATE_GITHUB_TOKEN'] = ''
        $process = [Diagnostics.Process]::Start($start)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(20000)) {
                $process.Kill($true)
                throw "Offline CheckOnly fixture timed out: $($case.name)"
            }
            $log = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
            if ($case.ContainsKey('error')) {
                Assert ($process.ExitCode -ne 0 -and $log -match $case.error) "Expected failure for $($case.name): $log"
                Assert (-not (Test-Path -LiteralPath $output)) "Failed read emitted an update decision: $($case.name)"
            } else {
                Assert ($process.ExitCode -eq 0) "CheckOnly failed for $($case.name): $log"
                $values = Read-Outputs $output
                Assert ($values.Count -eq 9) "Incomplete update decision: $($case.name)"
                Assert ($values['version'] -eq '4.11.5.0') 'Wrong detected release version.'
                Assert ($values['needsUpdate'] -eq $case.update) "Wrong update decision: $($case.name)"
                Assert ($values['changeType'] -eq $case.change) "Wrong update category: $($case.name)"
                Assert ((-not [string]::IsNullOrEmpty($values['existingPrUrl'])) -eq $case.existing) "Incorrect duplicate-PR protection: $($case.name)"
            }
            Write-Host "PASS: full CheckOnly / $($case.name)"
        } finally {
            $process.Dispose()
        }
    }
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
Write-Host "Complete CheckOnly decisions: $($cases.Count) passed; external API availability was not tested."
