Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Load only Sync-Fork, never the submit entry point or a real HTTP transport.
$source = Join-Path $PSScriptRoot '../Submit-VeyonWingetUpdate.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path $source), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Production PowerShell source does not parse.' }
$function = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Sync-Fork'
}, $true))
if ($function.Count -ne 1) { throw 'Expected one production Sync-Fork function.' }
. ([scriptblock]::Create($function[0].Extent.Text))

$forkRepo = 'Railsimulatornet/winget-pkgs'
$upstreamRepo = 'microsoft/winget-pkgs'
$baseSha = '1' * 40
$upstreamSha = '2' * 40
$forkSha = '3' * 40
$script:passed = 0

function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Throws {
    param([scriptblock]$Code, [string]$Pattern)
    $caught = $null
    try { & $Code | Out-Null } catch { $caught = $_.Exception.Message }
    Assert ($null -ne $caught -and $caught -match $Pattern) "Expected '$Pattern'; got '$caught'"
}
function Prepare {
    $script:SkipForkSync = $false
    $env:WINGET_CREATE_GITHUB_TOKEN = 'offline-fork-test-token'
    $script:fork = [pscustomobject]@{
        full_name=$forkRepo; fork=$true; default_branch='master'
        parent=[pscustomobject]@{ full_name=$upstreamRepo }
    }
    $script:upstream = [pscustomobject]@{ full_name=$upstreamRepo; fork=$false; default_branch='master' }
    $script:forkHead = $forkSha
    $script:upstreamHead = $upstreamSha
    $script:parents = @{}
    $script:parents[$baseSha] = @()
    $script:parents[$upstreamSha] = @($baseSha)
    $script:parents[$forkSha] = @($baseSha)
    $script:requests = [Collections.Generic.List[object]]::new()
    $script:sleeps = [Collections.Generic.List[int]]::new()
    $script:nextCommit = 10
    $script:upstreamReads = 0
    $script:lastReadUpstream = ''
    $script:mergeMode = 'normal'
    $script:mergeError = ''
    $script:moveUpstream = ''
    $script:badComparison = $false
    $script:refOverride = $null
}
function New-Commit {
    param([string[]]$Parents)
    $script:nextCommit++
    $sha = $script:nextCommit.ToString('x40')
    $script:parents[$sha] = $Parents
    return $sha
}
function Get-Ancestors {
    param([string]$Head)
    $seen = [Collections.Generic.List[string]]::new()
    $queue = [Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($Head)
    while ($queue.Count) {
        $sha = $queue.Dequeue()
        if ($seen.Contains($sha)) { continue }
        Assert ($script:parents.ContainsKey($sha)) 'Unknown fixture commit.'
        $seen.Add($sha)
        foreach ($parent in $script:parents[$sha]) { $queue.Enqueue($parent) }
    }
    return $seen.ToArray()
}
function Compare-Commits {
    param([string]$Base, [string]$Head)
    $baseAncestors = @(Get-Ancestors $Base)
    $headAncestors = @(Get-Ancestors $Head)
    $ahead = @($headAncestors | Where-Object { $_ -notin $baseAncestors }).Count
    $behind = @($baseAncestors | Where-Object { $_ -notin $headAncestors }).Count
    $common = @($baseAncestors | Where-Object { $_ -in $headAncestors })
    Assert ($common.Count -gt 0) 'Fixture commits must share history.'
    $status = if ($ahead -and $behind) { 'diverged' } elseif ($ahead) { 'ahead' } elseif ($behind) { 'behind' } else { 'identical' }
    if ($script:badComparison) { $status = 'identical' }
    return [pscustomobject]@{
        status=$status; ahead_by=$ahead; behind_by=$behind
        base_commit=[pscustomobject]@{ sha=$Base }
        merge_base_commit=[pscustomobject]@{ sha=$common[0] }
    }
}
function GH {
    param([string]$Method, [string]$Uri, [AllowNull()]$Body = $null)
    $script:requests.Add([pscustomobject]@{ Method=$Method; Uri=$Uri; Body=$Body })
    if ($Method -eq 'Get' -and $null -eq $Body) {
        if ($Uri -eq "https://api.github.com/repos/$forkRepo") { return $script:fork }
        if ($Uri -eq "https://api.github.com/repos/$upstreamRepo") { return $script:upstream }
        if ($Uri -eq "https://api.github.com/repos/$forkRepo/git/ref/heads/master") {
            if ($null -ne $script:refOverride) { return $script:refOverride }
            return [pscustomobject]@{ ref='refs/heads/master'; object=[pscustomobject]@{ type='commit'; sha=$script:forkHead } }
        }
        if ($Uri -eq "https://api.github.com/repos/$upstreamRepo/git/ref/heads/master") {
            $script:upstreamReads++
            if (($script:moveUpstream -eq 'once' -and $script:upstreamReads -eq 2) -or
                ($script:moveUpstream -eq 'always' -and $script:upstreamReads % 2 -eq 0)) {
                $script:upstreamHead = New-Commit @($script:upstreamHead)
            }
            $script:lastReadUpstream = $script:upstreamHead
            return [pscustomobject]@{ ref='refs/heads/master'; object=[pscustomobject]@{ type='commit'; sha=$script:upstreamHead } }
        }
        $comparePrefix = "https://api.github.com/repos/$forkRepo/compare/"
        if ($Uri.StartsWith($comparePrefix) -and
            $Uri.Substring($comparePrefix.Length) -match '^([0-9a-f]{40})\.\.\.([0-9a-f]{40})\?per_page=1$') {
            return Compare-Commits $Matches[1] $Matches[2]
        }
    }
    if ($Method -eq 'Post' -and $Uri -eq "https://api.github.com/repos/$forkRepo/merges") {
        Assert ($Body.Count -eq 2 -and $Body.base -eq 'master') 'Only a normal merge into the expected branch is permitted.'
        Assert ($Body.head -ceq $script:lastReadUpstream -and $Body.head -match '^[0-9a-f]{40}$') 'Merge must use the captured upstream SHA.'
        if ($script:mergeError) { throw $script:mergeError }
        if ($script:mergeMode -eq 'lose-fork') {
            $script:forkHead = $Body.head
        } elseif ($script:mergeMode -ne 'omit-upstream') {
            $script:forkHead = New-Commit @($script:forkHead, $Body.head)
        }
        if ($script:mergeMode -eq 'empty-response') { return $null }
        return [pscustomobject]@{ sha=$script:forkHead }
    }
    throw "Offline fixture blocked an unexpected request: $Method $Uri"
}
function Start-Sleep {
    param([int]$Seconds)
    $script:sleeps.Add($Seconds)
}
function Invoke-RestMethod { throw 'Offline fixture blocked real HTTP.' }
function Invoke-WebRequest { throw 'Offline fixture blocked a download.' }
function wingetcreate { throw 'Offline fixture blocked submission.' }
function git { throw 'Offline fixture blocked Git mutation.' }
function Post-Count { return @($script:requests | Where-Object Method -eq 'Post').Count }
function Assert-Preserved {
    $ancestors = @(Get-Ancestors $script:forkHead)
    Assert ($forkSha -in $ancestors -and $script:upstreamHead -in $ancestors) 'Fork and current upstream history must both be preserved.'
}
function Test {
    param([string]$Name, [scriptblock]$Code)
    Prepare
    & $Code
    $script:passed++
    Write-Host "PASS: $Name"
}

Test 'Diverged fork keeps its own commit and incorporates upstream' {
    Assert (Sync-Fork -Required) 'Sync failed.'
    Assert-Preserved
    Assert ((Post-Count) -eq 1) 'Expected exactly one normal merge.'
}
Test 'A fork with no own changes still synchronizes' {
    $script:forkHead = $baseSha
    Assert (Sync-Fork -Required) 'Sync failed.'
    Assert ($upstreamSha -in @(Get-Ancestors $script:forkHead)) 'Upstream is missing.'
    Assert ((Post-Count) -eq 1) 'Expected one merge.'
}
Test 'Identical histories need no write' {
    $script:forkHead = $upstreamSha
    Assert (Sync-Fork -Required) 'No-op failed.'
    Assert ((Post-Count) -eq 0) 'Unnecessary write.'
}
Test 'Own commits on a current upstream need no write' {
    $script:parents[$forkSha] = @($upstreamSha)
    Assert (Sync-Fork -Required) 'Ahead-only fork should be accepted.'
    Assert-Preserved
    Assert ((Post-Count) -eq 0) 'Unnecessary write.'
}
Test 'Repeating a successful synchronization does not merge again' {
    Assert (Sync-Fork -Required) 'First sync failed.'
    Assert (Sync-Fork -Required) 'Repeated sync failed.'
    Assert-Preserved
    Assert ((Post-Count) -eq 1) 'Repeated sync wrote again.'
}
Test 'An empty merge response succeeds only after verified readback' {
    $script:mergeMode = 'empty-response'
    Assert (Sync-Fork -Required) 'Valid empty response rejected.'
    Assert-Preserved
}
Test 'A merge conflict stops without another mutation' {
    $script:mergeError = 'HTTP-Status: 409. Merge conflict'
    Assert-Throws { Sync-Fork -Required } '409.*Merge conflict'
    Assert ((Post-Count) -eq 1 -and $script:forkHead -eq $forkSha) 'Conflict must preserve the fork and stop.'
}
Test 'Missing workflow scope retains the actionable error' {
    $script:mergeError = 'refusing to allow a Personal Access Token without workflow scope'
    Assert-Throws { Sync-Fork -Required } 'workflow-Scope'
    Assert ((Post-Count) -eq 1) 'Permission failure must not retry a mutation.'
}
Test 'Losing the original fork history is not reported as success' {
    $script:mergeMode = 'lose-fork'
    Assert-Throws { Sync-Fork -Required } 'Fork-Verlauf ist nicht vollständig erhalten'
    Assert ((Post-Count) -eq 1) 'History failure must not cause another write.'
}
Test 'A successful HTTP response without upstream ancestry fails' {
    $script:mergeMode = 'omit-upstream'
    Assert-Throws { Sync-Fork -Required } 'Upstream ist noch nicht vollständig enthalten'
    Assert ((Post-Count) -eq 1) 'Incomplete merge must stop.'
}
Test 'Upstream advancement causes a new pinned merge and verification' {
    $script:moveUpstream = 'once'
    Assert (Sync-Fork -Required) 'Advancing upstream did not recover.'
    Assert-Preserved
    Assert ((Post-Count) -eq 2 -and $script:sleeps.Count -eq 1) 'Expected one bounded retry.'
}
Test 'Continuously changing upstream stops after three attempts' {
    $script:moveUpstream = 'always'
    Assert-Throws { Sync-Fork -Required } 'bei drei Prüfungen geändert'
    Assert ((Post-Count) -eq 3 -and $script:sleeps.Count -eq 2) 'Retry bound was not respected.'
    Assert ($forkSha -in @(Get-Ancestors $script:forkHead)) 'Retries lost fork history.'
}
Test 'A different fork repository is rejected before writes' {
    $script:fork.full_name = 'someone/winget-pkgs'
    Assert-Throws { Sync-Fork -Required } 'nicht der erwartete Fork'
    Assert ((Post-Count) -eq 0) 'Unexpected fork was modified.'
}
Test 'A non-fork repository is rejected before writes' {
    $script:fork.fork = $false
    Assert-Throws { Sync-Fork -Required } 'nicht der erwartete Fork'
    Assert ((Post-Count) -eq 0) 'Non-fork was modified.'
}
Test 'An unexpected parent is rejected before writes' {
    $script:fork.parent.full_name = 'someone/winget-pkgs'
    Assert-Throws { Sync-Fork -Required } 'nicht der erwartete Fork'
    Assert ((Post-Count) -eq 0) 'Unexpected upstream was merged.'
}
Test 'An unexpected upstream repository is rejected before writes' {
    $script:upstream.full_name = 'someone/winget-pkgs'
    Assert-Throws { Sync-Fork -Required } 'nicht den erwarteten Upstream-Branch'
    Assert ((Post-Count) -eq 0) 'Unexpected upstream was merged.'
}
Test 'A changed fork default branch is rejected before writes' {
    $script:fork.default_branch = 'main'
    Assert-Throws { Sync-Fork -Required } 'nicht der erwartete Fork'
    Assert ((Post-Count) -eq 0) 'Unexpected branch was modified.'
}
Test 'A changed upstream default branch is rejected before writes' {
    $script:upstream.default_branch = 'main'
    Assert-Throws { Sync-Fork -Required } 'nicht den erwarteten Upstream-Branch'
    Assert ((Post-Count) -eq 0) 'Unexpected branch was merged.'
}
Test 'A malformed branch SHA is rejected before writes' {
    $script:refOverride = [pscustomobject]@{ ref='refs/heads/master'; object=[pscustomobject]@{ type='commit'; sha='master' } }
    Assert-Throws { Sync-Fork -Required } 'Ungültiger Branch-Verweis'
    Assert ((Post-Count) -eq 0) 'Unpinned branch was used.'
}
Test 'An unexpected branch reference is rejected before writes' {
    $script:refOverride = [pscustomobject]@{ ref='refs/heads/main'; object=[pscustomobject]@{ type='commit'; sha=$forkSha } }
    Assert-Throws { Sync-Fork -Required } 'Ungültiger Branch-Verweis'
    Assert ((Post-Count) -eq 0) 'Unexpected branch reference was used.'
}
Test 'An inconsistent comparison is rejected before writes' {
    $script:badComparison = $true
    Assert-Throws { Sync-Fork -Required } 'Widersprüchlicher Commit-Vergleich'
    Assert ((Post-Count) -eq 0) 'Malformed comparison permitted a write.'
}
Test 'Required synchronization cannot be skipped' {
    $script:SkipForkSync = $true
    Assert-Throws { Sync-Fork -Required } 'nicht übersprungen'
    Assert ($script:requests.Count -eq 0) 'Skip guard reached the API.'
}
Test 'Required synchronization needs the submission credential' {
    $env:WINGET_CREATE_GITHUB_TOKEN = ''
    Assert-Throws { Sync-Fork -Required } 'TOKEN fehlt'
    Assert ($script:requests.Count -eq 0) 'Missing credential reached the API.'
}
Write-Host "Fork-sync regression tests: $script:passed passed; no network or submission."
