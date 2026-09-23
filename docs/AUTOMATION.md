# Crack a Geode! — Automation guide (for Josh)

This is the plain-English manual for the "automated improvement system": what runs
when, how to read what it produces, how to get its work into Roblox Studio, and how
to pause it. Every command here is copy-pasteable. The rules the automation follows
are in `CLAUDE.md` (repo root) and `automation/PLAYBOOK.md`.

**The one thing to remember:** nothing in this system ever changes the live game.
The live game changes only when *you* press **Publish** in Roblox Studio.

---

## 1. What runs, when

| What | When | Where | Needs you? |
| --- | --- | --- | --- |
| **Luau CI** (`.github/workflows/luau-ci.yml`) | Every push / pull request that touches `src/`, `default.project.json`, the tool config files, `scripts/check.sh`, `lint/`, `automation/` (so every weekly PR gets a run) or the workflow itself | GitHub Actions (Ubuntu) | No. Shows a green tick / red cross on the commit or PR. |
| **Weekly improvement agent** | Every **Monday** (a scheduled "Routine" in Claude Code on the web; the exact hour is set on the Routine) | A fresh cloud Claude Code session in this repo's environment | No, until you decide to apply its PR. |
| **Apply scripts** (`scripts/apply-improvements.ps1` / `.sh`) | Whenever you choose | Your PC/Mac, with Roblox Studio open | Yes — this is your step. |

### What the weekly agent does (short version)

1. Fetches the game branch (`main` if its `default.project.json` is named `CrackAGeode`,
   otherwise `claude/crack-a-geode`) and creates `claude/auto-improve-YYYY-MM-DD` from it.
2. Runs `scripts/check.sh --report`, reads `automation/IDEAS_BACKLOG.md`, the last two
   reports in `automation/reports/`, and the reports on weekly branches you have not merged yet
   (so it does not redo work that is still waiting for your decision).
3. Makes a **small, bounded** set of safe improvements ("TIER A": bug fixes, stability,
   performance, lint/type cleanup, defensive validation). Roughly: at most ~300 changed lines
   and ~6 files.
4. Verifies with `scripts/check.sh` (must pass), writes `automation/reports/YYYY-MM-DD.md`,
   updates the backlog, commits, pushes the branch, and opens a **pull request against the game
   branch** with the report as the PR body.
5. Waits for Luau CI on the PR (up to ~10 minutes), fixes and re-pushes if it is red (max 2 tries).
6. Ends with a 5-line summary — that summary is the push/email notification you receive.

### What the agent will never do

- It cannot see Roblox Studio, playtest, look at art, or publish. It only reads and writes the git repo.
- It never changes monetization IDs, prices or pass/product keys in `Config.luau` / `Zones.luau`.
- It never changes `Config.Version` (that would reset every player's save).
- It never removes a saved-data field, deletes files, force-pushes, pushes to `main` / the game
  branch directly, or merges its own PR. Its work always arrives as a PR that you can close with one click.
- It never touches `.mcp.json` or `assets/`.
- Economy / balance / prices / new monetized features / visual or Studio-only work ("TIER B") are
  **proposed in the report, not done**, each with a paste-ready prompt for your local session.

**CI and the agent can only catch *static* problems** (does it build, do the types and lints
look right, are the rules in `CLAUDE.md` respected). They cannot tell you whether the game is fun,
whether a button is reachable on a phone, or whether a crack feels good. **You still playtest.**

---

## 2. One-time setup checklist

Do these once, in order. Steps 1-2 are the important ones; the rest make life easier.

- [ ] **1. Make the repo match the live game.** The game branch's last commit (Aug 13, 2026) is
      about a month behind your Studio place. Open the place in Studio, open Claude Code locally in
      the repo folder (so the Roblox Studio MCP is connected), check out the game branch, and ask:
      *"Export the open Studio place's scripts into src/ following default.project.json, then show
      me the diff."* Review, commit, push. Until this is done, the agent will (correctly) warn that
      the repo may be behind Studio and keep its changes minimal.

- [ ] **2. Merge the automation files into the game branch.** They live on the tooling branch
      `claude/roblox-studio-mcp-sx9h7d`. From the repo folder:

      ```bash
      git fetch origin
      git checkout claude/crack-a-geode
      git pull
      git checkout origin/claude/roblox-studio-mcp-sx9h7d -- .gitattributes CLAUDE.md rokit.toml selene.toml .luaurc scripts lint automation docs .github
      git commit -m "Add automation toolchain, CI and weekly-agent docs"
      git push
      ```

      Also make sure the game branch's `.gitignore` contains a line `.lint/` (that folder holds
      downloaded/generated check outputs and must not be committed). Add the line if it is missing.

      `.gitattributes` matters on Windows: the tooling version is a superset of the game branch's
      (which pins only `.luau`, `.json` and `.md` to LF) and adds `*.sh`, `.luaurc`, `*.toml` and
      `lint/*.txt`, so the bash scripts are never checked out with Windows line endings. A CRLF
      `check.sh` fails in Git Bash with `$'\r': command not found` — see the FAQ if you ever see that.
      If you skip this step entirely, the agent will merge those files into its own working branch on
      its first run and say so in the report — but CI won't exist on the game branch until the PR lands.

