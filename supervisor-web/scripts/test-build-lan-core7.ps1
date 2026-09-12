# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
# Focal SERVER fixtures only. No build, Git update, player, listener or LAN run.
# Run only after Platform acknowledges the selected runtime installation.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$webRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $webRoot
$builder = Join-Path $webRoot 'lan-player/Build-LanPlayerFromGit.ps1'
$source = [IO.File]::ReadAllText($builder)
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'builder parse failed' }
$guardStart = $source.IndexOf('$ErrorActionPreference =')
$guardEnd = $source.IndexOf('# The bounded parent process accepts UTF-8')
if ($guardStart -lt 0 -or $guardEnd -le $guardStart) { throw 'builder guard boundary changed' }
$guard = [scriptblock]::Create($source.Substring($guardStart, $guardEnd - $guardStart))

# Execute the unchanged production guard in this REAL host, before test effects.
$environmentKeys = @('PATH','PATHEXT','ComSpec','GIT_CONFIG_NOSYSTEM','GIT_CONFIG_GLOBAL')
$beforeEnvironment = @($environmentKeys | ForEach-Object { [Environment]::GetEnvironmentVariable($_) })
$beforeLocation = (Get-Location).Path
$beforeEncoding = [Console]::OutputEncoding.CodePage
& $guard
if ((Get-Location).Path -cne $beforeLocation -or [Console]::OutputEncoding.CodePage -ne $beforeEncoding) {
    throw 'runtime guard changed location/encoding'
}
for ($index = 0; $index -lt $environmentKeys.Count; $index++) {
    if ([Environment]::GetEnvironmentVariable($environmentKeys[$index]) -cne $beforeEnvironment[$index]) {
        throw 'runtime guard changed environment'
    }
}
$results = [Collections.Generic.List[string]]::new()
$results.Add('real-selected-host-guard-no-environment-location-encoding-effects')

# Negative versions/architectures are predicate fixtures, NOT claims of running
# PS5, 7.6.5, Linux or ARM. Extract the production predicate, do not copy its policy.
$hostIf = $ast.Find({ param($item)
    $item -is [Management.Automation.Language.IfStatementAst] -and
    $item.Extent.Text.StartsWith('if ($PSVersionTable.PSEdition')
}, $true)
if ($null -eq $hostIf) { throw 'runtime predicate not found' }
$predicate = $hostIf.Clauses[0].Item1.Extent.Text.Replace('$PSVersionTable', '$Fixture.VersionTable').
    Replace('[Environment]::OSVersion.Platform', '$Fixture.Platform').
    Replace('[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture', '$Fixture.Architecture')
$rejects = [scriptblock]::Create('param($Fixture) [bool](' + $predicate + ')')
foreach ($case in @(
    @('Desktop','5.1','Win32NT','X64', $true),
    @('Core','7.6.5','Win32NT','X64', $true),
    @('Core','7.7.0','Win32NT','X64', $true),
    @('Core','7.6.6','Unix','X64', $true),
    @('Core','7.6.6','Win32NT','X86', $true),
    @('Core','7.6.6','Win32NT','Arm64', $true),
    @('Core','7.6.6','Win32NT','X64', $false)
)) {
    $fixture = @{ VersionTable=@{ PSEdition=$case[0]; PSVersion=[version]$case[1] }
        Platform=[PlatformID]$case[2]; Architecture=$case[3] }
    if ((& $rejects $fixture) -ne $case[4]) { throw 'host predicate fixture mismatch' }
    $results.Add('host-predicate-' + ($case[0..3] -join '-'))
}
foreach ($operation in @('[Console]::OutputEncoding =','. $distributionLibrary',
        'Invoke-TeremoqBoundedNativeProcess -FilePath $node','Push-Location -LiteralPath $project','$env:PATH =')) {
    if ($source.IndexOf($operation) -le $guardEnd) { throw 'effect precedes runtime guard' }
}
if ($source.Contains("'powershell.exe'") -or $source.Contains('System32\WindowsPowerShell')) {
    throw 'legacy host fallback remains'
}
$results.Add('source-order-before-helpers-probes-environment-no-legacy-fallback')

