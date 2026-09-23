#!/usr/bin/env bash
#
# scripts/check.sh - the ONE quality gate for "Crack a Geode!"
#
# The same script is run by:
#   * GitHub Actions           (.github/workflows/luau-ci.yml)
#   * the weekly improvement agent (automation/PLAYBOOK.md)
#   * Josh, locally, before pushing:   bash scripts/check.sh
#
# Stages, in order:
#   0. Only runs for a Crack a Geode checkout (default.project.json "name" == "CrackAGeode").
#      Other branches of this repo hold an unrelated project; there it prints a notice and exits 0.
#   1. rojo build        - the Rojo project must build (catches broken project files / paths).
#   2. luau-lsp analyze  - type-checks + lints every file in src/. Findings are RATCHETED:
#                          every finding is turned into a stable "fingerprint"
#                              src/relative/File.luau | Category | message
#                          (no line numbers, no absolute paths) and compared with
#                          lint/baseline.luau-lsp.txt. A fingerprint that is not in the
#                          baseline FAILS the gate. Baseline entries that no longer occur are
#                          reported as "fixed" (run --update to shrink the baseline).
#   3. selene            - Roblox-aware linter. Runs with --allow-warnings, so only ERROR-level
#                          lints fail. selene must download the Roblox API dump first; where that
#                          is impossible (a sandbox without network) the stage is SKIPPED locally.
#                          In CI (GITHUB_ACTIONS=true) it is a real gate.
#
# Modes:
#   bash scripts/check.sh            gate: exit 1 on new findings / build error / selene error
#   bash scripts/check.sh --update   rewrite lint/baseline.luau-lsp.txt from the current findings
#   bash scripts/check.sh --report   print all findings and never fail on them (a broken build still fails)
#   bash scripts/check.sh --help
#
# Tools: rojo, luau-lsp and selene are looked up on PATH first (install them with rokit:
# "rokit install" inside the repo), then in $LUAU_TOOLS_DIR (a folder containing the binaries).
# rojo and luau-lsp are required; selene is optional locally, required in CI.
#
# Outputs (all under .lint/, which is gitignored):
#   build.rbxl, sourcemap.json, globalTypes.d.luau (downloaded once), luau-lsp.txt (raw output),
#   findings.txt (sorted fingerprints), findings-with-locations.txt, new-findings.txt,
#   fixed-findings.txt, selene.txt.
# When $GITHUB_STEP_SUMMARY is set (GitHub Actions) a Markdown summary is appended to it.
#
# Exit codes: 0 = pass, 1 = gate failed, 2 = tooling / setup problem.
#
# Portability: plain bash 3.2+ (macOS), Git Bash on Windows, Linux. No bash-4-only features
# (no associative arrays, no mapfile), no GNU-only flags (no sed -i, no readlink -f, no grep -P).

set -euo pipefail

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
BASELINE="lint/baseline.luau-lsp.txt"
LINT_DIR=".lint"
GLOBAL_TYPES_URL="https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau"
MSG_MAX=160   # fingerprint messages are cut at this many characters (stops churn from long type dumps)

usage() {
	sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# Mode
# ---------------------------------------------------------------------------
MODE="gate"
case "${1:-}" in
	"") ;;
	--update) MODE="update" ;;
	--report) MODE="report" ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "check.sh: unknown option '$1'" >&2
		echo "usage: bash scripts/check.sh [--update | --report | --help]" >&2
		exit 2
		;;
esac

# ---------------------------------------------------------------------------
# Always work from the repo root (the folder that contains scripts/)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
REPO_ROOT="$(pwd)"

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
count_lines() {
	# Number of lines in a file, without the leading spaces macOS "wc" prints.
	LC_ALL=C wc -l < "$1" | tr -d '[:space:]'
}

is_ci() {
	[ "${GITHUB_ACTIONS:-}" = "true" ]
}

