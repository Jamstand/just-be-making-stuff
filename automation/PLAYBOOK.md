# Weekly improvement agent — PLAYBOOK (Crack a Geode!)

You are a **cloud** Claude Code session started by a schedule (the prompt in
`automation/TRIGGER_PROMPT.md`). You can use git, bash, static tools and the GitHub MCP tools.
You **cannot** see Roblox Studio, playtest, see art, or publish. Josh (solo, non-expert) reads
your PR and decides. Read `CLAUDE.md` first; it holds the code map and the golden rules.
Follow the steps below in order. Precision over speed. When unsure: propose, don't change.

## Guardrails (non-negotiable)

1. Never push to `main` or the game branch. Only push `claude/auto-improve-YYYY-MM-DD`. Never merge or
   auto-merge your own PR (`mcp__github__merge_pull_request`, `mcp__github__enable_pr_auto_merge`) and never
   write to the repository through the GitHub API (`mcp__github__push_files`, `create_or_update_file`,
   `delete_file`, `create_branch`). Your only writes are `git push` of your own `claude/auto-improve-*` branch
   and `create_pull_request` / `update_pull_request`. Humans merge.
2. Never force-push, never rewrite history, never delete files, never `git reset --hard` on shared branches.
3. Never change numbers in `Config.GamePasses`, `Config.DevProducts`, `Config.Version`, `Config.Balance`,
   or `unlockPrice` / drop tables in `Zones.luau`. Text (`desc`, the display `name`, `icon`) is fine; `key`
   strings, numbers and `id`s are not (keys are stored in player data and derive the `Unlock_*` product keys).
4. Never touch `.mcp.json`, `assets/`, `README-CoinRush.md`, or anything outside the game + automation files.
5. Never remove a saved-profile field; every new one needs a default in `DEFAULT` (`Data.luau`) + migration note.
6. Keep `ProcessReceipt` idempotent and grant-before-save. Keep every remote validated, `S.Ready`-gated, rate-limited.
7. No formatter (no StyLua). Tabs, double quotes, hand-aligned tables stay aligned. Match surrounding style.
8. Never claim you tested gameplay. You ran `scripts/check.sh`; say exactly that.
9. Budget: about 300 changed lines and 6 files per week (more only when ONE fix needs it). The budget counts
   `src/` and `default.project.json` only, measured with `git diff --stat "origin/$GAME"..HEAD -- src default.project.json`;
   `automation/`, `lint/`, `docs/`, `CLAUDE.md` and the other tooling files never count. Stop when you hit it.
10. Everything TIER B goes into the report as a proposal with a paste-ready prompt — never into code.
11. If the last commit that touched `src/` on the game branch is older than 21 days, the repo may be behind
    Studio: banner + minimal changes (step 5). Merged reports or automation files do not make `src/` fresher.
12. Ambiguous? Prefer proposing over changing. A skipped week is fine; a broken game is not.

## Tier A vs Tier B

| | TIER A — you may do it | TIER B — propose only (Josh / Studio) |
| --- | --- | --- |
| Bugs | GiftBoost target ignored by `ProcessReceipt` (`Monetize.luau`) — plumb the target server-side | What should happen when the gift target left the server (refund? self-boost?) — Josh decides |
| Data safety | Warn in `Data.fromStored` when a stored key is dropped; raise the 50-receipt cap defensively | Removing/renaming saved fields; changing `Config.Version`; preserving unknown keys by design |
| Validation | Add missing `type()` checks / debounce to a remote handler, copying the `Purchase` pattern | New remotes for new features |
| Lint / types | Remove dead `makePanel` (UI), unused locals (`Pets`, `Stations`, `init.client`), split same-line statements, add optional fields `isHub`/`prebuilt` to the Zones type | Rewriting `UI.luau`'s `refs` pattern wholesale (52 findings) — too big, needs eyes in Studio |
| Performance | Cache a repeated `FindFirstChild`, avoid per-frame allocations in `Quality`/`Effects` when obviously safe | Changing `Quality.luau` thresholds that alter what mobile players see |
| Docs | Fix stale text in `README.md` (IDs are real now), comments, this playbook | — |
| Economy / monetization | — | Prices, IDs, drop rates, pity, multipliers, new passes/products, starter pack contents |
| UI / feel | — | Touch-target sizes, safe-area insets, pickaxe feel, layout, colors, art, geometry, lighting |