foreach ($case in @(
    @{ Prefix='if (-not [string]::Equals($hostExecutable'; Variables='param($hostExecutable,$powerShell)';
       Good=@('C:\selected\pwsh.exe','C:\selected\pwsh.exe'); Bad=@('C:\other\pwsh.exe','C:\selected\pwsh.exe'); Name='executable-mismatch' },
    @{ Prefix='if ($hostEntry.PSIsContainer'; Variables='param($hostEntry)';
       Good=@([pscustomobject]@{ PSIsContainer=$false; Attributes=[IO.FileAttributes]::Normal });
       Bad=@([pscustomobject]@{ PSIsContainer=$false; Attributes=[IO.FileAttributes]::ReparsePoint }); Name='reparse-executable' }
)) {
    $statement = $ast.Find({ param($item)
        $item -is [Management.Automation.Language.IfStatementAst] -and $item.Extent.Text.StartsWith($case.Prefix)
    }, $true)
    if ($null -eq $statement) { throw 'executable predicate not found' }
    $test = [scriptblock]::Create($case.Variables + ' [bool](' + $statement.Clauses[0].Item1.Extent.Text + ')')
    $good = $case.Good
    $bad = $case.Bad
    if ((& $test @good) -or -not (& $test @bad)) { throw 'executable predicate fixture mismatch' }
    $results.Add('host-predicate-' + $case.Name)
}

