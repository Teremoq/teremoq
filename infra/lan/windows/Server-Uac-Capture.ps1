# SPDX-FileCopyrightText: 2026 Teremoq contributors
# SPDX-License-Identifier: Apache-2.0
# A bounded, host-specific PoC exception. This is not a generic native-origin test.

function New-TeremoqServerUacDecision {
    param([Parameter(Mandatory = $true)][string]$RawReport,
          [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Evidence)
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    $bytes = $utf8.GetBytes($RawReport)
    if ($bytes.Length -lt 1 -or $bytes.Length -gt 24576) { throw 'UAC original report exceeds its byte budget' }
    $report = $RawReport | ConvertFrom-Json
    $reportKeys = @('schema_version','report_kind','run_id','source_commit','role','server_ipv4','client_ipv4',
        'prefix_length','network_profile','expected_wsl_mode','maximum_clock_offset_ms','minimum_mtu',
        'minimum_cpu_cores','minimum_memory_mib','minimum_disk_mib','capture_context','checks')
    if (@($report.PSObject.Properties).Count -ne $reportKeys.Count -or
        @($report.PSObject.Properties.Name | Where-Object { $_ -cnotin $reportKeys }).Count -ne 0 -or
        $report.source_commit -cnotmatch '^[0-9a-f]{40}$' -or $report.run_id -cnotmatch '^lan-[a-z0-9][a-z0-9-]{0,31}$') {
        throw 'UAC original report schema mismatch'
    }
    $context = $report.capture_context
    $contextKeys = @('schema_version','current_process_name','parent_process_names','parent_process_count',
        'traversal_depth_limit','traversal_outcome','wsl_environment_keys_present','powershell_edition','powershell_version_major')
    if (@($context.PSObject.Properties).Count -ne $contextKeys.Count -or
        @($context.PSObject.Properties.Name | Where-Object { $_ -cnotin $contextKeys }).Count -ne 0 -or
        $report.schema_version -ne 2 -or $report.report_kind -cne 'teremoq-lan-windows-preflight-v2' -or
        $report.role -cne 'server' -or $context.schema_version -ne 2 -or
        $context.current_process_name -cne 'powershell.exe' -or $context.powershell_edition -cne 'Desktop' -or
        $context.powershell_version_major -ne 5 -or $context.traversal_depth_limit -ne 16 -or
        $context.traversal_outcome -cne 'parent_process_missing' -or $context.parent_process_count -ne 0 -or
        $context.parent_process_names -isnot [array] -or $context.parent_process_names.Count -ne 0 -or
        $context.wsl_environment_keys_present -isnot [array] -or $context.wsl_environment_keys_present.Count -ne 0) {
        throw 'UAC warning requires the exact original server missing-parent observation'
    }
    foreach ($field in @('schema_version','powershell_version_major','traversal_depth_limit','parent_process_count')) {
        if ($context.$field -isnot [int] -and $context.$field -isnot [long]) { throw 'UAC context integer type mismatch' }
    }
    $expected = [ordered]@{
        collector='preflight-lan-same-process-v1'; elevated=$true; architecture='x64'
        host_path='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        host_sha256='3247bcfd60f6dd25f34cb74b5889ab10ef1b3ec72b4d4b3d95b5b25b534560b8'
        checkout_kind='local-clean-git'; source_commit=$report.source_commit
        configuration_binding='original-report-sha256'
    }
    if ($Evidence.Count -ne $expected.Count -or $Evidence.elevated -isnot [bool]) { throw 'UAC independent evidence schema mismatch' }
    foreach ($key in $expected.Keys) {
        if (-not $Evidence.Contains($key) -or $Evidence[$key] -cne $expected[$key]) { throw 'UAC independent evidence binding mismatch' }
    }
    # The report is freshly emitted by Preflight-Lan in this process, not imported
    # from an arbitrary operator file. Every other material check stays blocking.
    $seen = @{}
    $checkNames = @('windows_caption','windows_version','configured_private_ip_present','network_profile',
        'capture_origin','wifi_adapter','wifi_link_speed','wifi_radio','wifi_band','wsl_mode','expected_wsl_mode_gate',
        'clock_offset','mtu','logical_cpu','physical_memory_mib','free_disk_mib','browser_msedge.exe','browser_chrome.exe',
        'docker_server','docker_publication_inventory','wslconfig_present','preflight_gate',
        'listener_udp_4433','listener_udp_9000','listener_udp_14433','listener_udp_19000',
        'listener_tcp_4433','listener_tcp_5678','listener_tcp_6379','listener_tcp_11434','listener_tcp_18443')
    foreach ($check in $report.checks) {
        if (@($check.PSObject.Properties).Count -ne 4 -or
            @($check.PSObject.Properties.Name | Where-Object { $_ -cnotin @('check','status','value','evidence_quality') }).Count -ne 0 -or
            $check.check -cnotin $checkNames) { throw 'UAC original check schema mismatch' }
        if ($seen.ContainsKey($check.check)) { throw 'Duplicate preflight check' }
        $seen[$check.check] = $true
        if ($check.check -cin @('capture_origin','preflight_gate')) {
            $value = if ($check.check -ceq 'capture_origin') { 'wsl_or_ambiguous_capture' } else { 'blocked' }
            if ($check.status -cne 'blocked' -or $check.value -cne $value -or $check.evidence_quality -cne 'real') {
                throw 'UAC original blocked check mismatch'
            }
        } elseif ($check.check -cin @('windows_caption','windows_version','wifi_link_speed','wifi_radio','wifi_band',
                    'wsl_mode','browser_msedge.exe','browser_chrome.exe','docker_server')) {
            if ($check.status -cnotin @('pass','observed')) { throw 'UAC decision cannot relax another check' }
        } elseif ($check.status -cnotin @('pass','observed') -or $check.evidence_quality -cnotin @('real','configured') -or
            $check.value -match '(?i)(^|[^a-z])(blocked|pending|unavailable|unknown|not_measured|occupied)($|[^a-z])') {
            throw 'UAC decision cannot relax another check'
        }
    }
    if ($seen.Count -ne $checkNames.Count) { throw 'UAC original check set incomplete' }
    $ipCheck = @($report.checks | Where-Object { $_.check -ceq 'configured_private_ip_present' })[0]
    if ($ipCheck.status -cne 'pass' -or $ipCheck.value -cne $report.server_ipv4 -or $ipCheck.evidence_quality -cne 'real') {
        throw 'UAC decision requires the exact measured server IP'
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    return [ordered]@{
        schema_version=1; report_kind='teremoq-server-uac-capture-decision-v1'
        disposition='warning:verified-elevated-host-parent-unobserved'
        raw_preflight_utf8=$RawReport; raw_preflight_sha256=$digest; independent_evidence=$Evidence
    }
}

function Get-TeremoqServerUacEvidence {
    param([Parameter(Mandatory = $true)][string]$CheckoutRoot,
          [Parameter(Mandatory = $true)][string]$SourceCommit)
    if ($PSVersionTable.PSEdition -cne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or
        [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitProcess) {
        throw 'UAC exception requires the reviewed native Desktop5 x64 host'
    }
    foreach ($key in @('WSLENV','WSL_INTEROP','WSL_DISTRO_NAME')) {
        if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($key))) { throw 'WSL evidence rejects UAC exception' }
    }
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'UAC exception requires measured elevation' }
    $hostPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $process = [Diagnostics.Process]::GetCurrentProcess()
    try {
        if (-not [string]::Equals($process.MainModule.FileName, $hostPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'UAC process executable differs from the reviewed host'
        }
    } finally { $process.Dispose() }
    foreach ($path in @($hostPath, $CheckoutRoot)) {
        if ($path -notmatch '^[A-Za-z]:\\' -or $path.StartsWith('\\')) { throw 'UAC evidence requires local Windows paths' }
        $entry = Get-Item -LiteralPath $path -Force
        while ($null -ne $entry) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'UAC evidence rejects reparse paths' }
            $parent = Split-Path -Parent $entry.FullName
            if (-not $parent -or $parent -ceq $entry.FullName) { break }
            $entry = Get-Item -LiteralPath $parent -Force
        }
    }
    $hostHash = (Get-FileHash -LiteralPath $hostPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hostHash -cne '3247bcfd60f6dd25f34cb74b5889ab10ef1b3ec72b4d4b3d95b5b25b534560b8') { throw 'UAC host hash is not the reviewed host build' }
    # No caller-supplied evidence flags; all facts below are measured here.
    foreach ($key in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'GIT_*' })) {
        throw 'UAC source verification rejects Git environment overrides'
    }
    $git = Join-Path $env:ProgramFiles 'Git\cmd\git.exe'
    $top = (& $git -C $CheckoutRoot rev-parse --show-toplevel | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not [string]::Equals([IO.Path]::GetFullPath($top),
        [IO.Path]::GetFullPath($CheckoutRoot), [StringComparison]::OrdinalIgnoreCase)) { throw 'UAC checkout root mismatch' }
    $head = (& $git -C $CheckoutRoot rev-parse HEAD | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $head -cne $SourceCommit -or $head -cnotmatch '^[0-9a-f]{40}$') { throw 'UAC checkout commit mismatch' }
    $status = (& $git -C $CheckoutRoot status --porcelain --untracked-files=normal | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $status) { throw 'UAC checkout must be clean' }
    return [ordered]@{
        collector='preflight-lan-same-process-v1'; elevated=$true; architecture='x64'
        host_path=$hostPath; host_sha256=$hostHash; checkout_kind='local-clean-git'
        source_commit=$head; configuration_binding='original-report-sha256'
    }
}

function Write-TeremoqNewCaptureFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    if ($Path -notmatch '^[A-Za-z]:\\') { throw 'Capture output must be an absolute local Windows path' }
    $parent = Get-Item -LiteralPath (Split-Path -Parent $Path) -Force
    if (-not $parent.PSIsContainer) { throw 'Capture parent must exist' }
    while ($null -ne $parent) {
        if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Capture output rejects reparse paths' }
        $next = Split-Path -Parent $parent.FullName
        if (-not $next -or $next -ceq $parent.FullName) { break }
        $parent = Get-Item -LiteralPath $next -Force
    }
    $bytes = (New-Object Text.UTF8Encoding($false, $true)).GetBytes($Text)
    if ($bytes.Length -gt 65536) { throw 'Capture output exceeds byte budget' }
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}
