[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [string]$Manifest = 'docs/factory/tasks.json',
    [switch]$ApprovedPlan,
    [switch]$Preview
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath $Repository).Path
$inside = & git -C $repo rev-parse --is-inside-work-tree 2>$null
if ($LASTEXITCODE -ne 0 -or $inside -ne 'true') { throw 'Target must be a Git repository.' }
$manifestPath = if ([IO.Path]::IsPathRooted($Manifest)) { $Manifest } else { Join-Path $repo $Manifest }
$config = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if ($config.tasks -isnot [array] -or $config.tasks.Count -eq 0 -or $config.checks -isnot [array] -or $config.checks.Count -eq 0) { throw 'Manifest requires nonempty arrays of tasks and mandatory PowerShell checks.' }
foreach ($check in $config.checks) {
    if ($check -isnot [string] -or [string]::IsNullOrWhiteSpace($check)) { throw 'Mandatory checks must be nonempty PowerShell command strings.' }
}
if ($null -ne $config.completedTaskIds -and $config.completedTaskIds -isnot [array]) { throw 'completedTaskIds must be an array.' }
$ids = @{}
foreach ($completed in $config.completedTaskIds) {
    if ($completed -isnot [string] -or $completed -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$' -or $ids.ContainsKey($completed)) { throw 'Completed task IDs must be unique safe names.' }
    $ids[$completed] = $true
}
foreach ($task in $config.tasks) {
    if ($task.id -isnot [string] -or $task.id -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$' -or $ids.ContainsKey($task.id)) { throw 'Task IDs must be unique safe names.' }
    $ids[$task.id] = $true
    if ($task.description -isnot [string] -or [string]::IsNullOrWhiteSpace($task.description) -or $task.testCommand -isnot [string] -or [string]::IsNullOrWhiteSpace($task.testCommand) -or $task.acceptanceCriteria -isnot [array] -or $task.acceptanceCriteria.Count -eq 0 -or $task.dependsOn -isnot [array]) { throw "Incomplete or malformed task: $($task.id)" }
    foreach ($criterion in $task.acceptanceCriteria) {
        if ($criterion -isnot [string] -or [string]::IsNullOrWhiteSpace($criterion)) { throw "Acceptance criteria must be nonempty strings: $($task.id)" }
    }
    foreach ($dependency in $task.dependsOn) {
        if ($dependency -isnot [string] -or $dependency -eq $task.id -or -not $ids.ContainsKey($dependency)) { throw 'Dependencies must precede their task.' }
    }
}
if ($Preview) {
    $config.tasks | ForEach-Object { Write-Output "$($_.id): fresh TDD worker -> mandatory checks -> fresh read-only reviewer" }
    return
}
if (-not $ApprovedPlan) { throw 'Review the spec, plan and task manifest; pass -ApprovedPlan to authorize this run.' }
$null = & git -C $repo rev-parse --verify --quiet HEAD
if ($LASTEXITCODE -ne 0) { throw 'Target must have an initial commit before running tasks.' }
$dirty = & git -C $repo status --porcelain
if ($LASTEXITCODE -ne 0 -or $dirty) { throw 'Start from a clean dedicated branch or worktree; commit the spec and manifest first.' }
$branch = & git -C $repo branch --show-current
if (-not $branch -or $branch -in @('main','master')) { throw 'Use a dedicated task branch or worktree.' }
$runId = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$run = Join-Path $repo "docs/factory/runs/$runId"
New-Item -ItemType Directory -Path $run -Force | Out-Null
$schema = Join-Path $PSScriptRoot 'result.schema.json'
function Invoke-Agent([string]$Prompt, [string]$Sandbox, [string]$Output) {
    $Prompt | & codex exec -C $repo -s $Sandbox --ephemeral --json --output-schema $schema -o $Output - 2>&1 |
        Out-File -LiteralPath "$Output.events.jsonl" -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw "Codex failed; inspect $Output.events.jsonl" }
    if (-not (Test-Path -LiteralPath $Output)) { throw 'Agent returned no structured result.' }
    $result = Get-Content -Raw -LiteralPath $Output | ConvertFrom-Json
    if ($result.status -ne 'pass') { throw "Agent blocked or failed: $($result.summary)" }
    return $result
}
foreach ($task in $config.tasks) {
    $base = & git -C $repo rev-parse HEAD
    $taskJson = $task | ConvertTo-Json -Depth 20
    $workerFile = Join-Path $run "$($task.id)-worker.json"
    $workerPrompt = @"
You are a fresh implementation worker for ONE bounded task. Read applicable AGENTS.md and use Osmani test-driven-development and incremental-implementation skills. Task data:
$taskJson
Read docs/factory/spec.md for relevant requirements, and only the files needed for this task. Prior conversation and worker transcripts are unnecessary.
Perform red-green-refactor: write a meaningful acceptance test, run it BEFORE production changes, record its failure and why it represents missing behavior, implement, rerun and refactor. Save exact commands, outputs, and exit codes under $run. If TDD is inapplicable or a prerequisite is missing, return blocked rather than claim success.
Implement only this task. Do not commit, merge, deploy, or modify factory manifests or validation scripts to make checks pass. Return structured status with redExitCode, greenExitCode and evidencePaths relative to the repository. Pass requires a meaningful failing red test and a passing green test.
"@
    $worker = Invoke-Agent $workerPrompt 'workspace-write' $workerFile
    if ($null -eq $worker.redExitCode -or $worker.redExitCode -eq 0 -or $worker.greenExitCode -ne 0) { throw 'Missing red/green TDD evidence.' }
    if (-not $worker.evidencePaths) { throw 'Missing evidence files.' }
    foreach ($evidence in $worker.evidencePaths) {
        $full = [IO.Path]::GetFullPath((Join-Path $repo $evidence))
        if ([IO.Path]::IsPathRooted($evidence) -or -not $full.StartsWith($repo.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $full -PathType Leaf)) { throw 'Invalid or missing evidence file.' }
    }
    $checkIndex = 0
    foreach ($check in $config.checks) {
        $checkIndex++
        $checkScript = Join-Path $run "$($task.id)-check-$checkIndex.ps1"
        # Checks are trusted commands from the human-approved manifest, executed in separate processes.
        $checkLines = @(
            '$ErrorActionPreference = ''Stop'''
            ('Set-Location -LiteralPath ''{0}''' -f $repo.Replace("'", "''"))
            $check
            'if ($LASTEXITCODE) { exit $LASTEXITCODE }'
        )
        ($checkLines -join [Environment]::NewLine) | Set-Content -LiteralPath $checkScript -Encoding utf8
        # Windows PowerShell converts native stderr into error records. Capture it
        # without aborting before we can inspect the child process exit code.
        $savedErrorPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & powershell.exe -NoProfile -File $checkScript *> (Join-Path $run "$($task.id)-check-$checkIndex.log")
            $checkExit = $LASTEXITCODE
        } finally { $ErrorActionPreference = $savedErrorPreference }
        if ($checkExit -ne 0) { throw "Mandatory check $checkIndex failed ($checkExit); run stopped." }
    }
    $reviewFile = Join-Path $run "$($task.id)-review.json"
    $reviewPrompt = @"
You are a fresh independent reviewer. Use Osmani code-review-and-quality and security-and-hardening skills. Read applicable AGENTS.md. Task data:
$taskJson
Compare the working tree with base commit $base using git diff and inspect new untracked source files. Read relevant spec requirements and the task evidence in $run, including $workerFile and mandatory check logs. Assess correctness, scope, meaningful acceptance coverage, and whether red evidence failed for the intended missing behavior before implementation. Agent summaries are claims to verify against evidence and code.
Return pass only when this task meets every acceptance criterion, TDD evidence is credible, mandatory checks passed, and no actionable blocking findings remain. Return fail or blocked otherwise with findings. Read-only review; do not edit files. Use null redExitCode and greenExitCode for your result.
"@
    $null = Invoke-Agent $reviewPrompt 'read-only' $reviewFile
    $headNow = & git -C $repo rev-parse HEAD
    if ($headNow -ne $base) { throw 'Unexpected commit created during task; stopped.' }
    # Stop here until a human records the accepted task as a commit. Each task gets its own diff baseline.
    Write-Output "Task $($task.id) passed. Evidence: $run"
    if ($task.id -ne $config.tasks[-1].id) {
        Write-Output 'Commit the reviewed task, remove it from the next approved manifest, and rerun for remaining tasks.'
        return
    }
}
Write-Output 'All tasks in this run passed. Merge and deployment remain human-controlled.'
