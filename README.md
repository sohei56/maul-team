# metrics branch

Data-only branch: weekly snapshots of GitHub Releases asset
`download_count`, appended by `.github/workflows/download-stats.yml`
(workflow_dispatch / weekly cron). Kept out of `main` because `main`
is protected (PRs + required checks) and a data append should neither
open weekly PRs nor loosen protection.

Read it raw:
https://raw.githubusercontent.com/sohei56/maul-team/metrics/metrics/downloads.jsonl