## Procedure

Run the commands one at a time in bash (not as one big script) so every failure is visible.
`YYYY-MM-DD` is today's UTC date: `$(date -u +%F)`.

1. **Orient.** `pwd` (repo root), `git status --short`, `git fetch origin --prune`. Read `CLAUDE.md`.
2. **Game branch.**
   ```bash
   GAME=claude/crack-a-geode
   git show origin/main:default.project.json | grep -E '"name"[[:space:]]*:[[:space:]]*"CrackAGeode"' >/dev/null && GAME=main
   echo "game branch: $GAME"
   ```
3. **Working branch.** `TODAY=$(date -u +%F); git checkout -b "claude/auto-improve-$TODAY" "origin/$GAME"`.
   If that branch already exists on origin (a re-run today), use `claude/auto-improve-$TODAY-2`; the report is then
   `automation/reports/$TODAY-2.md` and the PR title ends in `(2)` (steps 12 and 16).
4. **Automation files present?** If `scripts/check.sh` is missing on this branch, merge them in and say so in the report:
   ```bash
   git checkout origin/claude/roblox-studio-mcp-sx9h7d -- .gitattributes CLAUDE.md rokit.toml selene.toml .luaurc scripts lint automation docs .github
   grep -q '^\.lint/$' .gitignore 2>/dev/null || printf '\n# check.sh outputs\n.lint/\n' >> .gitignore
   git status --short    # expect only the paths above (the checkout already staged them) plus .gitignore
   git add .gitignore && git commit -m "Add automation toolchain, CI and weekly-agent docs (from tooling branch)"
   ```
   (`git add .gitignore`, not `git add -A`: `-A` would also stage any stray file the environment left behind.)
   Never check out `default.project.json`, `src/` or `.mcp.json` from that branch (it holds an unrelated project).
   If the checkout prints `error: pathspec ... did not match`, nothing was changed (it is all-or-nothing): drop the
   missing path from the list and retry once; if it still fails, continue without the automation files and open a
   report-only PR that says so.
5. **Freshness check.** Measure the last commit that touched *game code*, not the last commit of any kind —
   merging automation files or a weekly report must never hide a stale `src/`:
   ```bash
   LAST_SRC=$(git log -1 --format='%h %cI %s' "origin/$GAME" -- src default.project.json)
   AGE_DAYS=$(( ( $(date +%s) - $(git log -1 --format=%ct "origin/$GAME" -- src default.project.json) ) / 86400 ))
   echo "last commit touching src/: $LAST_SRC ($AGE_DAYS days ago)"
   ```
   If `AGE_DAYS > 21`: the report starts with the banner (see template), and you do at most ONE small, obviously
   safe change (or none). Every proposal must say "verify against the current Studio scripts first".
6. **Tools.** `command -v rojo luau-lsp selene`. If they are missing, do NOT use rokit in the cloud session: its
   installer and `rokit install` both talk to api.github.com, which the sandbox proxy blocks (rokit is for Josh's
   machines). Release downloads do work, so fetch the pinned binaries with the repo's own script (it reads the
   versions from `rokit.toml`; CI uses the same script):
   ```bash
   bash scripts/get-tools.sh /tmp/luau-tools
   ```
   It prints each tool's version and ends with `get-tools: ready`. Shell variables may not survive between
   tool calls, so prefix every check with the folder: `LUAU_TOOLS_DIR=/tmp/luau-tools bash scripts/check.sh`.
   If a download fails, run the script once more (it skips what it already has). If the tools still cannot be
   obtained, make NO code changes: open a report-only PR whose Risks section quotes the error.
   selene usually cannot download the Roblox API dump in the cloud sandbox; `check.sh` prints SKIPPED — that is expected.
