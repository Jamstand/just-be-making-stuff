<#
.SYNOPSIS
    Merge a weekly improvement branch into your LOCAL game branch, then hand off to a LOCAL
    Claude Code session (the one with the Roblox Studio MCP) that puts src/ into the open place.

.DESCRIPTION
    scripts\apply-improvements.ps1  (Windows PowerShell 5.1 or PowerShell 7)

    What it does, in order (it asks y/N before changing anything):
      1. cd to the repo root, git fetch origin
      2. work out the game branch ("main" if its default.project.json is named CrackAGeode,
         otherwise "claude/crack-a-geode")
      3. pick the branch to apply (argument, or the newest origin/claude/auto-improve-* -
         "newest" = the latest date in the branch name, so a late fix on an old branch never wins)
      4. show its commits and its weekly report, ask for confirmation
      5. refuse if you have uncommitted changes; check out the game branch; fast-forward it
         to origin; merge the branch with a merge commit (git merge --no-ff)
      6. launch:  claude "<apply prompt>"  - the local session applies src/ into Studio,
         runs the Studio-only TestHook smoke actions, and reminds you to Publish
      7. print the git push command for you to run when you are happy (this script never pushes)

    It never force-pushes, never deletes anything, never pushes. If the merge conflicts it
    stops and tells you how to abort.

    Exit codes: 0 ok / nothing done, 1 refused or failed, 2 setup problem (git, repo),
                3 claude not found (merge already done; the prompt is printed for you).

.PARAMETER Target
    Optional. A branch name (claude/auto-improve-2026-09-28, with or without "origin/")
    or a bare pull request number (42). Default: the newest origin/claude/auto-improve-* branch
    (newest by the date in its name).

.PARAMETER Help
    Show this help and exit.

.EXAMPLE
    .\scripts\apply-improvements.ps1
.EXAMPLE
    .\scripts\apply-improvements.ps1 42
.EXAMPLE
    .\scripts\apply-improvements.ps1 claude/auto-improve-2026-09-28
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\apply-improvements.ps1
    (use this form if PowerShell says "running scripts is disabled on this system")
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Target = '',
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# The prompt handed to the local Claude Code session. Kept IDENTICAL to the one in
# scripts/apply-improvements.sh - if you change one, change the other.
# (Single-quoted here-string: nothing inside is expanded by PowerShell. Keep it free of
#  double quotes so it survives being passed as one command-line argument on Windows.)
# ---------------------------------------------------------------------------
$ApplyPrompt = @'
You are running LOCALLY in the Crack a Geode repo folder on Josh's computer, and this machine has the Roblox Studio MCP server from .mcp.json (tools named mcp__Roblox_Studio__..., for example run_code). Josh has just merged a reviewed improvement branch into the local game branch. Your job: put the merged src/ code into the place that is open in Roblox Studio, smoke-test it, and report. Read CLAUDE.md first. Do exactly these steps, in order, and stop at the first step that fails.

STEP 1 - Confirm Studio is connected. If the Roblox Studio MCP tools are not listed, load them with ToolSearch (query: Roblox_Studio). Make one harmless read-only call, for example run this Luau and show its output: print(game.Name); for _, c in ipairs(game.ReplicatedStorage:GetChildren()) do print(c.ClassName, c.Name) end. If the server is not connected or the call fails: STOP and tell Josh, in one sentence, to open the Crack a Geode place in Roblox Studio, turn on the MCP plugin toggle (Plugins tab), and re-run the apply script. Do not try any workaround and do not change anything.

STEP 2 - Learn the mapping. Read default.project.json; its name must be CrackAGeode (if it is not, stop and tell Josh this is not the game branch). The mapping is:
  src/shared/Config.luau maps to ReplicatedStorage.Config (ModuleScript)
  src/shared/Zones.luau maps to ReplicatedStorage.Zones (ModuleScript)
  src/shared/StyleGuide.luau maps to ReplicatedStorage.StyleGuide (ModuleScript)
  src/server/CrackAGeodeServer/init.server.luau maps to ServerScriptService.CrackAGeodeServer (a Script); every other .luau file in that folder maps to a child ModuleScript of it, named after the file without .luau (Data.luau becomes Data)
  src/client/CrackAGeodeClient/init.client.luau maps to StarterPlayer.StarterPlayerScripts.CrackAGeodeClient (a LocalScript); every other .luau file in that folder maps to a child ModuleScript of it
Before changing anything, list every .luau file under src/ next to the instance path it maps to.