find_tool() {
	# Prints the path of tool $1: PATH first, then $LUAU_TOOLS_DIR (with or without .exe).
	# Prints nothing (and returns 1) when the tool cannot be found.
	local name="$1"
	if command -v "$name" > /dev/null 2>&1; then
		command -v "$name"
		return 0
	fi
	if [ -n "${LUAU_TOOLS_DIR:-}" ]; then
		if [ -x "$LUAU_TOOLS_DIR/$name" ]; then
			echo "$LUAU_TOOLS_DIR/$name"
			return 0
		fi
		if [ -x "$LUAU_TOOLS_DIR/$name.exe" ]; then
			echo "$LUAU_TOOLS_DIR/$name.exe"
			return 0
		fi
	fi
	return 1
}

# The Markdown summary for GitHub Actions is collected here and written at the end.
SUMMARY_ROWS=""
add_summary_row() {
	SUMMARY_ROWS="${SUMMARY_ROWS}| $1 | $2 |
"
}

# ---------------------------------------------------------------------------
# Stage 0: is this a Crack a Geode checkout at all?
# ---------------------------------------------------------------------------
if [ ! -f default.project.json ] \
	|| ! grep -Eq '"name"[[:space:]]*:[[:space:]]*"CrackAGeode"' default.project.json; then
	echo "not a Crack a Geode checkout — nothing to check"
	echo "(default.project.json is missing or its \"name\" is not \"CrackAGeode\"; this repo has other projects on other branches)"
	exit 0
fi

echo "== Crack a Geode check (mode: $MODE) =="
echo "repo: $REPO_ROOT"

# ---------------------------------------------------------------------------
# Locate tools
# ---------------------------------------------------------------------------
ROJO="$(find_tool rojo || true)"
LUAU_LSP="$(find_tool luau-lsp || true)"
SELENE="$(find_tool selene || true)"

MISSING=""
[ -n "$ROJO" ] || MISSING="$MISSING rojo"
[ -n "$LUAU_LSP" ] || MISSING="$MISSING luau-lsp"
if [ -n "$MISSING" ]; then
	echo ""
	echo "Missing required tool(s):$MISSING"
	echo ""
	echo "Install them with rokit (versions are pinned in rokit.toml):"
	echo "  macOS / Linux (Terminal):"
	echo "    curl -sSf https://raw.githubusercontent.com/rojo-rbx/rokit/main/scripts/install.sh | bash"
	echo "  Windows (PowerShell):"
	echo "    Invoke-RestMethod https://raw.githubusercontent.com/rojo-rbx/rokit/main/scripts/install.ps1 | Invoke-Expression"
	echo "  then, inside this repo folder:"
	echo "    rokit install"
	echo "  and open a NEW terminal so ~/.rokit/bin is on your PATH."
	echo ""
	echo "Alternative: set LUAU_TOOLS_DIR to a folder that contains the rojo, luau-lsp and selene binaries."
	exit 2
fi

mkdir -p "$LINT_DIR"
# .lint/ ignores itself, so it can never be committed by accident - even on a branch whose
# top-level .gitignore does not list it yet.
if [ ! -f "$LINT_DIR/.gitignore" ]; then
	echo '*' > "$LINT_DIR/.gitignore"
fi
EXIT_CODE=0

# ---------------------------------------------------------------------------
# Stage 1: rojo build + sourcemap
# ---------------------------------------------------------------------------
echo ""
echo "[1/3] rojo build"
if ! "$ROJO" build default.project.json -o "$LINT_DIR/build.rbxl" > "$LINT_DIR/rojo-build.txt" 2>&1; then
	echo "  FAIL: rojo build failed:"
	sed 's/^/    /' "$LINT_DIR/rojo-build.txt"
	add_summary_row "rojo build" "FAIL"
	EXIT_CODE=1
else
	echo "  ok ($LINT_DIR/build.rbxl)"
	add_summary_row "rojo build" "ok"
fi

if ! "$ROJO" sourcemap default.project.json -o "$LINT_DIR/sourcemap.json" > "$LINT_DIR/rojo-sourcemap.txt" 2>&1; then
	echo "  FAIL: rojo sourcemap failed:"
	sed 's/^/    /' "$LINT_DIR/rojo-sourcemap.txt"
	EXIT_CODE=1
fi