7. **Baseline before.** `LUAU_TOOLS_DIR=/tmp/luau-tools bash scripts/check.sh --report | tee /tmp/check-before.txt`
   (drop the prefix if the tools are on PATH). Note the line
   `baseline: N fingerprint(s)   new: X   fixed: Y`. If it prints `baseline created`, commit `lint/baseline.luau-lsp.txt`.
   If rojo build FAILS on an untouched checkout, stop coding: report it as the only finding (it needs Josh).
8. **Read context.** `automation/IDEAS_BACKLOG.md`, the two newest reports on this branch
   (`ls automation/reports | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}(-[0-9]+)?\.md$' | sort | tail -n 2` — `README.md`
   is not a report), and `.lint/new-findings.txt` / `.lint/findings.txt`.
   A report reaches the game branch only when Josh merges its PR, so also read the reports on the newest
   weekly branches that may still be unmerged:
   ```bash
   for REF in $(git for-each-ref --sort=-refname --format='%(refname:short)' 'refs/remotes/origin/claude/auto-improve-*' | head -n 3); do
     echo "== $REF"; git show "$REF:automation/reports/${REF#origin/claude/auto-improve-}.md" 2>/dev/null || echo "(no report on $REF)"
   done
   ```
   and list their PRs with `mcp__github__list_pull_requests` (owner `jamstand`, repo `just-be-making-stuff`,
   state `all`) to see which are open, closed or merged. Rules: skip any backlog item an OPEN PR already fixes
   (Josh has not decided yet — say so in Risks); treat the items of a CLOSED-but-not-merged PR as rejected unless
   the backlog says otherwise; a MERGED PR's report is already on the game branch. Do not redo something a
   previous report says Josh rejected or closed.
9. **Pick work.** Choose 1-4 TIER A items, highest impact first (stability > data safety > validation >
   lint/type cleanup > small improvements). Write the list down before editing. Skip anything that needs Studio,
   art, balance decisions, or more than the budget. Unchecked backlog items marked `[A]` are the default menu.
10. **Make changes.** One logical change per commit. For each: read the whole file first, keep style, no
    reformatting of untouched lines, no new `--!strict`, no new dependencies. Explain non-obvious code in a short
    comment. Config/Zones numbers are read-only (guardrail 3).
11. **Verify.** `bash scripts/check.sh` (with the `LUAU_TOOLS_DIR=/tmp/luau-tools` prefix if needed) must print
    `RESULT: PASS` (selene SKIPPED locally is fine). `new: 0` always.
    If `fixed > 0`: `bash scripts/check.sh --update`, then commit `lint/baseline.luau-lsp.txt` on its own
    (`lint: shrink baseline after <what you fixed>`). Only if a fix legitimately restructures code and creates a
    *different* noise finding may the baseline gain a line — explain it in the commit body and the report. Record
    the after-counts. Also run `rojo build default.project.json -o /tmp/verify.rbxl` once more if you touched
    `default.project.json` (you should not need to).
12. **Report.** Write `automation/reports/YYYY-MM-DD.md` (`YYYY-MM-DD-2.md` on a re-run, matching the branch name)
    from the template below. Every "What I fixed" entry needs
    file, why, how verified. Every TIER B proposal needs a paste-ready prompt for Josh's local Studio session.
13. **Backlog.** Edit `automation/IDEAS_BACKLOG.md`: tick `[x]` what you did (append `— PR YYYY-MM-DD`), add new
    findings as unchecked items in the right tier with a one-line rationale. Move a ticked item to `## Done`
    (keeping its date) once its report `automation/reports/<that date>.md` exists on `origin/$GAME` — that means
    Josh merged the PR. Do not delete Josh's items.
14. **Commit.** Code commits first, then `automation: weekly report YYYY-MM-DD` (report + backlog together).
    Style: imperative, module name first (`Monetize: pass gift target through ProcessReceipt`), body = what/why/how verified.