STEP 3 - Apply. For each file: create the instance if it is missing, otherwise replace its Source, at exactly that path, with the complete file contents unchanged (keep tabs, do not reformat, do not trim). Keep names and class types exactly as mapped. When you set Source from Luau, wrap the file text in a long-bracket string level that does not appear in the file. Do NOT create, delete, move, rename or edit any other instance (parts, models, UI, lighting, folders, values, remotes). If an existing instance at a mapped path has the wrong class, do not delete it: report it and skip that file. Do not save or publish the place.

STEP 4 - Verify. Read back the Source of every instance you wrote and compare it with the file (same character count, same first line, same last line). List any mismatch and fix it before continuing.

STEP 5 - Smoke test (best effort). While the game runs in Studio, init.server.luau creates a Studio-only BindableFunction named TestHook in ServerStorage. If your tools can run the place with a player (Play mode) and TestHook exists, invoke it with the actions 'profile', 'crack' and 'snapshot', in that order, and report the raw results. Do not invoke any other action (several grant gems, passes or products). If you cannot run the place or TestHook is missing, say so and give Josh this line to paste into the Studio command bar while playing, with the server view selected: print(game:GetService('ServerStorage').TestHook:Invoke('snapshot'))

STEP 6 - Report in plain English: how many files were applied and which instances were created versus replaced, any skipped files or mismatches, the smoke-test output or why it was skipped, and end with this reminder in bold: Nothing is live until you Publish (File menu, Publish to Roblox) in Studio. Playtest for a minute first.
'@

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
$script:LastGitExitCode = 0

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Invoke-Git {
    # Runs git with the given arguments.
    #   default:      captures stdout+stderr and returns the lines (git prints progress on
    #                 stderr, which is NOT an error, so stderr is merged, not thrown)
    #   -PassThru:    streams output to the console instead (for checkout / merge)
    #   -AllowFailure: do not throw on a non-zero exit code; check $script:LastGitExitCode
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure,
        [switch]$PassThru
    )
    $ErrorActionPreference = 'Continue'   # only inside this function
    $lines = @()
    if ($PassThru) {
        & git @Arguments | Out-Host
        $code = $LASTEXITCODE
    } else {
        $raw = & git @Arguments 2>&1
        $code = $LASTEXITCODE
        $lines = @($raw | ForEach-Object { "$_" })
    }
    $script:LastGitExitCode = $code
    if (($code -ne 0) -and (-not $AllowFailure)) {
        throw "git $($Arguments -join ' ') failed (exit code $code):`n$($lines -join "`n")"
    }
    return $lines
}

function Get-GameBranch {
    # "main" if ITS default.project.json is the CrackAGeode project, else claude/crack-a-geode.
    $lines = @(Invoke-Git -Arguments @('show', 'origin/main:default.project.json') -AllowFailure)
    if ($script:LastGitExitCode -eq 0) {
        $text = $lines -join "`n"
        if ($text -match '"name"\s*:\s*"CrackAGeode"') {
            return 'main'
        }
    }
    return 'claude/crack-a-geode'
}

function Resolve-TargetRef {
    # Returns a remote-tracking ref name (origin/...) for the branch to apply.
    param([string]$Requested)

    if ([string]::IsNullOrWhiteSpace($Requested)) {
        # Newest origin/claude/auto-improve-* by NAME (ISO dates, so text order is date order and a
        # "-2" re-run sorts after its base name). Not by commit date: a late fix on an old branch
        # must not make it "newest".
        $refs = @(Invoke-Git -Arguments @('for-each-ref', '--sort=-refname', '--format=%(refname:short)', 'refs/remotes/origin/claude/auto-improve-*'))
        $refs = @($refs | Where-Object { $_ -ne '' })
        if ($refs.Count -eq 0) {
            throw 'No origin/claude/auto-improve-* branch found. Has the weekly agent run yet? You can also pass a branch name or PR number.'
        }
        Write-Host "Newest improvement branch: $($refs[0])"
        return $refs[0]
    }

    if ($Requested -match '^\d+$') {
        # A bare pull request number: resolve it through the PR head ref on origin.
        $pr = [int]$Requested
        $lsRemote = @(Invoke-Git -Arguments @('ls-remote', 'origin', "refs/pull/$pr/head"))
        $shaLines = @($lsRemote | Where-Object { $_ -match '^[0-9a-f]{40}\s' })
        if ($shaLines.Count -eq 0) {
            throw "Pull request #$pr was not found on origin (git ls-remote origin refs/pull/$pr/head returned nothing)."
        }
        $sha = ($shaLines[0] -split '\s+')[0]
        Invoke-Git -Arguments @('fetch', 'origin', "refs/pull/$pr/head:refs/remotes/origin/pr/$pr") | Out-Null
        # Prefer the real branch name when a remote branch points at the same commit.
        $named = @(Invoke-Git -Arguments @('for-each-ref', '--points-at', $sha, '--format=%(refname:short)', 'refs/remotes/origin/claude/*'))
        $named = @($named | Where-Object { $_ -ne '' })
        $resolved = "origin/pr/$pr"
        if ($named.Count -gt 0) {
            $resolved = $named[0]
        }
        Write-Host "Pull request #$pr -> $resolved ($sha)"
        return $resolved
    }

    # A branch name (with or without the origin/ prefix).
    $name = $Requested -replace '^origin/', ''
    Invoke-Git -Arguments @('rev-parse', '--verify', '--quiet', "refs/remotes/origin/$name") -AllowFailure | Out-Null
    if ($script:LastGitExitCode -ne 0) {
        throw "origin/$name does not exist. 'git branch -r' lists the remote branches."
    }
    return "origin/$name"
}