if [ "$EXIT_CODE" -ne 0 ]; then
	echo ""
	echo "RESULT: FAIL (the Rojo project does not build; fix default.project.json / src paths first)"
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		{
			echo "## Luau CI — Crack a Geode"
			echo ""
			echo "| Stage | Result |"
			echo "| --- | --- |"
			printf '%s' "$SUMMARY_ROWS"
			echo ""
			echo "**Result: FAIL** (rojo build)"
		} >> "$GITHUB_STEP_SUMMARY"
	fi
	exit 1
fi

# ---------------------------------------------------------------------------
# Stage 2: luau-lsp analyze, ratcheted against the baseline
# ---------------------------------------------------------------------------
echo ""
echo "[2/3] luau-lsp analyze"

# 2a. Roblox global types (the API definitions luau-lsp needs). Downloaded once into .lint/.
GLOBAL_TYPES="$LINT_DIR/globalTypes.d.luau"
if [ ! -s "$GLOBAL_TYPES" ]; then
	if [ -n "${LUAU_TOOLS_DIR:-}" ] && [ -s "$LUAU_TOOLS_DIR/globalTypes.d.luau" ]; then
		cp "$LUAU_TOOLS_DIR/globalTypes.d.luau" "$GLOBAL_TYPES"
	else
		echo "  downloading Roblox global types into $GLOBAL_TYPES ..."
		if ! curl -sSfL "$GLOBAL_TYPES_URL" -o "$GLOBAL_TYPES.tmp"; then
			rm -f "$GLOBAL_TYPES.tmp"
			echo "  could not download $GLOBAL_TYPES_URL"
			echo "  (no network? download it by hand into $GLOBAL_TYPES and re-run)"
			exit 2
		fi
		mv "$GLOBAL_TYPES.tmp" "$GLOBAL_TYPES"
	fi
fi

# 2b. Run the analyzer. It exits 1 whenever it reports anything, so do not use set -e here.
LUAURC_ARGS=""
if [ -f .luaurc ]; then
	LUAURC_ARGS="--base-luaurc=.luaurc"
fi
set +e
# shellcheck disable=SC2086  # LUAURC_ARGS is intentionally unquoted (empty or one flag)
"$LUAU_LSP" analyze \
	--definitions="$GLOBAL_TYPES" \
	--sourcemap="$LINT_DIR/sourcemap.json" \
	--no-strict-dm-types \
	$LUAURC_ARGS \
	src > "$LINT_DIR/luau-lsp.txt" 2>&1
LSP_RC=$?
set -e

# A "[ERROR]" line means luau-lsp itself had a problem (bad definitions file, bad sourcemap ...).
# A line starting with ".luaurc:" means .luaurc could not be parsed (typo, unknown key, bad
# languageMode). luau-lsp then analyzes NOTHING and exits 1 - that must never pass as "0 findings".
if grep -Eq '^\[ERROR\]|^\.luaurc:' "$LINT_DIR/luau-lsp.txt"; then
	echo "  luau-lsp reported a setup problem:"
	grep -E '^\[ERROR\]|^\.luaurc:' "$LINT_DIR/luau-lsp.txt" | sed 's/^/    /'
	echo "  (raw output: $LINT_DIR/luau-lsp.txt)"
	exit 2
fi
if [ "$LSP_RC" -gt 1 ]; then
	echo "  luau-lsp exited with code $LSP_RC (raw output: $LINT_DIR/luau-lsp.txt)"
	exit 2
fi