15. **Push.** `git push -u origin "claude/auto-improve-$TODAY"`. Never `--force`.
16. **Open the PR.** Tool `mcp__github__create_pull_request` (load with ToolSearch `select:mcp__github__create_pull_request`
    if it is not listed): owner `jamstand`, repo `just-be-making-stuff`, head = your branch, base = `$GAME`,
    title `Weekly improvements YYYY-MM-DD` (`Weekly improvements YYYY-MM-DD (2)` on a re-run), body = the full report
    file. If the repo shows the branch under a different
    default remote name, still target `$GAME`.
    If the GitHub MCP tools are not available in this session (ToolSearch finds nothing named
    `mcp__github__*`), do not look for another way to call the GitHub API: leave the branch pushed, skip
    step 17, and put this one-click link in the 5-line summary so Josh can open the PR himself:
    `https://github.com/Jamstand/just-be-making-stuff/compare/<game branch>...claude/auto-improve-YYYY-MM-DD?expand=1`
    and say "PR not opened (no GitHub tools in this session)".
17. **Wait for CI.** Workflow name `Luau CI`. Poll with `mcp__github__actions_list` (workflow runs for your branch)
    and `mcp__github__actions_get` (run status/conclusion); on failure read logs with `mcp__github__get_job_logs`
    (failed jobs only). `mcp__github__pull_request_read` (status/checks methods) also shows the check state. Load any
    of them with ToolSearch `select:<name>` and read the schema before calling. Poll about every 60 s
    (`sleep 60`; if sleep is blocked, use the Monitor tool), at most 10 minutes total. Every weekly PR triggers the
    workflow (its `paths` filter includes `automation/**`, so even a report-only PR gets a run). Only the newest run
    for your head commit counts: a run whose conclusion is `cancelled` was replaced by a newer push and is not red.
    If NO run has appeared after 3 minutes, stop waiting and do not make a change just to trigger one — that is not
    a failure: write "CI not triggered" plus the likely reason (Actions disabled for the repo, or the workflow file
    missing from your branch) in the report Summary and in the 5-line summary, and do not use the `[CI RED]` prefix.
18. **Red CI?** Read the log, fix locally, re-run `bash scripts/check.sh`, commit, push (normal push). At most 2
    rounds. Typical causes: a selene error-level lint that was SKIPPED locally; a baseline you forgot to commit.
19. **Finish** with the 5-line plain-English summary for Josh (what changed, what needs him, CI state, PR URL,
    next-week suggestion). This text becomes his notification; no markdown tables, no jargon.

## Report template

````markdown
# Weekly report — YYYY-MM-DD

> **Repo may be behind Studio — export from Studio first, then re-run.** The last commit touching `src/` on the game branch is N days old.
> (Include this banner ONLY when AGE_DAYS > 21. Otherwise delete it.)

## Summary
3-5 lines: what you did, what needs Josh, CI state (green / not triggered / red). No PR URL here — the PR does not
exist yet when this file is committed; the URL goes in the final 5-line summary (and GitHub shows it on the PR itself).

## Repo freshness check
Game branch: `<branch>` at `<sha>`; last commit touching `src/`: `<sha>` (`<date>`, N days old).
Automation files present: yes/no (merged from tooling branch: yes/no). Earlier weekly PRs seen: <open / closed / merged, or none>.
check.sh before: baseline N, new X, fixed Y. Tools: rojo/luau-lsp/selene versions (selene: ran / SKIPPED locally).

## What I fixed
### 1. <short title> — `src/.../File.luau`
- Why: <the bug/risk in one or two sentences, with the line or function name>
- What: <the change>
- Verified: `scripts/check.sh` PASS (new 0, fixed K); <any static reasoning>. Not playtested (cloud session).

## Metrics
- Known lint/type findings (baseline): N -> M (K fixed, 0 new)
- Game code changed (the budget; from `git diff --stat "origin/$GAME"..HEAD -- src default.project.json`): F files (list), +A / -B lines
- Other files changed (report, backlog, baseline, automation files): list
- Commits: C

