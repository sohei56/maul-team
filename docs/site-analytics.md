# Landing-page analytics (site/)

How traffic to the GitHub Pages landing page is measured, and how to read
the numbers when deciding what to improve on the LP.

## Stack

- **Umami Cloud** (cookieless, no consent banner needed). The tracker
  snippet is in the `<head>` of `site/index.html` and `site/terms.html`,
  scoped with `data-domains="sohei56.github.io"` so local previews are
  not counted. Dashboard: <https://cloud.umami.is> (website id
  `9005e05d-1557-4ac1-bb9e-bc05201b77db`).
- **GitHub Releases `download_count`** — the funnel's bottom step.
  `.github/workflows/download-stats.yml` snapshots it weekly into
  `metrics/downloads.jsonl` (the API only exposes a cumulative counter,
  so trends exist only from snapshot diffs). Homebrew-cask installs pull
  the same dmg asset, so they are included in the count but cannot be
  distinguished from LP-button downloads.

## Event schema

| Event | Where | Data |
|---|---|---|
| `download-dmg` | all 5 dmg CTAs | `position`: `nav` / `hero` / `install` / `final-cta` / `footer` |
| `outbound` | GitHub / README links | `target`: `github` / `readme-en` / `readme-ja`, `position` |
| `section-view` | first time a section crosses mid-viewport | `id`: `why` / `demo` / `how` / `loop` / `features` / `install` |
| `demo-play` | demo video cover click | — |
| `copy-build-cmds` | build-from-source copy button | — |

Link events use Umami's declarative `data-umami-event` attributes; the
behavioral events call `track()` in the inline script, which no-ops when
the tracker is absent (ad blockers) so the page never breaks.

## UTM convention

Every link *to* the LP that we control carries UTM parameters so inflow
sources separate cleanly in the Umami dashboard:

```text
https://sohei56.github.io/maul-team/?utm_source=<source>&utm_medium=<medium>
```

- README / README_ja: `utm_source=github&utm_medium=readme`
- X (Twitter) posts: `utm_source=x&utm_medium=social`
- Release notes: `utm_source=github&utm_medium=release-notes`

Add new sources following the same pattern; Umami aggregates `utm_*`
out of the box.

## Weekly review (LP-improvement inputs)

1. **Inflow** — pageviews, visitors, top referrers, UTM breakdown.
2. **Journey** — `section-view` funnel: what share of visitors reach
   `#install`? Where does the drop-off grow?
3. **CTA** — `download-dmg` rate by `position`: which button earns its
   place; which is dead weight.
4. **Conversion** — `download-dmg` clicks vs. the week-over-week delta
   in `metrics/downloads.jsonl` totals.

Known blind spots: ad-block users are missing from Umami (but not from
`download_count`), and pre-instrumentation history is unrecoverable.