# Existing production process boundary; only fixture children are started below.
$library = Join-Path $repoRoot 'infra/lan/client/Client-Distribution.ps1'
. $library
$selectedHost = Join-Path $PSHOME 'pwsh.exe'
$node = Join-Path $env:ProgramFiles 'nodejs/node.exe'
if (-not (Test-Path -LiteralPath $node -PathType Leaf)) { throw 'server Node prerequisite missing' }
$nodeVersion = Invoke-TeremoqBoundedNativeProcess -FilePath $node -WorkingDirectory $webRoot `
    -Arguments @('--version') -TimeoutMilliseconds 30000 -StdoutMaxBytes 128 -StderrMaxBytes 4096
if ($nodeVersion.ExitCode -ne 0 -or $nodeVersion.Stderr -ne '' -or $nodeVersion.Stdout.Trim() -cnotmatch '^v22[.][0-9]+[.][0-9]+$') {
    throw 'server Node 22 prerequisite failed'
}
$outputRoot = Join-Path $webRoot ('evidence/managed-v2-core7-' + [guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $outputRoot) { throw 'test output must be new' }
$fixtureRoot = Join-Path $outputRoot 'node_modules'
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$argvScript = Join-Path $fixtureRoot 'echo argv.ps1'
[IO.File]::WriteAllText($argvScript, '[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); [Console]::Out.Write((ConvertTo-Json -InputObject @($args) -Compress))', $utf8)
$expected = @('plain', 'two words', 'a"b', 'C:\space path\', 'ñ 日本語', '; & $() literal', '-flag')
foreach ($target in @('core7', 'node')) {
    if ($target -eq 'core7') {
        $executable = $selectedHost
        $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-File',$argvScript) + $expected
    } else {
        $executable = $node
        $arguments = @('-e','process.stdout.write(JSON.stringify(process.argv.slice(1)))','--') + $expected
    }
    $result = Invoke-TeremoqBoundedNativeProcess -FilePath $executable -WorkingDirectory $webRoot `
        -Arguments $arguments -TimeoutMilliseconds 30000 -StdoutMaxBytes 16384 -StderrMaxBytes 4096
    if ($result.ExitCode -ne 0 -or $result.Stderr -ne '') { throw 'argv fixture process failed' }
    $observed = ConvertFrom-Json -InputObject $result.Stdout -NoEnumerate
    # Preserve the JSON array instead of pipeline enumeration.
    if ($observed.Count -ne $expected.Count) { throw 'argv cardinality changed' }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        if ($observed[$index] -cne $expected[$index]) { throw 'argv bytes changed' }
    }
    $results.Add('real-' + $target + '-argv-json-roundtrip')
}
# The existing mandatory string[] boundary rejects empty arguments. Preserve
# that limitation; no required builder argument is empty, so do not widen it.
$emptyRejected = $false
try {
    $unexpected = Invoke-TeremoqBoundedNativeProcess -FilePath $node -WorkingDirectory $webRoot `
        -Arguments @('-e','process.exit(97)','') -TimeoutMilliseconds 30000 -StdoutMaxBytes 4096 -StderrMaxBytes 4096
} catch {
    if ($_.FullyQualifiedErrorId -cne 'ParameterArgumentValidationErrorEmptyStringNotAllowed,Invoke-TeremoqBoundedNativeProcess') { throw }
    $emptyRejected = $true
}
if (-not $emptyRejected) { throw 'empty argv unexpectedly crossed the existing parameter binding' }
$results.Add('empty-argv-rejected-before-child-by-existing-parameter-binding')

# Whole builder rejection in Core7; invalid input must never reach Node/Git/build.
$absentState = Join-Path $fixtureRoot 'must remain absent'
$failure = Invoke-TeremoqBoundedNativeProcess -FilePath $selectedHost -WorkingDirectory $webRoot `
    -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-File',$builder,
        '-CheckoutRoot',$repoRoot,'-StateRoot',$absentState,'-RepositoryUrl','https://invalid.example/test',
        '-RepositoryRef','refs/heads/fixture','-SourceCommit',('1' * 40),'-BuildMode','node') `
    -TimeoutMilliseconds 30000 -StdoutMaxBytes 4096 -StderrMaxBytes 16384
if ($failure.ExitCode -eq 0 -or (Test-Path -LiteralPath $absentState) -or
    -not $failure.Stderr.Contains('LAN Git distribution parameters are outside the closed policy')) {
    throw 'invalid-input rejection did not happen before StateRoot effects'
}
$results.Add('real-core7-whole-builder-invalid-input-no-state-created')

# Reuse/identity/mode and closed JSON are the existing production JS canaries.
# This is a contract test, not reuse of a built or measured player artifact.
$canaryPath = Join-Path $PSScriptRoot 'lan-distribution-contract.canary.mjs'
$canary = Invoke-TeremoqBoundedNativeProcess -FilePath $node -WorkingDirectory $webRoot `
    -Arguments @($canaryPath) -TimeoutMilliseconds 30000 -StdoutMaxBytes 4096 -StderrMaxBytes 4096
if ($canary.ExitCode -ne 0 -or $canary.Stderr -ne '' -or $canary.Stdout.Trim() -cne 'lan-distribution-contract-test: PASS') {
    throw 'identity/reuse/closed-JSON canary failed'
}
$results.Add('real-node-existing-closed-json-identity-reuse-node-one-or-zero-contract-canary')
$report = [ordered]@{ schema_version=1; kind='server-contract-fixtures-not-lan-not-build'
    powershell_version=$PSVersionTable.PSVersion.ToString(); edition=$PSVersionTable.PSEdition
    architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    node_version=$nodeVersion.Stdout.Trim(); builder_sha256=(Get-FileHash -LiteralPath $builder).Hash.ToLowerInvariant()
    process_helper_sha256=(Get-FileHash -LiteralPath $library).Hash.ToLowerInvariant()
    tests=@($results); result='PASS'; builds_executed=0; lan_runs_executed=0 }
[IO.File]::WriteAllText((Join-Path $outputRoot 'result.json'), (($report | ConvertTo-Json -Depth 5) + "`n"), $utf8)
Write-Output ('Core7 focal fixtures PASS; report: ' + (Join-Path $outputRoot 'result.json'))
