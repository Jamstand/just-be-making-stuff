#!/usr/bin/env bash
#
# scripts/apply-improvements.sh  (Mac / Linux / Git Bash on Windows)
#
# Pulls a weekly improvement branch (claude/auto-improve-YYYY-MM-DD) into your LOCAL
# game branch and then hands off to a LOCAL Claude Code session (the one that can talk to
# Roblox Studio through the MCP server) to put src/ into the open Studio place.
#
# Usage:
#   bash scripts/apply-improvements.sh                 # newest origin/claude/auto-improve-* branch (by the date in its name)
#   bash scripts/apply-improvements.sh 42              # a pull request number
#   bash scripts/apply-improvements.sh claude/auto-improve-2026-09-28   # a branch name
#   bash scripts/apply-improvements.sh --help
#
# What it does, in order (it asks y/N before changing anything):
#   1. cd to the repo root, git fetch origin
#   2. work out the game branch ("main" if its default.project.json is named CrackAGeode,
#      otherwise "claude/crack-a-geode")
#   3. pick the branch to apply (argument, or the newest origin/claude/auto-improve-* -
#      "newest" = the latest date in the branch name, so a late fix on an old branch never wins)
#   4. show its commits and its weekly report, ask for confirmation
#   5. refuse if you have uncommitted changes; check out the game branch; fast-forward it
#      to origin; merge the branch with a merge commit (git merge --no-ff)
#   6. launch:  claude "<apply prompt>"   - the local session applies src/ into Studio,
#      runs the Studio-only TestHook smoke actions, and reminds you to Publish
#   7. print the git push command for you to run when you are happy (this script never pushes)
#
# It never force-pushes, never deletes anything, never pushes. If the merge conflicts it
# stops and tells you how to abort. Portable: bash 3.2 (macOS), Git Bash, Linux.
#
# Exit codes: 0 ok / nothing done, 1 refused or failed, 2 setup problem (git, repo),
#             3 claude not found (merge already done; the prompt is printed for you).

set -euo pipefail

# ---------------------------------------------------------------------------
# The prompt handed to the local Claude Code session. Kept IDENTICAL to the one in
# scripts/apply-improvements.ps1 - if you change one, change the other.
# (Quoted heredoc: nothing inside is expanded by the shell.)
# ---------------------------------------------------------------------------
APPLY_PROMPT=$(cat <<'EOF_APPLY_PROMPT'
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
EOF_APPLY_PROMPT
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit "${2:-1}"; }

usage() {
	# Print the comment block at the top of this file (lines 2-31) as the help text.
	sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
	-h | --help | help)
		usage
		exit 0
		;;
esac
TARGET_ARG="${1:-}"

# ---------------------------------------------------------------------------
# 1. Repo root + prerequisites
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

command -v git >/dev/null 2>&1 || die "git is not installed or not on PATH." 2
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$REPO_ROOT is not a git repository." 2

HAVE_CLAUDE=1
if ! command -v claude >/dev/null 2>&1; then
	HAVE_CLAUDE=0
	say "WARNING: the 'claude' command was not found on PATH. The merge can still be done;"
	say "         the Studio apply prompt will be printed for you to paste into Claude Code yourself."
fi

step "Fetching from origin"
git fetch origin --prune

# ---------------------------------------------------------------------------
# 2. Which branch is the game branch?
#    "main" if ITS default.project.json is the CrackAGeode project, else claude/crack-a-geode.
#    (grep reads all of its input on purpose: no -q, so pipefail cannot misfire.)
# ---------------------------------------------------------------------------
GAME_BRANCH="claude/crack-a-geode"
if git show origin/main:default.project.json 2>/dev/null | grep -E '"name"[[:space:]]*:[[:space:]]*"CrackAGeode"' >/dev/null; then
	GAME_BRANCH="main"
fi
git rev-parse --verify --quiet "refs/remotes/origin/$GAME_BRANCH" >/dev/null \
	|| die "origin/$GAME_BRANCH does not exist. Run 'git branch -r' and check the remote." 2
say "Game branch: $GAME_BRANCH"

# ---------------------------------------------------------------------------
# 3. Which branch to apply? (TARGET is always a remote-tracking ref like origin/...)
# ---------------------------------------------------------------------------
TARGET=""
if [ -z "$TARGET_ARG" ]; then
	# Newest by NAME (the names are ISO dates, so text order is date order and a "-2" re-run sorts
	# after its base name). Not by commit date: a late fix on an old branch must not make it "newest".
	# awk reads all input (no head), so pipefail stays quiet.
	TARGET="$(git for-each-ref --sort=-refname --format='%(refname:short)' 'refs/remotes/origin/claude/auto-improve-*' | awk 'NR==1')"
	[ -n "$TARGET" ] || die "No origin/claude/auto-improve-* branch found. Has the weekly agent run yet? You can also pass a branch name or PR number."
	say "Newest improvement branch: $TARGET"
