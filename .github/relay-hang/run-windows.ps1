<#
.SYNOPSIS
Builds and repeats this branch's connect tests with bounded failure capture.
.DESCRIPTION
The workflow sets variant, repetitions, watchdogs and dump limits through RELAY_*
environment variables. Baseline uses unchanged source. Shared-handle and
split-shutdown each apply one standalone patch to 5f5323c, without probes.
Buffered records three stalled upgrades in fixed memory buffers. The two
after-shutdown variants use the same probes and gate one side's first receive
until shutdown returns, bounded by 2 s of real time.
All runs use --nocapture and libtest's
default thread count. Failures and hangs do not stop later repetitions.

Each run writes run-NNN.stdout, run-NNN.stderr and run-NNN.status.json. The timeline
JSONL timestamps output chunks when observed by the harness, with polling and
scheduling delay. Buffered variants write run-NNN.probe only after all three
observed server reads, worker joins and initial shutdown calls have returned.
Earlier hangs retain the static buffers in the existing process dump.
Probe slots 0, 1 and 2 are close_during_join, hold_deadline and stalled_join_cause.
Actors 0, 1, 2 and 3 are worker, shutdown, server and test. The probe header maps
event numbers to names. Sort records by ns to compare actors. Timestamps bracket
Rust calls, not kernel entry. Negative values are native errors, with -1 for an
error without a native code; receive successes carry byte counts.

Run 4 schedules 30 complete binary runs in each of two shards per variant.
The baseline measures the failure rate without probes. Shared-handle removes
only the blocking stream's duplicated shutdown handle. Split-shutdown changes
only the shutdown call sequence. These variants contain no memory probes.
Buffered keeps the original shutdown behavior and records results in memory.
Worker-after-shutdown gates the native worker read after its timeout is set.
Server-after-shutdown gates the server read after its stalled notification.
A gate records whether its 2 s wait succeeded. If a deadline prevents a worker
read, join_exit and read_deadline_error record that path instead.

Compare buffered failures with baseline before interpreting the gated arms.
A trigger without timely shutdown suggests application scheduling or locking.
A failed shutdown identifies its native error. A successful shutdown followed
by server timeout narrows the failure to the socket/receive path; user-space
events alone do not prove whether TCP emitted a FIN. Compare the two ordered
arms to isolate receive/shutdown overlap on each endpoint. Zero failures in an
instrumented arm are inconclusive if its probes suppress baseline failures.
No short SO_RCVTIMEO retry loop is tested, since Windows considers a connection
indeterminate after a blocking receive timeout.

Output is forwarded to the Actions log while the test runs. A watchdog expiry records
outcome timeout, captures a dump up to RELAY_MAX_DUMPS times per job, and kills
the process tree. A returned nonzero exit records outcome failed. A server panic
can appear in stderr followed by timeout if the parent test remains blocked.

