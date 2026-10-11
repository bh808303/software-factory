# Software Factory
Release: **0.2alpha** (`v0.2.0-alpha`). Experimental, supervised workflow for Windows PowerShell.
A reusable, human-operated Codex pipeline using Addy Osmani agent-skills.

Requires Windows PowerShell 5.1, Git, an authenticated Codex CLI on PATH, and the referenced installed skills. See [CHANGELOG.md](CHANGELOG.md) for release notes.

## Start
1. Open your target Git repository in a fresh Codex chat. The installed skills are discovered in new sessions.
2. Copy templates/task.md to your repository as FACTORY-TASK.md and fill it in.
3. Commit existing work and use a dedicated branch or isolated worktree.
4. Run each stage with the launcher, reviewing its result before advancing:

    & './Start-FactoryStage.ps1' -Repository 'C:\path\to\repo' -Stage spec

Stages: align, spec, plan, build, verify, review. Align, spec, plan, verify, and review start fresh interactive sessions. Build uses the task worker runner described below. Run the launcher from this factory directory, or use its absolute path.
Results and evidence belong in the target repository's docs/factory/ directory.
The launcher does not create worktrees, enforce CI gates, merge, deploy, or start background agents.

## Gates
Spec: acceptance criteria and unresolved questions recorded; approve scope.
Plan: bounded tasks mapped to acceptance criteria; approve plan.
Build: implementation and meaningful tests complete.
Verify: project build, lint, and tests run; exact commands, exit codes, and failures recorded.
Review: findings addressed or explicitly accepted; prepare a PR with evidence.
Merge and deployment require explicit human authorization.

Skills provide workflow guidance. Enforce mandatory checks using branch protection and CI in each target repository.
Configure CI after the first target's stack and commands are known.

## Installed dependency
addyosmani/agent-skills, version 0.6.12 at setup.
https://github.com/addyosmani/agent-skills
Codex invokes underlying skills; Claude slash commands and personas do not transfer automatically.

## Fresh worker per task
The build stage now delegates to Invoke-Factory.ps1. Each task uses a new noninteractive, ephemeral Codex process for implementation, followed by a new read-only reviewer process. Neither resumes or forks conversation history. Both load applicable project instructions and relevant skills. Repository files and evidence remain shared; this is conversation isolation, not filesystem isolation.

1. Finish and approve spec and plan.
2. Copy templates/tasks.example.json into the target repository as docs/factory/tasks.json. Replace example commands and tasks with real ones. Keep mandatory checks fail-fast: propagate every failed native command with an explicit exit.
3. Commit the task manifest and specification on a dedicated branch or isolated worktree.
4. Preview: & './Invoke-Factory.ps1' -Repository 'C:\path\to\repo' -Preview
5. Run: & './Invoke-Factory.ps1' -Repository 'C:\path\to\repo' -ApprovedPlan

The build launcher also accepts -ApprovedPlan. Approval authorizes manifest commands to execute locally under your user account; inspect them before running. The target must have an initial Git commit. The runner validates nonempty arrays, command strings, task fields, unique IDs, and dependency ordering before execution.
The runner handles one task per invocation, stopping after successful independent review. Commit the result and evidence, move the finished ID into completedTaskIds, remove its task entry, and commit that manifest change before the next run. Dependencies must name completed tasks or earlier pending tasks.
Failures stop the run and leave changes and evidence available for inspection. There is no automatic retry, rollback, commit, merge, or deployment. Evidence lives in docs/factory/runs/<run-id>/.

## TDD validation
Workers must record the failing test before production edits, then passing tests after implementation. The runner requires nonzero red and zero green exit codes plus existing evidence files. It independently executes the approved mandatory checks and requires a passing reviewer result. The reviewer examines the test quality and claimed red-green ordering.
Red timing is worker-recorded evidence, not tamper-proof enforcement. This runner is a supervised foundation; branch-protected CI and externally captured test execution are still needed for stronger enforcement.
Run regression checks with `powershell.exe -NoProfile -File ./tests/Test-Factory.ps1`. These use mocked model responses with real Git repositories, filesystem validation, and mandatory-check processes. Live model execution and target-specific checks remain untested until a real target is selected.

The task's focused `testCommand` is supplied to the worker but is not independently executed by the runner. Specification approval is a conversational gate without a defined machine-verifiable approval record. Evidence containment validates lexical paths; symlinks and junctions are not a security isolation mechanism.


## Requirements alignment with Pocock
Before specification, the interactive align stage uses the installed mattpocock-skills:grilling skill. It asks decision questions in rounds, researches project facts, and follows dependent questions only after their prerequisites are answered. The resulting decision record is docs/factory/alignment.md.

    & './Start-FactoryStage.ps1' -Repository 'C:\path\to\repo' -Stage align

Confirm the shared understanding when the interview is complete. The agent records the actual confirmation; pending decisions stay pending. The spec stage reads this record and resumes grilling if alignment is incomplete, so starting directly at spec also includes alignment. New scope questions reopen the affected decisions. This interview stays interactive with the human; implementation workers receive the resulting specification.

Skill dependency: mattpocock-skills:grilling from the installed mattpocock-skills plugin (1.2.3 at setup). The launcher requests native Codex skill discovery; install the plugin before using alignment.
The confirmation gate is an agent workflow instruction, not a machine-verifiable approval mechanism.