# 2c. Normalize every finding into "fingerprint<TAB>location".
#
# luau-lsp prints findings in two shapes (Windows may use backslashes):
#   /abs/path/src/shared/Zones.luau [game/ReplicatedStorage/Zones](49,2): TypeError: message...
#   src/server/CrackAGeodeServer/Pets.luau(5,7): LocalUnused: Variable 'Players' is never used...
# Multi-line messages continue on following lines (indented, or starting with plain text);
# only the first line counts. "[INFO]" / "[WARN]" lines are ignored.
#
# Fingerprint = "src/relative/File.luau | Category | message" where the message has its
# whitespace collapsed and is cut at $MSG_MAX characters. No line/column, no absolute path,
# no [game/...] bracket -> moving code around does not create churn.
normalize_findings() {
	tr -d '\r' | LC_ALL=C awk -v maxlen="$MSG_MAX" '
		{
			line = $0
			gsub(/\\/, "/", line)                       # Windows backslashes -> slashes
			if (line ~ /^[[:space:]]/) next             # continuation line of a multi-line message
			if (line ~ /^\[/) next                      # [INFO] / [WARN] lines
			# A finding starts with a path: "/abs/...", "C:/...", "./src/..." or "src/...".
			# Continuation lines such as "but got ..." or "caused by:" do not.
			if (line !~ /^(\/|[A-Za-z]:\/|\.\/|src\/)/) next
			# ".luau?" matches .luau AND .lua (Rojo maps both the same way); keep the real extension.
			if (match(line, /\.luau?( \[[^]]*\])?\([0-9]+,[0-9]+\): [A-Za-z]+: /) == 0) next
			ext  = (substr(line, RSTART, 5) == ".luau") ? ".luau" : ".lua"
			head = substr(line, 1, RSTART + RLENGTH - 1)   # up to and including "Category: "
			msg  = substr(line, RSTART + RLENGTH)
			path = substr(line, 1, RSTART - 1) ext
			sub(/^.*\/src\//, "src/", path)             # absolute or ./ path -> repo-relative
			loc = head
			match(loc, /\([0-9]+,[0-9]+\)/)
			loc = substr(loc, RSTART, RLENGTH)
			cat = head
			sub(/^.*\): /, "", cat)
			sub(/: $/, "", cat)
			gsub(/[[:space:]]+/, " ", msg)
			sub(/^ /, "", msg)
			sub(/ $/, "", msg)
			if (length(msg) > maxlen) msg = substr(msg, 1, maxlen)
			print path " | " cat " | " msg "\t" path loc
		}
	'
}

normalize_findings < "$LINT_DIR/luau-lsp.txt" > "$LINT_DIR/findings-with-locations.txt"
cut -f1 "$LINT_DIR/findings-with-locations.txt" | LC_ALL=C sort -u > "$LINT_DIR/findings.txt"
RAW_COUNT="$(count_lines "$LINT_DIR/findings-with-locations.txt")"
FOUND_COUNT="$(count_lines "$LINT_DIR/findings.txt")"
echo "  $RAW_COUNT finding(s) -> $FOUND_COUNT unique fingerprint(s)   (raw output: $LINT_DIR/luau-lsp.txt)"

print_with_locations() {
	# $1 = file of fingerprints. Prints each one as "path(line,col): Category: message" for
	# every location where it occurs, so it reads like the original luau-lsp line.
	awk -F '\t' '
		NR == FNR { wanted[$0] = 1; next }
		($1 in wanted) {
			fp = $1
			n = index(fp, " | ")
			rest = substr(fp, n + 3)
			m = index(rest, " | ")
			print "    " $2 ": " substr(rest, 1, m - 1) ": " substr(rest, m + 3)
		}
	' "$1" "$LINT_DIR/findings-with-locations.txt"
}

: > "$LINT_DIR/new-findings.txt"
: > "$LINT_DIR/fixed-findings.txt"
NEW_COUNT=0
FIXED_COUNT=0

if [ ! -f "$BASELINE" ]; then
	# First ever run on this checkout: everything found becomes the baseline.
	mkdir -p "$(dirname "$BASELINE")"
	cp "$LINT_DIR/findings.txt" "$BASELINE"
	echo "  baseline created, commit $BASELINE ($FOUND_COUNT fingerprints)"
	if is_ci; then
		# A "::warning::" line becomes a yellow annotation on the workflow run and on the PR, so a
		# baseline that was never committed is visible - not just a line in a log nobody reads.
		echo "::warning title=No lint baseline::$BASELINE is missing on this branch, so nothing is being ratcheted. Run 'bash scripts/check.sh' locally and commit the file."
	fi
	add_summary_row "luau-lsp analyze" "baseline created with $FOUND_COUNT fingerprints (commit $BASELINE)"