- [ ] **3. Install the tools (rokit).** Rokit is a tiny tool manager that installs the exact
      versions pinned in `rokit.toml` (rojo, luau-lsp, selene). See section 5.

- [ ] **4. Run the check once locally** and commit the baseline if it changed:

      ```bash
      scripts/check.sh
      ```

      If it prints `baseline created, commit lint/baseline.luau-lsp.txt`, commit that file. If it
      reports NEW findings right after your Studio export (expected — the baseline was made from the
      August code), run `scripts/check.sh --update`, look at the diff of
      `lint/baseline.luau-lsp.txt`, and commit it with a message like `lint: re-baseline after Studio export`.

- [ ] **5. (Optional) Make the game branch the default on GitHub** — Settings → Branches →
      Default branch → `claude/crack-a-geode`. PRs and the Actions tab then open on the right branch
      by default. Later, if you merge the game into `main`, every script switches to `main`
      automatically (they check the project name, not the branch name).

- [ ] **6. Confirm the weekly Routine exists.** In a Claude Code cloud session for this repo, ask:
      *"List my routines."* You should see the weekly Crack a Geode one. If not, ask Claude to create
      it from `automation/TRIGGER_PROMPT.md` (every Monday, fresh session, notifications on).

---

## 3. Every week: reading the PR

You will get a notification (push/email) with a 5-line summary and a PR link. Then:

1. **Open the PR.** Its title is `Weekly improvements YYYY-MM-DD` (prefixed `[CI RED]` if CI could
   not be fixed), its branch is `claude/auto-improve-YYYY-MM-DD`, and its body is the week's report.
   The same report is committed at `automation/reports/YYYY-MM-DD.md`.
2. **Read the report top to bottom.** Sections, in order:
   - **Summary** — what happened in 3-5 lines.
   - **Repo freshness check** — if you see a banner saying *"repo may be behind Studio — export
     from Studio first, then re-run"*, do the export (setup step 1) before applying anything.
   - **What I fixed** — one entry per change: file, why, how it was verified.
   - **Metrics** — lint/type baseline count before → after, files and lines changed.
   - **Proposals for Studio** — things it deliberately did *not* do. Each comes with a paste-ready
     prompt for your local Claude session (which *can* see Studio).
   - **Ideas for next week** — 3-5, ranked by retention / monetization / stability impact.
   - **Risks / notes.**
3. **Check CI.** At the bottom of the PR, "Luau CI" must be green. If it is red, click *Details*
   to see which stage failed (rojo build / the luau-lsp "ratchet" — the type-and-lint check against
   the known-findings list, see section 6 / selene). If the report says "CI not triggered", no run
   existed for that PR — treat it like a report-only week, not like a failure. The full outputs are attached
   to the workflow run as a downloadable artifact (the whole `.lint/` folder).
4. **Look at "Files changed"** if you want to see the actual code. Anything touching
   `Config.luau`, `Zones.luau` or `Data.luau` deserves a second look (the agent is told not to
   change numbers/IDs there, but you are the last line).
5. **Decide:**
   - **Yes** → go to section 4 (apply).
   - **Not like this** → leave a comment on the PR and, in a cloud session, ask Claude *"address
     my comment on PR #N"* — or just close the PR. Closing it costs nothing.
   - **Never** → close the PR and move the item to the **Rejected** section of
     `automation/IDEAS_BACKLOG.md` with a one-line reason (a `[x]` tick means "done", not "don't").

---

## 4. Applying a PR: repo → Studio → Publish

