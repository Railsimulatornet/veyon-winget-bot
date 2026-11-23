Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Load only the production functions; never run the submit/sync entry point.
$source = Join-Path $PSScriptRoot '../Submit-VeyonWingetUpdate.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path $source), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Production PowerShell source does not parse.' }
foreach ($name in @('Headers', 'Get-ObjectProperty', 'Invoke-ManifestRead', 'Get-WingetInstallerManifest')) {
    $function = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true))
    if ($function.Count -ne 1) { throw "Expected one production function: $name" }
    . ([scriptblock]::Create($function[0].Extent.Text))
}

$PackageId = 'VeyonSolutions.Veyon'
$env:GITHUB_API_TOKEN = 'offline-test-token'
$env:WINGET_CREATE_GITHUB_TOKEN = ''
$manifestPath = 'manifests/v/VeyonSolutions/Veyon/4.11.5.0/VeyonSolutions.Veyon.installer.yaml'
$manifestText = "PackageIdentifier: VeyonSolutions.Veyon`n# Grüße`n"
$script:passed = 0

function Response {
    param([int]$Status, [hashtable]$Headers = @{}, [string]$Text = $manifestText)
    $body = @{ type='file'; path=$manifestPath; encoding='base64';
        content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)) }
    [pscustomobject]@{ StatusCode=$Status; Headers=$Headers; Content=($body | ConvertTo-Json) }
}
function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Throws {
    param([scriptblock]$Code, [string]$Pattern)
    $caught = $null
    try { & $Code | Out-Null } catch { $caught = $_.Exception.Message }
    Assert ($null -ne $caught -and $caught -match $Pattern) "Expected error matching '$Pattern'; got '$caught'"
}
function Prepare {
    param([object[]]$Responses)
    $script:responses = [Collections.Generic.Queue[object]]::new()
    foreach ($response in $Responses) { $script:responses.Enqueue($response) }
    $script:requests = [Collections.Generic.List[object]]::new()
    $script:sleeps = [Collections.Generic.List[int]]::new()
}
function Invoke-WebRequest {
    param([string]$Uri, [hashtable]$Headers, [switch]$SkipHttpErrorCheck, [int]$TimeoutSec)
    Assert ($Uri.StartsWith('https://api.github.com/repos/microsoft/winget-pkgs/contents/')) 'Unexpected network destination.'
    Assert ($Headers.Authorization -eq 'Bearer offline-test-token') 'Manifest read must authenticate.'
    Assert ($Headers.Accept -eq 'application/vnd.github+json') 'Expected JSON contents response.'
    Assert ($SkipHttpErrorCheck -and $TimeoutSec -eq 60) 'Expected bounded HTTP read.'
    $script:requests.Add([pscustomobject]@{ Uri=$Uri })
    if (-not $script:responses.Count) { throw 'Unexpected extra HTTP request.' }
    $script:responses.Dequeue()
}
function Start-Sleep {
    param([int]$Seconds)
    $script:sleeps.Add($Seconds)
}
function Test {
    param([string]$Name, [scriptblock]$Code)
    & $Code
    $script:passed++
    Write-Host "PASS: $Name"
}