else
	# Compare with the baseline. Both sides sorted the same way (LC_ALL=C) so comm works.
	# (blank / whitespace-only lines are dropped, so a hand-edited baseline never grows a phantom entry)
	tr -d '\r' < "$BASELINE" | sed '/^[[:space:]]*$/d' | LC_ALL=C sort -u > "$LINT_DIR/baseline.sorted.txt"
	BASE_COUNT="$(count_lines "$LINT_DIR/baseline.sorted.txt")"
	LC_ALL=C comm -13 "$LINT_DIR/baseline.sorted.txt" "$LINT_DIR/findings.txt" > "$LINT_DIR/new-findings.txt"
	LC_ALL=C comm -23 "$LINT_DIR/baseline.sorted.txt" "$LINT_DIR/findings.txt" > "$LINT_DIR/fixed-findings.txt"
	NEW_COUNT="$(count_lines "$LINT_DIR/new-findings.txt")"
	FIXED_COUNT="$(count_lines "$LINT_DIR/fixed-findings.txt")"
	echo "  baseline: $BASE_COUNT fingerprint(s)   new: $NEW_COUNT   fixed: $FIXED_COUNT"

	# Sanity check: the baseline has entries but the analyzer reported nothing at all. That is
	# almost never "everything got fixed at once" and almost always "nothing was analyzed"
	# (a broken .luaurc, an empty src/, a bad sourcemap). Never pass, and never wipe the
	# baseline, on the strength of an empty result.
	if [ "$FOUND_COUNT" -eq 0 ] && [ "$BASE_COUNT" -gt 0 ]; then
		echo ""
		echo "  luau-lsp reported 0 findings while the baseline has $BASE_COUNT - that looks like nothing was analyzed."
		echo "  Check $LINT_DIR/luau-lsp.txt. If every finding really is fixed, delete $BASELINE and re-run"
		echo "  (a fresh, empty baseline is then created)."
		if [ "$MODE" != "report" ]; then
			exit 2
		fi
	fi

	if [ "$NEW_COUNT" -gt 0 ]; then
		echo ""
		echo "  NEW findings (not in $BASELINE):"
		print_with_locations "$LINT_DIR/new-findings.txt"
	fi
	if [ "$FIXED_COUNT" -gt 0 ]; then
		echo ""
		echo "  FIXED (in the baseline but no longer reported):"
		sed 's/^/    /' "$LINT_DIR/fixed-findings.txt"
	fi

	case "$MODE" in
		update)
			cp "$LINT_DIR/findings.txt" "$BASELINE"
			echo ""
			echo "  baseline updated: $BASELINE now has $FOUND_COUNT fingerprint(s) (+$NEW_COUNT new, -$FIXED_COUNT fixed) - commit it"
			add_summary_row "luau-lsp analyze" "baseline updated: $FOUND_COUNT fingerprints (+$NEW_COUNT / -$FIXED_COUNT)"
			;;
		report)
			add_summary_row "luau-lsp analyze" "report: $NEW_COUNT new, $FIXED_COUNT fixed, $BASE_COUNT in baseline"
			;;
		gate)
			if [ "$NEW_COUNT" -gt 0 ]; then
				echo ""
				echo "  FAIL: $NEW_COUNT new finding(s). Fix them, or (only if the change is intended) run:"
				echo "        bash scripts/check.sh --update    and commit $BASELINE"
				add_summary_row "luau-lsp analyze" "FAIL: $NEW_COUNT new finding(s), $FIXED_COUNT fixed, $BASE_COUNT in baseline"
				EXIT_CODE=1
			else
				if [ "$FIXED_COUNT" -gt 0 ]; then
					echo "  ($FIXED_COUNT baseline entries are fixed - run 'bash scripts/check.sh --update' to shrink the baseline)"
				fi
				add_summary_row "luau-lsp analyze" "ok: 0 new, $FIXED_COUNT fixed, $BASE_COUNT in baseline"
			fi
			;;
	esac
fi