function Get-LatestReportPath {
    # Newest automation/reports/YYYY-MM-DD.md (or YYYY-MM-DD-2.md) committed on the given ref.
    param([Parameter(Mandatory = $true)][string]$Ref)
    $files = @(Invoke-Git -Arguments @('ls-tree', '-r', '--name-only', $Ref, '--', 'automation/reports') -AllowFailure)
    $reports = @($files | Where-Object { $_ -match '/\d{4}-\d{2}-\d{2}(-\d+)?\.md$' } | Sort-Object)
    if ($reports.Count -eq 0) {
        return ''
    }
    return $reports[$reports.Count - 1]
}

function Show-ApplyPromptForManualUse {
    param([Parameter(Mandatory = $true)][string]$PushHint)
    Write-Host ''
    Write-Host "'claude' is not on PATH, so I cannot launch Claude Code for you."
    Write-Host 'Install Claude Code, open it in this folder with Studio running, and paste this prompt:'
    Write-Host '======================================================================='
    Write-Host $ApplyPrompt
    Write-Host '======================================================================='
    Write-Host ''
    Write-Host "When you are happy with the result and have Published from Studio, push with:   $PushHint"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if ($Help -or ($Target -eq '--help') -or ($Target -eq '-h') -or ($Target -eq 'help')) {
    Get-Help -Detailed $MyInvocation.MyCommand.Path
    exit 0
}

try {
    # 1. Repo root + prerequisites -------------------------------------------------
    $repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
    Set-Location -LiteralPath $repoRoot

    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host 'ERROR: git is not installed or not on PATH (install Git for Windows).'
        exit 2
    }
    Invoke-Git -Arguments @('rev-parse', '--is-inside-work-tree') -AllowFailure | Out-Null
    if ($script:LastGitExitCode -ne 0) {
        Write-Host "ERROR: $repoRoot is not a git repository."
        exit 2
    }

    $claudeCommand = Get-Command claude -ErrorAction SilentlyContinue
    $haveClaude = ($null -ne $claudeCommand)
    if (-not $haveClaude) {
        Write-Host "WARNING: the 'claude' command was not found on PATH. The merge can still be done;"
        Write-Host '         the Studio apply prompt will be printed for you to paste into Claude Code yourself.'
    }

    Write-Step 'Fetching from origin'
    Invoke-Git -Arguments @('fetch', 'origin', '--prune') -PassThru

    # 2. Game branch ------------------------------------------------------------------
    $gameBranch = Get-GameBranch
    Invoke-Git -Arguments @('rev-parse', '--verify', '--quiet', "refs/remotes/origin/$gameBranch") -AllowFailure | Out-Null
    if ($script:LastGitExitCode -ne 0) {
        Write-Host "ERROR: origin/$gameBranch does not exist. Run 'git branch -r' and check the remote."
        exit 2
    }
    Write-Host "Game branch: $gameBranch"

    # 3. Branch to apply --------------------------------------------------------------
    $targetRef = Resolve-TargetRef -Requested $Target

    # 4. Show what would be merged ----------------------------------------------------
    Write-Step "Commits in $targetRef that are not yet in origin/$gameBranch"
    $commits = @(Invoke-Git -Arguments @('log', '--oneline', "origin/$gameBranch..$targetRef") | Where-Object { $_ -ne '' })
    if ($commits.Count -eq 0) {
        Write-Host "(none - this branch is already contained in origin/$gameBranch)"
    } else {
        $commits | ForEach-Object { Write-Host $_ }
    }

    Write-Step 'Weekly report on that branch'
    $reportPath = Get-LatestReportPath -Ref $targetRef
    if ($reportPath -ne '') {
        Write-Host $reportPath
        Write-Host '-----------------------------------------------------------------------'
        Invoke-Git -Arguments @('show', "${targetRef}:${reportPath}") -PassThru
        Write-Host '-----------------------------------------------------------------------'
    } else {
        Write-Host "(no automation/reports/YYYY-MM-DD.md found on $targetRef)"
    }

    Write-Step "Diff summary (origin/$gameBranch..$targetRef)"
    Invoke-Git -Arguments @('diff', '--stat', "origin/$gameBranch", $targetRef) -PassThru -AllowFailure

    # 5. Confirm, check the working tree, merge --------------------------------------
    Write-Host ''
    $answer = Read-Host "Merge $targetRef into your local $gameBranch branch? [y/N]"
    if ($answer -notmatch '^(y|yes)$') {
        Write-Host 'Nothing changed.'
        exit 0
    }

    $dirty = @(Invoke-Git -Arguments @('status', '--porcelain', '--untracked-files=no') | Where-Object { $_ -ne '' })
    if ($dirty.Count -gt 0) {
        Write-Host ''
        Write-Host 'Your working tree has uncommitted changes:'
        $dirty | ForEach-Object { Write-Host $_ }
        Write-Host 'ERROR: Commit or stash them first (git stash), then run this script again.'
        exit 1
    }

    Write-Step "Checking out $gameBranch"
    Invoke-Git -Arguments @('show-ref', '--verify', '--quiet', "refs/heads/$gameBranch") -AllowFailure | Out-Null
    if ($script:LastGitExitCode -eq 0) {
        Invoke-Git -Arguments @('checkout', $gameBranch) -PassThru
        # Bring the local branch up to date without rewriting anything (fast-forward only).
        Invoke-Git -Arguments @('merge', '--ff-only', "origin/$gameBranch") -PassThru -AllowFailure
        if ($script:LastGitExitCode -ne 0) {
            Write-Host "ERROR: Your local $gameBranch and origin/$gameBranch have diverged. Push or reconcile it first"
            Write-Host "       (ask Claude locally: 'my $gameBranch diverged from origin, help me reconcile without losing anything'), then re-run."
            exit 1
        }
    } else {
        Invoke-Git -Arguments @('checkout', '-b', $gameBranch, "origin/$gameBranch") -PassThru
    }

    Write-Step "Merging $targetRef (merge commit, no fast-forward)"
    Invoke-Git -Arguments @('merge', '--no-ff', '--no-edit', '-m', "Merge $targetRef into $gameBranch (weekly improvements)", $targetRef) -PassThru -AllowFailure
    if ($script:LastGitExitCode -ne 0) {
        Write-Host ''
        Write-Host "The merge has conflicts. Either resolve them (ask Claude locally: 'help me resolve this merge'),"
        Write-Host 'or put everything back with:   git merge --abort'
        exit 1
    }
    Write-Host 'Merged. Nothing has been pushed.'

    # 6. Hand off to the local Claude Code session (Roblox Studio MCP) ---------------
    $pushHint = "git push origin $gameBranch"

    if (-not $haveClaude) {
        Show-ApplyPromptForManualUse -PushHint $pushHint
        exit 3
    }

    Write-Step 'Launching Claude Code (make sure Roblox Studio is open on the Crack a Geode place with the MCP toggle on)'
    Write-Host "When the session ends, remember: Publish from Studio, then push with:   $pushHint"
    Write-Host ''

    $promptToSend = $ApplyPrompt
    if ($claudeCommand.Source -match '\.(cmd|bat)$') {
        # A .cmd/.bat launcher goes through cmd.exe, which cannot carry newlines in an argument.
        # Send the same wording on one line.
        $promptToSend = ($ApplyPrompt -split "`r?`n" | Where-Object { $_ -ne '' }) -join ' '
    }

    $ErrorActionPreference = 'Continue'   # claude's own exit code must not abort this script
    & claude $promptToSend
    $claudeExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($claudeExit -ne 0) {
        Write-Host "(claude exited with status $claudeExit; the merge is still in place locally)"
    }

    # 7. Done - suggest the push (never done automatically) --------------------------
    Write-Host ''
    Write-Host 'Done. If Studio looks good and you have Published, push the merged branch so GitHub matches the live game:'
    Write-Host ''
    Write-Host "    $pushHint"
    Write-Host ''
    Write-Host "Changed your mind and have NOT pushed? Ask Claude locally: 'undo the last merge on this branch, I haven't pushed it'."
    exit 0
}
catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)"
    exit 1
}