Test 'Authenticated manifest content keeps UTF-8 and uses no cache-busting CDN URL' {
    Prepare @((Response 200))
    $result = Get-WingetInstallerManifest '4.11.5.0'
    Assert ($result.Exists -and $result.Text -ceq $manifestText) 'Manifest content changed.'
    Assert ($result.Branch -eq 'master' -and $script:requests.Count -eq 1) 'Wrong branch/read count.'
    Assert ($script:requests[0].Uri.EndsWith('?ref=master')) 'Missing explicit branch.'
    Assert ($script:sleeps.Count -eq 0) 'Successful reads must not sleep.'
}
Test 'Only a genuine 404 permits the main-branch fallback' {
    Prepare @((Response 404), (Response 200))
    $result = Get-WingetInstallerManifest '4.11.5.0'
    Assert ($result.Exists -and $result.Branch -eq 'main' -and $script:requests.Count -eq 2) 'Fallback failed.'
}
Test 'Two genuine 404 responses mean the manifest is absent' {
    Prepare @((Response 404), (Response 404))
    $result = Get-WingetInstallerManifest '4.11.5.0'
    Assert (-not $result.Exists -and $script:requests.Count -eq 2) 'Unexpected absence result.'
}
Test 'Temporary rate limiting recovers without treating the manifest as absent' {
    Prepare @((Response 429 @{'Retry-After'='5'}), (Response 200))
    $result = Get-WingetInstallerManifest '4.11.5.0'
    Assert ($result.Exists -and $script:requests.Count -eq 2) 'Rate limit recovery failed.'
    Assert ($script:sleeps.Count -eq 1 -and $script:sleeps[0] -eq 60) 'Rate-limit pause was not respected.'
}
Test 'Temporary server errors retry only the read with bounded backoff' {
    Prepare @((Response 503), (Response 502), (Response 200))
    $result = Get-WingetInstallerManifest '4.11.5.0'
    Assert ($result.Exists -and ($script:sleeps -join ',') -eq '2,4') 'Incorrect transient-error backoff.'
}
Test 'Persistent rate limiting fails after exactly three attempts' {
    Prepare @((Response 429), (Response 429), (Response 429))
    Assert-Throws { Get-WingetInstallerManifest '4.11.5.0' } 'HTTP 429, Versuch 3'
    Assert ($script:requests.Count -eq 3 -and $script:sleeps.Count -eq 2) 'Unbounded rate-limit retry.'
}
Test 'Long Retry-After defers to the next scheduled run without another request' {
    Prepare @((Response 429 @{'Retry-After'='300'}))
    Assert-Throws { Get-WingetInstallerManifest '4.11.5.0' } 'nächste geplante Lauf'
    Assert ($script:requests.Count -eq 1 -and $script:sleeps.Count -eq 0) 'Long retry was not deferred.'
}
Test 'Primary rate-limit reset is respected without premature retry' {
    Prepare @((Response 403 @{'X-RateLimit-Remaining'='0'; 'X-RateLimit-Reset'=[string]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+600)}))
    Assert-Throws { Get-WingetInstallerManifest '4.11.5.0' } 'nächste geplante Lauf'
    Assert ($script:requests.Count -eq 1 -and $script:sleeps.Count -eq 0) 'Primary rate limit was retried prematurely.'
}
Test 'Permission failures do not look like a missing manifest' {
    Prepare @((Response 403))
    Assert-Throws { Get-WingetInstallerManifest '4.11.5.0' } 'HTTP 403'
    Assert ($script:requests.Count -eq 1 -and $script:sleeps.Count -eq 0) 'Unexpected retry on denied access.'
}
Test 'Malformed success response fails closed' {
    $response = Response 200
    $response.Content = '{"type":"file","encoding":"none"}'
    Prepare @($response)
    Assert-Throws { Get-WingetInstallerManifest '4.11.5.0' } 'kein gültiges'
    Assert ($script:requests.Count -eq 1) 'Malformed content must not trigger a branch fallback.'
}
Test 'Invalid Base64 fails closed' {
    $response = Response 200
    $body = $response.Content | ConvertFrom-Json
    $body.content = 'not-base64!'
    $response.Content = $body | ConvertTo-Json
    Prepare @($response)
    Assert-Throws { Get-WingetInstallerManifest '4.11.5.0' } 'Base-64|Base64'
}
Test 'Invalid path input cannot change the API target' {
    Prepare @()
    Assert-Throws { Get-WingetInstallerManifest '../../wrong' } 'Ungültige Paketkennung'
    Assert ($script:requests.Count -eq 0) 'Unvalidated path reached HTTP.'
}
Write-Host "Manifest-read regression tests: $script:passed passed; no network or submission."