if [ "$MODE" = "report" ]; then
	echo ""
	echo "  Findings by file:"
	cut -f2 "$LINT_DIR/findings-with-locations.txt" | sed 's/(.*//' | LC_ALL=C sort | uniq -c | sed 's/^/    /'
	echo ""
	echo "  Findings by category:"
	cut -f1 "$LINT_DIR/findings-with-locations.txt" | awk -F ' \\| ' '{ print $2 }' | LC_ALL=C sort | uniq -c | sed 's/^/    /'
	echo ""
	echo "  All findings:"
	print_with_locations "$LINT_DIR/findings.txt"
fi

# ---------------------------------------------------------------------------
# Stage 3: selene
# ---------------------------------------------------------------------------
echo ""
echo "[3/3] selene"
SELENE_SKIPPED=0
if [ -z "$SELENE" ]; then
	if is_ci; then
		echo "  FAIL: selene not found in CI (rokit should have installed it from rokit.toml)"
		add_summary_row "selene" "FAIL: binary not found"
		EXIT_CODE=1
	else
		echo "  SKIPPED: selene is not installed here (run 'rokit install'); CI runs it"
		add_summary_row "selene" "SKIPPED locally (not installed)"
		SELENE_SKIPPED=1
	fi
else
	set +e
	"$SELENE" --allow-warnings --display-style=quiet src > "$LINT_DIR/selene.txt" 2>&1
	SELENE_RC=$?
	set -e
	if [ "$SELENE_RC" -eq 0 ]; then
		echo "  ok (warnings, if any, never fail: $LINT_DIR/selene.txt)"
		if [ -s "$LINT_DIR/selene.txt" ] && [ "$MODE" = "report" ]; then
			sed 's/^/    /' "$LINT_DIR/selene.txt"
		fi
		add_summary_row "selene" "ok"
	elif grep -Eqi 'could not collect standard library|API dump' "$LINT_DIR/selene.txt"; then
		# selene could not download the Roblox API dump (no network / blocked).
		if is_ci; then
			echo "  FAIL: selene could not download the Roblox API dump in CI (network hiccup?) - re-run the workflow"
			sed 's/^/    /' "$LINT_DIR/selene.txt"
			add_summary_row "selene" "FAIL: could not download the Roblox API dump - re-run"
			EXIT_CODE=1
		else
			echo "  SKIPPED locally: selene could not download the Roblox API dump (no network here); it runs for real in CI"
			add_summary_row "selene" "SKIPPED locally (no API dump); runs in CI"
			SELENE_SKIPPED=1
		fi
	else
		echo "  FAIL: selene found error-level problems:"
		sed 's/^/    /' "$LINT_DIR/selene.txt"
		add_summary_row "selene" "FAIL: error-level lints"
		EXIT_CODE=1
	fi
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$EXIT_CODE" -eq 0 ]; then
	RESULT="PASS"
else
	RESULT="FAIL"
fi
if [ "$SELENE_SKIPPED" -eq 1 ]; then
	echo "RESULT: $RESULT (selene skipped locally; it runs in CI)"
else
	echo "RESULT: $RESULT"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	{
		echo "## Luau CI — Crack a Geode"
		echo ""
		echo "| Stage | Result |"
		echo "| --- | --- |"
		printf '%s' "$SUMMARY_ROWS"
		echo ""
		echo "**Result: $RESULT**"
		if [ "$NEW_COUNT" -gt 0 ]; then
			echo ""
			echo "<details><summary>New findings ($NEW_COUNT)</summary>"
			echo ""
			echo '```'
			print_with_locations "$LINT_DIR/new-findings.txt"
			echo '```'
			echo "</details>"
		fi
		if [ "$FIXED_COUNT" -gt 0 ]; then
			echo ""
			echo "<details><summary>Fixed since baseline ($FIXED_COUNT) - run scripts/check.sh --update</summary>"
			echo ""
			echo '```'
			cat "$LINT_DIR/fixed-findings.txt"
			echo '```'
			echo "</details>"
		fi
	} >> "$GITHUB_STEP_SUMMARY"
fi

exit "$EXIT_CODE"
