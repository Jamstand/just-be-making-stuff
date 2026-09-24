# Weekly reports

One file per weekly agent run, named by the run date in UTC: `YYYY-MM-DD.md` (e.g. `2026-09-28.md`; a second run on the same day is `2026-09-28-2.md`).
Each file follows the template in `automation/PLAYBOOK.md` (Summary, Repo freshness check, What I fixed, Metrics, Proposals for Studio, Ideas for next week, Risks/notes) and is also the body of that week's pull request.
The agent reads the two newest reports here, plus the reports on `claude/auto-improve-*` branches whose PR is still open or was closed unmerged, before choosing work — so notes you leave here (e.g. "rejected, don't retry") are seen next week, and open PRs are not redone.
Never edit a past report's facts; add a dated note at the bottom instead. This README is the only file here that is not a report.