else
	case "$TARGET_ARG" in
		*[!0-9]*)
			# A branch name (with or without the origin/ prefix).
			NAME="${TARGET_ARG#origin/}"
			git rev-parse --verify --quiet "refs/remotes/origin/$NAME" >/dev/null \
				|| die "origin/$NAME does not exist. 'git branch -r' lists the remote branches."
			TARGET="origin/$NAME"
			;;
		*)
			# A bare pull request number: resolve it through the PR head ref on origin.
			PR="$TARGET_ARG"
			PR_SHA="$(git ls-remote origin "refs/pull/$PR/head" | awk '{ print $1 }')"
			[ -n "$PR_SHA" ] || die "Pull request #$PR was not found on origin (git ls-remote origin refs/pull/$PR/head returned nothing)."
			git fetch origin "refs/pull/$PR/head:refs/remotes/origin/pr/$PR"
			# Prefer the real branch name when a remote branch points at the same commit.
			TARGET="$(git for-each-ref --points-at "$PR_SHA" --format='%(refname:short)' 'refs/remotes/origin/claude/*' | awk 'NR==1')"
			[ -n "$TARGET" ] || TARGET="origin/pr/$PR"
			say "Pull request #$PR -> $TARGET ($PR_SHA)"
			;;
	esac
fi

# ---------------------------------------------------------------------------
# 4. Show what would be merged: commits + the weekly report
# ---------------------------------------------------------------------------
step "Commits in $TARGET that are not yet in origin/$GAME_BRANCH"
COMMITS="$(git log --oneline "origin/$GAME_BRANCH..$TARGET")"
if [ -z "$COMMITS" ]; then
	say "(none - this branch is already contained in origin/$GAME_BRANCH)"
else
	say "$COMMITS"
fi

step "Weekly report on that branch"
REPORT_PATH="$(git ls-tree -r --name-only "$TARGET" -- automation/reports | grep -E '/[0-9]{4}-[0-9]{2}-[0-9]{2}(-[0-9]+)?\.md$' | sort | tail -n 1 || true)"
if [ -n "$REPORT_PATH" ]; then
	say "$REPORT_PATH"
	say "-----------------------------------------------------------------------"
	git show "$TARGET:$REPORT_PATH"
	say "-----------------------------------------------------------------------"
else
	say "(no automation/reports/YYYY-MM-DD.md found on $TARGET)"
fi

step "Diff summary (origin/$GAME_BRANCH..$TARGET)"
git diff --stat "origin/$GAME_BRANCH" "$TARGET" || true

# ---------------------------------------------------------------------------
# 5. Confirm, check the working tree, merge
# ---------------------------------------------------------------------------
printf '\nMerge %s into your local %s branch? [y/N] ' "$TARGET" "$GAME_BRANCH"
read -r ANSWER
case "$ANSWER" in
	y | Y | yes | YES | Yes) ;;
	*)
		say "Nothing changed."
		exit 0
		;;
esac

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
	say ""
	say "Your working tree has uncommitted changes:"
	git status --short --untracked-files=no
	die "Commit or stash them first (git stash), then run this script again."
fi

step "Checking out $GAME_BRANCH"
if git show-ref --verify --quiet "refs/heads/$GAME_BRANCH"; then
	git checkout "$GAME_BRANCH"
	# Bring the local branch up to date without rewriting anything (fast-forward only).
	if ! git merge --ff-only "origin/$GAME_BRANCH"; then
		die "Your local $GAME_BRANCH and origin/$GAME_BRANCH have diverged. Push or reconcile it first (ask Claude locally: 'my $GAME_BRANCH diverged from origin, help me reconcile without losing anything'), then re-run."
	fi
else
	git checkout -b "$GAME_BRANCH" "origin/$GAME_BRANCH"
fi

step "Merging $TARGET (merge commit, no fast-forward)"
if ! git merge --no-ff --no-edit -m "Merge $TARGET into $GAME_BRANCH (weekly improvements)" "$TARGET"; then
	say ""
	say "The merge has conflicts. Either resolve them (ask Claude locally: 'help me resolve this merge'),"
	say "or put everything back with:   git merge --abort"
	exit 1
fi
say "Merged. Nothing has been pushed."

# ---------------------------------------------------------------------------
# 6. Hand off to the local Claude Code session (Roblox Studio MCP)
# ---------------------------------------------------------------------------
PUSH_HINT="git push origin $GAME_BRANCH"

if [ "$HAVE_CLAUDE" -eq 0 ]; then
	say ""
	say "'claude' is not on PATH, so I cannot launch Claude Code for you."
	say "Install Claude Code, open it in this folder with Studio running, and paste this prompt:"
	say "======================================================================="
	say "$APPLY_PROMPT"
	say "======================================================================="
	say ""
	say "When you are happy with the result and have Published from Studio, push with:   $PUSH_HINT"
	exit 3
fi

step "Launching Claude Code (make sure Roblox Studio is open on the Crack a Geode place with the MCP toggle on)"
say "When the session ends, remember: Publish from Studio, then push with:   $PUSH_HINT"
say ""
if ! claude "$APPLY_PROMPT"; then
	say "(claude exited with a non-zero status; the merge is still in place locally)"
fi

# ---------------------------------------------------------------------------
# 7. Done - suggest the push (never done automatically)
# ---------------------------------------------------------------------------
say ""
say "Done. If Studio looks good and you have Published, push the merged branch so GitHub matches the live game:"
say ""
say "    $PUSH_HINT"
say ""
say "Changed your mind and have NOT pushed? Ask Claude locally: 'undo the last merge on this branch, I haven't pushed it'."
exit 0