## Proposals for Studio (TIER B — not done)
### P1. <title> — impact: retention / monetization / stability
Why it matters: <one or two sentences>
Paste into the local Claude session (Studio open, MCP on):
```text
<complete prompt: what to change, where, how to test with TestHook / Play, what NOT to touch>
```
(A fenced block, not a quote: GitHub gives it a one-click copy button and keeps the text verbatim.)

## Ideas for next week (prioritized)
1. <idea> — impact: <retention|monetization|stability>, size: <S|M|L>, tier: <A|B>
2. ...

## Risks / notes
- <anything Josh should know: assumptions, skipped items, CI caveats, backlog items rejected and why>
````

## Definition of done

- [ ] Working branch `claude/auto-improve-YYYY-MM-DD` created from the current game branch; nothing pushed anywhere else
- [ ] `bash scripts/check.sh` prints `RESULT: PASS` with `new: 0` on the final commit
- [ ] Baseline count did not grow (or the growth is explained in a commit body + report)
- [ ] Within budget (~300 lines / 6 files of `src/` + `default.project.json`) or the overage is justified by one single fix
- [ ] No edits to monetization numbers, `Config.Version`, `.mcp.json`, `assets/`; no deleted files; no formatter
- [ ] `automation/reports/YYYY-MM-DD.md` follows the template; every fix has file/why/verified; every TIER B item has a paste-ready prompt
- [ ] `automation/IDEAS_BACKLOG.md` updated (done items ticked, new items added)
- [ ] Branch pushed; PR opened against the game branch with the report as body; nothing merged, no auto-merge, no GitHub-API writes
- [ ] `Luau CI` green on the PR — or "CI not triggered" stated (no run appeared), or the failure explained in the PR title/body and the summary
- [ ] Final message: 5 plain-English lines including the PR URL

## If something goes wrong

- **CI still red after 2 fix rounds:** stop fixing. With `mcp__github__update_pull_request` prefix the title with
  `[CI RED] `, add a top section `## CI failure (needs Josh)` naming the failing stage and the key log lines, and (if
  the tool supports it) mark the PR `draft`. Say it plainly in the 5-line summary. Never disable or edit the workflow.
- **No GitHub MCP tools in the session:** the branch is still pushed; give Josh the compare link (step 16) and say
  "PR not opened (no GitHub tools in this session)". Do not install `gh` or use tokens.
- **`git push` fails / no credentials:** commit locally anyway, write the report file, and end with the summary
  explaining that no PR exists, the branch name, and `git diff --stat origin/<game>..HEAD` so Josh can pull the work
  from the session transcript. Do not retry with other remotes or tokens.
- **selene unavailable locally** (`SKIPPED: ... API dump`): normal. Rely on CI; if CI then fails on selene, fix it in the CI round.
- **rojo build fails before you changed anything:** report only; propose the fix; do not "fix" project files blind.
- **Baseline missing on the game branch:** `check.sh` creates it; commit it in its own commit and mention it.
- **`src/` older than 21 days:** banner, at most one tiny change, proposals only. Do not apply Studio-side ideas.
- **Step-4 checkout prints `pathspec ... did not match`:** nothing was changed (a path checkout is all-or-nothing and
  cannot conflict). Check `git status --short`, drop the missing path from the list, retry once; if it still fails,
  continue without the automation files and open a report-only PR saying so. To undo a partial path checkout on the
  fresh working branch: `git reset -q --hard "origin/$GAME"` (allowed only here: the branch has no commits of its own yet).
- **No `Luau CI` run appears for the PR:** not red — see step 17. Say "CI not triggered" and finish.
- **A backlog item turns out to be TIER B or too big:** leave it unchecked, add a note under it, mention it in Risks.
- **Tool schema differs from this playbook:** trust the loaded schema; the tool names above are the stable part.
- **Nothing safe to do this week:** that is a valid outcome. Still write the report (Summary says "no code changes"),
  update the backlog, open the PR (report + backlog only). A small, honest PR beats a speculative one.
