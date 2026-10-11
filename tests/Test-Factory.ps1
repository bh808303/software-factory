$ErrorActionPreference = 'Stop'
$runner = Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-Factory.ps1'
$target = Join-Path ([IO.Path]::GetTempPath()) ('factory-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $target 'docs/factory') -Force | Out-Null
& git -C $target init -b codex/test --quiet
if ($LASTEXITCODE) { throw 'Cannot initialize test target.' }
$manifest = Join-Path $target 'docs/factory/tasks.json'
$global:FactoryMockMode = 'pass'
$global:FactoryMockCalls = 0

# Replace the model process only; Git, filesystem validation, and checks run for real.
function codex {
    $global:FactoryMockCalls++
    $output = $args[[Array]::IndexOf($args, '-o') + 1]
    $review = $args -contains 'read-only'
    $evidence = Join-Path (Split-Path $output -Parent) 'red-green.log'
    Set-Content -LiteralPath $evidence -Value 'Mocked model evidence; no live model execution.'
    $relative = 'docs/factory/runs/' + (Split-Path (Split-Path $output -Parent) -Leaf) + '/red-green.log'
    if ($global:FactoryMockMode -eq 'outside') { $relative = '../outside.log' }
    @{
        status = 'pass'; summary = 'Mock result'; findings = @()
        redExitCode = $(if ($review) { $null } else { 1 })
        greenExitCode = $(if ($review) { $null } else { 0 })
        evidencePaths = @($relative)
    } | ConvertTo-Json | Set-Content -LiteralPath $output
    $global:LASTEXITCODE = 0
}

function Write-Manifest($checks = @('exit 0'), $completed = @()) {
    @{
        completedTaskIds = $completed
        checks = $checks
        tasks = @(@{ id = 'task-001'; description = 'Test task'; acceptanceCriteria = @('Observable behavior'); testCommand = 'exit 0'; dependsOn = @() })
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifest
}
function Commit-Target {
    & git -C $target add .
    & git -C $target -c user.name=FactoryTest -c user.email=factory-test@example.invalid commit --quiet -m 'Test fixture'
    if ($LASTEXITCODE) { throw 'Cannot commit test target.' }
}
function Assert-Rejected([scriptblock]$action, [string]$message) {
    try { & $action | Out-Null } catch {
        if ($_.Exception.Message -notlike "*$message*") { throw }
        Write-Output "PASS: $message"
        return
    }
    throw "Expected rejection: $message"
}

Write-Manifest
& $runner -Repository $target -Preview
if ($global:FactoryMockCalls -ne 0) { throw 'Preview started a model.' }
Write-Output 'PASS: preview does not launch workers'
Assert-Rejected { & $runner -Repository $target } 'pass -ApprovedPlan'
Assert-Rejected { & $runner -Repository $target -ApprovedPlan } 'initial commit'
Write-Manifest -checks @(' ')
Assert-Rejected { & $runner -Repository $target -Preview } 'nonempty PowerShell command strings'
Write-Manifest -completed @('done', 'done')
Assert-Rejected { & $runner -Repository $target -Preview } 'Completed task IDs'
Write-Manifest
Commit-Target
$result = & $runner -Repository $target -ApprovedPlan
if ($global:FactoryMockCalls -ne 2 -or ($result -join ' ') -notlike '*Task task-001 passed*') { throw 'Worker/check/reviewer flow did not pass.' }
Write-Output 'PASS: valid Windows evidence reaches independent review'
Commit-Target
$global:FactoryMockMode = 'outside'
Assert-Rejected { & $runner -Repository $target -ApprovedPlan } 'Invalid or missing evidence file'
Commit-Target
$global:FactoryMockMode = 'pass'
Write-Manifest -checks @('exit 7')
Commit-Target
$callsBefore = $global:FactoryMockCalls
Assert-Rejected { & $runner -Repository $target -ApprovedPlan } 'Mandatory check 1 failed (7)'
if ($global:FactoryMockCalls -ne $callsBefore + 1) { throw 'Reviewer launched after failed checks.' }
Write-Output "All 8 regression checks passed. Temporary target: $target"