The apply scripts do the boring parts and then hand off to a *local* Claude session (the one with
the Roblox Studio MCP). Before you start:

- Roblox Studio is open on the **Crack a Geode!** place, and the MCP plugin toggle is on (MCP = the
  Studio plugin that lets a local Claude session read and write the open place).
- Claude Code is installed (the `claude` command works in a terminal).
- You are in the repo folder in a terminal.

**Windows (PowerShell):**

```powershell
cd <your repo folder>
.\scripts\apply-improvements.ps1            # newest claude/auto-improve-* branch
.\scripts\apply-improvements.ps1 42         # ...or a PR number
.\scripts\apply-improvements.ps1 claude/auto-improve-2026-10-05   # ...or a branch name
```

If PowerShell refuses to run scripts ("running scripts is disabled on this system"), run it this way
instead — every time, with the PR number or branch name after the file name if you want one:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\apply-improvements.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\apply-improvements.ps1 42
```

(Alternative: run `Set-ExecutionPolicy -Scope Process Bypass` once in that window, then use the plain
`.\scripts\...` form.)

**Mac (Terminal):**

```bash
cd <your repo folder>
bash scripts/apply-improvements.sh          # same optional argument: PR number or branch name
```

**Mac note:** the repo's `.mcp.json` starts the Studio MCP with `cmd.exe`, which only exists on
Windows. On the Mac the merge part works, but the Claude session it launches will stop at its first
step ("Studio not connected"). Until a Mac entry for the Roblox Studio MCP is added to `.mcp.json`
(ask Claude on the Mac to set it up), do the apply step on the Windows PC.

**What the script does (it asks before the only irreversible-ish step):**

1. `git fetch origin`, works out the game branch, picks the branch (argument or newest
   `origin/claude/auto-improve-*` — newest by the date in its name).
2. Shows you the commit list and the report file, then asks **y/N**. `N` = nothing changes.
   After `y` it refuses to go on if you have uncommitted changes (commit or `git stash` them first),
   and before merging it fast-forwards your local game branch to `origin` — if the two have diverged
   it stops and tells you what to ask Claude.
3. Merges the branch into your **local** game branch with a merge commit (`git merge --no-ff`).
   Nothing is pushed yet.
4. Launches `claude` with one prompt that tells the local session to: confirm the Studio MCP is
   connected (if not, it stops and tells you to open Studio, toggle the MCP, and re-run); apply
   `src/` into the open place exactly as `default.project.json` maps it (create/replace the Scripts,
   LocalScripts and ModuleScripts — it does not touch parts, models, lighting or anything else); run
   the Studio-only smoke checks through `ServerStorage.TestHook` if present (`profile`, `crack`,
   `snapshot`) and report; then remind you to Publish.
5. **You:** press Play in Studio and actually play for a minute (crack, open the shop, warp, on a
   phone or the phone emulator if the change touched UI). Then **File → Publish to Roblox**.
6. **Then push the merged game branch** so GitHub matches the live game:

   ```bash
   git push origin claude/crack-a-geode     # the script prints this exact command at the end (it becomes `main` once the game lives there)
   ```

   GitHub marks the PR as merged automatically when its commits land on the game branch. (If you
   prefer to click "Merge" on GitHub first, that is fine too — but code still reaches Studio only
   when you run the apply script.)

**Undo before you Publish:** if the merge happened but you changed your mind and have *not* pushed,
ask Claude locally: *"undo the last merge on this branch, I haven't pushed it"*. If the merge hit a
conflict, `git merge --abort` puts everything back.

---

## 5. Installing the tools (rokit)

`rokit.toml` pins: rojo 7.7.0, luau-lsp 1.70.0, selene 0.31.0. Rokit installs them onto your PATH
(`~/.rokit/bin`) so `scripts/check.sh` and CI use identical versions.

**Windows (PowerShell, once):**

```powershell
Invoke-RestMethod https://raw.githubusercontent.com/rojo-rbx/rokit/main/scripts/install.ps1 | Invoke-Expression
```

Close and reopen the terminal, then, in the repo folder (PowerShell or Git Bash):

```
rokit install
```

The first time, rokit asks whether you trust each tool's author (`rojo-rbx`, `JohnnyMorganz`,
`Kampfkarren`) — answer `y`.

**Mac (Terminal, once):**

```bash
curl -sSf https://raw.githubusercontent.com/rojo-rbx/rokit/main/scripts/install.sh | bash
```

Reopen the terminal, then in the repo folder: `rokit install` (answer `y` to the trust questions the first time).

Check it worked: `rojo --version`, `luau-lsp --version`, `selene --version`.

**No rokit?** `scripts/check.sh` also accepts an environment variable `LUAU_TOOLS_DIR` pointing at a
folder that contains the three binaries. If neither is found it prints these install instructions
and exits with code 2.

---

## 6. Running `scripts/check.sh` yourself

It is a plain bash script (works in Git Bash on Windows, macOS's built-in bash, and Linux). Three modes:

| Command | What it does | Exit code |
| --- | --- | --- |
| `scripts/check.sh` | The gate: rojo build must succeed; luau-lsp findings must all be in `lint/baseline.luau-lsp.txt`; selene must have no error-level lints (skipped locally if it cannot fetch the Roblox API dump). | 0 pass, non-zero fail, 2 tools missing |
| `scripts/check.sh --report` | Prints every finding, new or not, and never fails *on findings*. Good for a look around. | 0 — or 1 if the Rojo build is broken or selene finds an error-level lint |
| `scripts/check.sh --update` | Re-writes `lint/baseline.luau-lsp.txt` from the current findings. Use only after a deliberate change; commit the file and say why. | 0 — same two exceptions |

It only runs on a checkout whose `default.project.json` is named `CrackAGeode`; on any other branch
it prints "not a Crack a Geode checkout — nothing to check" and exits 0. Outputs land in `.lint/`
(it ignores itself, so it can't be committed): `build.rbxl`, `rojo-build.txt`, `sourcemap.json`,
`luau-lsp.txt` (raw analyzer output), `findings.txt` (all current fingerprints), `new-findings.txt`,
`fixed-findings.txt`, `selene.txt`, and the downloaded `globalTypes.d.luau` (Roblox type definitions,
fetched once, ~850 KB).

A **fingerprint** is what every run prints ("91 finding(s) -> 58 unique fingerprint(s)"): one line
`file | category | message` with the line number stripped, so identical messages collapse into one
entry and moving code around does not change the list. Exit code 2 means a setup problem (tools
missing, a broken `.luaurc`, or the analyzer reported nothing at all while the baseline is not empty —
the script refuses to call that a pass).

**Windows — three ways to run it:**

1. **Git Bash window:** Start menu → "Git Bash" (or right-click inside the repo folder → "Open Git
   Bash here"; on Windows 11 it may be under "Show more options"). Then:

   ```bash
   cd "/c/Users/<you>/<repo folder>"
   scripts/check.sh
   ```

2. **From PowerShell, using Git's bash directly** (Git for Windows ships bash at
   `C:\Program Files\Git\bin\bash.exe`):

   ```powershell
   & "C:\Program Files\Git\bin\bash.exe" scripts/check.sh
   & "C:\Program Files\Git\bin\bash.exe" scripts/check.sh --report
   ```

   If that path does not exist (per-user install), use
   `& "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe" scripts/check.sh` instead.

   Do **not** rely on plain `bash scripts/check.sh` in PowerShell: on many Windows machines `bash`
   resolves to the WSL launcher (`C:\Windows\System32\bash.exe`), which is a different Linux and
   won't see your rokit tools.

3. **Inside Claude Code locally:** just ask *"run scripts/check.sh and explain the result"*. Claude
   will use Git Bash.

**Mac:**

```bash
cd ~/path/to/repo
scripts/check.sh            # or: bash scripts/check.sh
```

**Re-baselining (when the baseline should legitimately change):**

```bash
scripts/check.sh --update
git diff lint/baseline.luau-lsp.txt      # eyeball what was added/removed
git add lint/baseline.luau-lsp.txt
git commit -m "lint: re-baseline after <reason>"
```

The baseline is a "ratchet": it should only shrink over time. If a `--update` *adds* lines, be
sure you know why (usually: new code from Studio that hasn't been type-cleaned yet — fine, just say so).

---

## 7. Pausing, resuming, deleting or poking the weekly run

The schedule is a "Routine" that belongs to your Claude account. You manage it by talking to Claude
in a **cloud** Claude Code session (claude.ai/code) in plain words — no settings pages needed:

- *"Pause the weekly Crack a Geode routine."* — it stays defined but stops firing.
- *"Resume the weekly Crack a Geode routine."*
- *"Delete the weekly Crack a Geode routine."* — removes it entirely (this cannot be undone; pausing is usually all you need).
- *"Run the weekly Crack a Geode routine now."* — fires it immediately (handy after a Studio export).
- *"List my routines."* — shows name, schedule (in UTC), enabled state and the last run's status.
- *"Change the weekly Crack a Geode routine to Wednesdays at 9am my time."* — reschedule.

You can also see the Routine in the Routines list in Claude Code on the web. Pausing costs nothing;
resuming picks up the next Monday.

---

## 8. FAQ

**Why is CI red on day one?**
Most likely one of these, all normal:
- The baseline (`lint/baseline.luau-lsp.txt`) was generated from the August code. After you export
  the newer Studio scripts, new type/lint findings appear and the ratchet fails. Fix: run
  `scripts/check.sh --update` locally, commit the baseline, push.
- selene is a **hard** gate only in CI (locally it is skipped when it can't download the Roblox API
  dump, which is the case in the agent's cloud sandbox). An error-level lint (undefined variable,
  duplicate table key, a parse error) that was invisible locally shows up red in CI first. Click
  *Details* on the failed job; the message names the file and line.
- `.lint/` was accidentally committed, or `rokit.toml` wasn't merged so `setup-rokit` had nothing
  to install. Check setup step 2.

**The report says the repo may be behind Studio. What now?**
The last commit that touched `src/` on the game branch is older than 21 days (merging reports or
automation files does not count), so the agent assumes your Studio place has changed since. Do setup step 1 (export from Studio, commit, push), then either wait for next Monday
or ask Claude to *"run the weekly Crack a Geode routine now"*. Don't apply a PR that was built on a
stale repo — the local session would overwrite newer Studio scripts with older ones plus the fix.

**Can I ignore a PR?**
Yes. Close it, or leave it. Nothing happens until you run the apply script. Old
`claude/auto-improve-*` branches can be deleted from GitHub whenever you like.

**Can the agent change prices, IDs, drop rates or the economy?**
No. Those are yours. It writes a proposal (with a prompt you can paste into your local session) and
stops. Same for anything visual, anything needing art, and anything needing Studio.

**What if the agent broke something that CI can't see?**
That is exactly why you playtest after the apply step and before Publish. If something is wrong in
Studio, don't Publish; tell the local Claude session what you saw, or `git merge --abort` / undo the
merge (section 4) and close the PR with a comment. The next weekly run reads recent reports and
the backlog, so leave a note in `automation/IDEAS_BACKLOG.md` if it should not retry.

**Why no auto-formatter?**
`Config.luau` and `Zones.luau` contain tables aligned by hand so the numbers line up in columns.
A formatter (StyLua) would rewrite all 30 files, break that alignment, and make every PR
unreviewable. The system deliberately has no formatter; the checks are build + types + lints only.

**Does the agent need my computer to be on?**
No. It runs in the cloud. Only the apply step needs your machine (and Studio open).

**What does "baseline" / "ratchet" mean?**
`lint/baseline.luau-lsp.txt` is the list of type/lint findings we already know about. On day one the
analyzer reported 91 findings (81 type errors + 10 lints, almost all harmless type-checker noise),
stored as 58 **fingerprints** — a fingerprint is `file | category | message` with the line number
stripped, so identical messages collapse into one line and moving code around does not change the
list. The gate fails only on fingerprints *not* on that list, so old noise never blocks you, but new
noise can't sneak in. Fixing an old finding makes the list shorter ("ratchet").

**`bash scripts/check.sh` says `$'\r': command not found` or `set: pipefail: invalid option name`.**
The script was checked out with Windows (CRLF) line endings — this happens when `.gitattributes` was
missing at checkout time. Fix: delete the file and let git rewrite it with the right endings:

```bash
rm scripts/check.sh scripts/apply-improvements.sh
git checkout -- scripts
```

(The repo's `.gitattributes` pins `*.sh` to LF, so the restored files are correct.)

**What can't the local session do either?**
It can read/write scripts in the open place and run code there, but it cannot Publish for you, and
it should not be asked to rebuild the hub geometry, lighting, or art — those are Studio-hand work.

**Where do I look when something is confusing?**
`CLAUDE.md` (rules and map of the code), `automation/PLAYBOOK.md` (exactly what the agent does),
`automation/reports/` (history), `automation/IDEAS_BACKLOG.md` (what's known/planned). Or ask Claude
in the repo — it reads all of these.