summary.json records every outcome and any repetitions skipped by the job budget.
The artifact also holds the tested executable, PDB symbols, applied patch, build
logs and source, toolchain and runner metadata. ProcDump diagnostics accompany
each attempted dump. The test source baseline is cli commit 5f5323c.
#>
param(
    [Parameter(Mandatory)][ValidateSet('Prepare', 'Run')][string]$Stage,
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$Evidence,
    [Parameter(Mandatory)][string]$TargetDirectory
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Set-StrictMode -Version Latest

# Validate the workflow settings before launching any process
$variant = $env:RELAY_VARIANT
if ($variant -notin @('baseline', 'shared-handle', 'split-shutdown', 'buffered',
    'worker-after-shutdown', 'server-after-shutdown')) {
    throw 'Unsupported RELAY_VARIANT'
}
$repetitions = if ($variant -eq 'baseline') {
    [int]$env:RELAY_BASELINE_REPETITIONS
} else {
    [int]$env:RELAY_OTHER_REPETITIONS
}
$watchdogSeconds = [int]$env:RELAY_WATCHDOG_SECONDS
$dumpTimeoutSeconds = [int]$env:RELAY_DUMP_TIMEOUT_SECONDS
$maxDumps = [int]$env:RELAY_MAX_DUMPS
$runBudgetSeconds = [int]$env:RELAY_RUN_BUDGET_SECONDS
if ($repetitions -lt 1 -or $repetitions -gt 100 -or $watchdogSeconds -lt 1 -or
    $watchdogSeconds -gt 60 -or $dumpTimeoutSeconds -lt 1 -or $dumpTimeoutSeconds -gt 30 -or
    $maxDumps -lt 0 -or $maxDumps -gt 10 -or $runBudgetSeconds -lt 1 -or $runBudgetSeconds -gt 900) {
    throw 'RELAY_* settings are outside the supported experiment bounds'
}
$repositoryFolder = (Resolve-Path -LiteralPath $Repository).Path
$evidenceFolder = (New-Item -ItemType Directory -Force -Path $Evidence).FullName
$targetFolder = (New-Item -ItemType Directory -Force -Path $TargetDirectory).FullName
$env:CARGO_TARGET_DIR = $targetFolder

# Remove the key entirely so libtest selects its default thread count
Remove-Item -LiteralPath Env:RUST_TEST_THREADS -ErrorAction SilentlyContinue
if ([Environment]::GetEnvironmentVariables().Contains('RUST_TEST_THREADS')) {
    throw 'RUST_TEST_THREADS must be absent, including an empty value'
}
Set-Location -LiteralPath $repositoryFolder
$metadataFile = Join-Path $evidenceFolder 'build-metadata.json'

function Stop-TestProcess {
    <# .SYNOPSIS
    Kills a remaining process tree and bounds exit and redirected-output completion.
    #>
    param([System.Diagnostics.Process]$Process)
    if (-not $Process.HasExited) {
        $Process.Kill($true)
    }
    if (-not $Process.WaitForExitAsync().Wait(5000)) {
        throw "Process $($Process.Id) did not finish exit and output handling"
    }
}

function Open-OutputReader {
    <# .SYNOPSIS
    Opens a live process log without preventing its writer from appending.
    #>
    param([string]$File)
    $stream = [System.IO.File]::Open($File, 'Open', 'Read', 'ReadWrite')
    return [System.IO.StreamReader]::new($stream)
}

function Write-ProcessOutput {
    <# .SYNOPSIS
    Forwards newly appended test output to the Actions log without consuming it.
    #>
    param(
        [System.IO.StreamReader]$StandardOutput,
        [System.IO.StreamReader]$StandardError,
        [System.Diagnostics.Stopwatch]$Clock,
        [System.IO.StreamWriter]$Timeline
    )
    foreach ($name in @('stdout', 'stderr')) {
        $reader = if ($name -eq 'stdout') { $StandardOutput } else { $StandardError }
        if ($null -eq $reader) { continue }
        $chunk = $reader.ReadToEnd()
        if ($chunk.Length -eq 0) { continue }
        $Timeline.WriteLine((@{
            elapsed_seconds = $Clock.Elapsed.TotalSeconds; stream = $name; text = $chunk
        } | ConvertTo-Json -Compress))
        if ($name -eq 'stdout') { [Console]::Out.Write($chunk) } else { [Console]::Error.Write($chunk) }
    }
}

function Save-ProcessDump {
    <# .SYNOPSIS
    Captures a stuck process and bounds the dump utility independently.
    #>
    param([int]$ProcessId, [string]$Stem, [string]$DumpTool, [int]$TimeoutSeconds)
    $dump = $null
    try {
        # Start-Process joins its arguments, so quote the output path explicitly
        $dumpFile = "$Stem.dmp"
        $arguments = @('-accepteula', '-ma', '-at', [string]$TimeoutSeconds,
            [string]$ProcessId, ('"' + $dumpFile + '"'))
        $dump = Start-Process -FilePath $DumpTool -ArgumentList $arguments -PassThru `
            -RedirectStandardOutput "$Stem.procdump.stdout" -RedirectStandardError "$Stem.procdump.stderr"
        if (-not $dump.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-TestProcess $dump
            return 'capture_timeout'
        }
        # Preserve a dump independently of the utility's exit-code convention
        if (Test-Path -LiteralPath $dumpFile -PathType Leaf) {
            $file = [System.IO.File]::OpenRead($dumpFile)
            try {
                $magic = [byte[]]::new(4)
                if ($file.Length -ge 32 -and $file.Read($magic, 0, 4) -eq 4 -and
                    [System.Text.Encoding]::ASCII.GetString($magic) -eq 'MDMP') {
                    if ($dump.ExitCode -eq 0) { return 'captured' }
                    return "dump_present_exit_$($dump.ExitCode)"
                }
            } finally { $file.Dispose() }
        }
        return "capture_failed_exit_$($dump.ExitCode)"
    } catch {
        $_ | Out-File -LiteralPath "$Stem.procdump.error" -Encoding utf8
        return 'capture_error'
    } finally {
        if ($null -ne $dump) {
            Stop-TestProcess $dump
            $dump.Dispose()
        }
    }
}

if ($Stage -eq 'Prepare') {
    # Record the branch commit and environment without dumping environment secrets
    $revision = & git rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Could not identify the checked-out commit' }
    & rustc -Vv 1> (Join-Path $evidenceFolder 'toolchain.txt') 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Could not identify rustc' }
    $PSVersionTable | Out-String | Out-File (Join-Path $evidenceFolder 'powershell.txt') -Encoding utf8
    Get-ComputerInfo | Out-File (Join-Path $evidenceFolder 'machine.txt') -Encoding utf8
    @{
        baseline = '5f5323c'; revision = $revision; variant = $variant; shard = $env:RELAY_SHARD
        image_os = $env:ImageOS; image_version = $env:ImageVersion
        runner_os = $env:RUNNER_OS; runner_arch = $env:RUNNER_ARCH
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidenceFolder 'subject.json') -Encoding utf8

    # Each variant starts from the unchanged source at the fixed baseline
    & git diff --exit-code 5f5323c -- . ':!.github/relay-hang' ':!.github/workflows/relay-hang-experiment.yml'
    if ($LASTEXITCODE -ne 0) { throw 'Source does not match the 5f5323c baseline' }
    $patches = switch ($variant) {
        'baseline' { @() }
        'shared-handle' { @('shared-handle.patch') }
        'split-shutdown' { @('split-shutdown.patch') }
        'buffered' { @('buffered.patch') }
        'worker-after-shutdown' { @('buffered.patch') }
        'server-after-shutdown' { @('buffered.patch') }
    }
    foreach ($patchName in $patches) {
        $patchFile = Join-Path $PSScriptRoot $patchName
        & git apply --index --check $patchFile
        if ($LASTEXITCODE -ne 0) { throw "Cannot apply $patchName to this branch" }
        & git apply --index $patchFile
        if ($LASTEXITCODE -ne 0) { throw "Could not apply $patchName" }
        Copy-Item -LiteralPath $patchFile -Destination $evidenceFolder
    }
    & git diff HEAD --no-ext-diff | Out-File (Join-Path $evidenceFolder 'applied.patch') -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw 'Could not record the applied patch' }

    # Obtain the dump utility before testing so a hang can be captured immediately
    $dumpArchive = Join-Path $targetFolder 'procdump.zip'
    Invoke-WebRequest https://download.sysinternals.com/files/Procdump.zip -OutFile $dumpArchive -TimeoutSec 30
    $dumpFolder = Join-Path $targetFolder 'procdump'
    Expand-Archive -LiteralPath $dumpArchive -DestinationPath $dumpFolder -Force
    $dumpTool = Join-Path $dumpFolder 'procdump64.exe'
    if (-not (Test-Path -LiteralPath $dumpTool)) { throw 'ProcDump executable is missing' }

    # Build the full connect binary once, taking its path from Cargo's output
    $buildMessages = Join-Path $evidenceFolder 'build.jsonl'
    & cargo test --lib --locked --no-run --message-format=json 1> $buildMessages 2> (Join-Path $evidenceFolder 'build.stderr')
    if ($LASTEXITCODE -ne 0) { throw 'Connect test build failed; inspect build.stderr' }
    $artifact = Get-Content -LiteralPath $buildMessages | ForEach-Object { $_ | ConvertFrom-Json } |
        Where-Object { $_.reason -eq 'compiler-artifact' } |
        Where-Object { $_.target.name -eq 'darkbio_connect' -and $_.executable } |
        Select-Object -Last 1
    if ($null -eq $artifact) { throw 'Cargo did not report the connect test binary' }
    $testBinary = $artifact.executable
    Copy-Item -LiteralPath $testBinary -Destination $evidenceFolder
    $symbols = [System.IO.Path]::ChangeExtension($testBinary, '.pdb')
    if (Test-Path -LiteralPath $symbols) { Copy-Item -LiteralPath $symbols -Destination $evidenceFolder }
    @{
        executable = $testBinary; procdump = $dumpTool; revision = $revision
        variant = $variant; shard = $env:RELAY_SHARD
    } | ConvertTo-Json | Set-Content -LiteralPath $metadataFile -Encoding utf8
    exit 0
}

# Resume the prepared build with a fresh process for every repetition
$metadata = Get-Content -Raw -LiteralPath $metadataFile | ConvertFrom-Json
if ($metadata.variant -ne $variant -or $metadata.shard -ne $env:RELAY_SHARD) {
    throw 'Prepared build does not match this variant and shard'
}
$results = [System.Collections.Generic.List[object]]::new()
$dumpCount = 0
$jobClock = [System.Diagnostics.Stopwatch]::StartNew()
$summaryFile = Join-Path $evidenceFolder 'summary.json'
for ($iteration = 1; $iteration -le $repetitions; $iteration++) {
    if ($jobClock.Elapsed.TotalSeconds -ge $runBudgetSeconds) { break }
    $stem = Join-Path $evidenceFolder ('run-{0:D3}' -f $iteration)
    Write-Host "$variant/$($env:RELAY_SHARD) run $iteration/$repetitions"
    $process = $null
    $stdout = $null
    $stderr = $null
    $elapsed = [System.Diagnostics.Stopwatch]::StartNew()
    $timeline = [System.IO.StreamWriter]::new("$stem.timeline.jsonl", $false)
    $timeline.AutoFlush = $true
    $env:RELAY_PROBE_FILE = "$stem.probe"
    $env:RELAY_PROBE_ORDER = switch ($variant) {
        'worker-after-shutdown' { 'worker-after-shutdown' }
        'server-after-shutdown' { 'server-after-shutdown' }
        default { 'observe' }
    }
    $record = [ordered]@{
        iteration = $iteration; outcome = 'harness_error'; exit_code = $null
        process_id = $null
        probe_file = 'not_applicable'
        started_utc = [DateTime]::UtcNow.ToString('o'); elapsed_seconds = 0.0
        watchdog_seconds = $watchdogSeconds; dump_status = 'not_needed'; error = $null
    }
    try {
        # Leave libtest's test selection and thread count at their defaults
        $process = Start-Process -FilePath $metadata.executable -ArgumentList @('--nocapture') -PassThru `
            -WorkingDirectory $repositoryFolder `
            -RedirectStandardOutput "$stem.stdout" -RedirectStandardError "$stem.stderr"
        $record.process_id = $process.Id
        $stdout = Open-OutputReader "$stem.stdout"
        $stderr = Open-OutputReader "$stem.stderr"
        while (-not $process.WaitForExit(200)) {
            Write-ProcessOutput $stdout $stderr $elapsed $timeline
            if ($elapsed.Elapsed.TotalSeconds -ge $watchdogSeconds) {
                $record.outcome = 'timeout'
                if ($dumpCount -lt $maxDumps) {
                    $dumpCount++
                    $record.dump_status = Save-ProcessDump $process.Id $stem $metadata.procdump $dumpTimeoutSeconds
                } else {
                    $record.dump_status = 'limit_reached'
                }
                break
            }
        }
        if ($record.outcome -ne 'timeout') {
            $record.exit_code = $process.ExitCode
            $record.outcome = if ($process.ExitCode -eq 0) { 'passed' } else { 'failed' }
        }
    } catch {
        $record.error = $_.ToString()
    } finally {
        # Persist each result before starting the next run, including after a hang
        if ($null -ne $process) {
            try {
                Stop-TestProcess $process
            } catch {
                $record.error = $_.ToString()
                if ($record.outcome -eq 'passed') { $record.outcome = 'harness_error' }
            }
        }
        Write-ProcessOutput $stdout $stderr $elapsed $timeline
        $timeline.Dispose()
        if ($null -ne $stdout) { $stdout.Dispose() }
        if ($null -ne $stderr) { $stderr.Dispose() }
        if ($null -ne $process) { $process.Dispose() }
        $elapsed.Stop()
        if ($variant -in @('buffered', 'worker-after-shutdown', 'server-after-shutdown')) {
            $record.probe_file = if (Test-Path -LiteralPath "$stem.probe" -PathType Leaf) {
                'present'
            } else {
                'missing'
            }
        }
        $record.elapsed_seconds = [Math]::Round($elapsed.Elapsed.TotalSeconds, 3)
        $record | ConvertTo-Json | Set-Content -LiteralPath "$stem.status.json" -Encoding utf8
        $results.Add([pscustomobject]$record)
        @{
            variant = $variant; shard = $env:RELAY_SHARD; revision = $metadata.revision
            finished = $false; planned = $repetitions; completed = $results.Count
            results = @($results.ToArray())
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $summaryFile -Encoding utf8
    }
}

# A red job still contains every completed repetition and its diagnostics
$failed = @($results | Where-Object { $_.outcome -ne 'passed' }).Count
$skipped = $repetitions - $results.Count
@{
    variant = $variant; shard = $env:RELAY_SHARD; revision = $metadata.revision
    finished = $true; planned = $repetitions; completed = $results.Count; skipped = $skipped
    passed = $results.Count - $failed
    failed = @($results | Where-Object { $_.outcome -eq 'failed' }).Count
    timeouts = @($results | Where-Object { $_.outcome -eq 'timeout' }).Count
    harness_errors = @($results | Where-Object { $_.outcome -eq 'harness_error' }).Count
    dumps_attempted = $dumpCount; results = @($results.ToArray())
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $summaryFile -Encoding utf8
Write-Host "$variant/$($env:RELAY_SHARD) completed $($results.Count), failed $failed, skipped $skipped"
if ($failed -gt 0 -or $skipped -gt 0) { exit 1 }
exit 0
