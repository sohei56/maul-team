"""Textual TUI Dashboard for Maul Team.

Three-panel real-time dashboard that monitors .scrum/ JSON files via
watchdog filesystem events. Designed to run in a tmux side pane alongside
Claude Code.

Panels:
  (a) Sprint Overview — Sprint Goal, project phase, PBI count, Developer
      assignments
  (b) Unified PBI Board — single DataTable showing each PBI's 13-value
      status (SSOT lives in `backlog.json.items[].status`). Per-PBI round
      counters come from `pbi/<id>/state.json`, but the status displayed
      is always the backlog SSOT — there is no separate phase column.
  (c) Work Log — merged chronological log of agent messages
      (communications.json) and work events (dashboard.json); `f` cycles
      the filter all → messages → work
"""

from __future__ import annotations

import json
import logging
import zlib
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from threading import Lock, Timer

from rich.cells import cell_len
from rich.markup import escape
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Vertical
from textual.widgets import DataTable, Footer, Header, RichLog, Static
from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer

try:
    from jsonschema import ValidationError
    from jsonschema import validate as _jsonschema_validate

    _SCHEMA_VALIDATION = True
except ImportError:  # pragma: no cover — fallback path when jsonschema absent
    _SCHEMA_VALIDATION = False

    class ValidationError(Exception):  # type: ignore[no-redef]
        pass

    def _jsonschema_validate(_data, _schema) -> None:  # type: ignore[misc]
        return None


logger = logging.getLogger(__name__)

SCRUM_DIR = Path(".scrum")

# Route logger output to .scrum/dashboard.log so users can
# `tail -f .scrum/dashboard.log` to debug silent schema rejections during
# TUI runs (Textual takes over stderr, hiding warnings otherwise).
# Guard against double-add when dashboard.app is re-imported (e.g. in tests).
if not logger.handlers:
    SCRUM_DIR.mkdir(parents=True, exist_ok=True)
    _log_handler = logging.FileHandler(SCRUM_DIR / "dashboard.log", mode="a", encoding="utf-8")
    _log_handler.setFormatter(
        logging.Formatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s")
    )
    logger.addHandler(_log_handler)
    logger.setLevel(logging.WARNING)

# SSOT schemas live alongside the contracts catalog. Each .scrum/<name>.json
# is validated against its schema on read; failures fall back to "stale data"
# rather than crashing the dashboard.
SCRUM_STATE_DIR = Path(__file__).resolve().parent.parent / "docs" / "contracts" / "scrum-state"

_SCHEMA_FOR_FILE = {
    "state.json": "state.schema.json",
    "sprint.json": "sprint.schema.json",
    "backlog.json": "backlog.schema.json",
    "communications.json": "communications.schema.json",
    "dashboard.json": "dashboard.schema.json",
}

# 13-value status SSOT — see docs/contracts/scrum-state/backlog.schema.json.
# Actor-split coloring: SM-managed states use green family, Developer-managed
# in_progress_* states use blue/cyan family. Terminal/escalated use red.
STATUS_COLORS = {
    # SM-managed (green family + neutrals)
    "draft": "dim",
    "refined": "yellow",
    "blocked": "red",
    "awaiting_cross_review": "bright_green",
    "cross_review": "bright_green",
    "escalated": "red",
    "done": "green",
    "cancelled": "dim",
    # Developer-managed (blue/cyan family)
    "in_progress_design": "cyan",
    "in_progress_impl": "blue",
    "in_progress_pbi_review": "bright_blue",
    "in_progress_ut_run": "bright_cyan",
    "in_progress_merge": "magenta",
}

# Compact display labels for the 13-value status enum. Keep short enough
# for a status column in a DataTable.
STATUS_LABELS = {
    "draft": "draft",
    "refined": "refined",
    "blocked": "blocked",
    "in_progress_design": "design",
    "in_progress_impl": "impl",
    "in_progress_pbi_review": "pbi-review",
    "in_progress_ut_run": "ut-run",
    "in_progress_merge": "merge",
    "awaiting_cross_review": "await-x-rev",
    "cross_review": "x-review",
    "escalated": "escalated",
    "done": "done",
    "cancelled": "cancelled",
}

# Developer-managed status set — used both to pick which round counter to
# surface (design_round vs impl_round) for live PBIs and to derive the
# at-a-glance actor glyph in format_status (◆ Developer-managed, ◇ SM-managed).
DEV_MANAGED_STATUSES = frozenset(
    {
        "in_progress_design",
        "in_progress_impl",
        "in_progress_pbi_review",
        "in_progress_ut_run",
        "in_progress_merge",
    }
)

# Project-level phase flow rendered in Sprint Overview. This is the
# **project-level** phase from `state.json.phase` — distinct from PBI
# status. The PBI-level `phase` field was removed by the status/phase
# unification.
PHASE_FLOW = [
    ("new", "New"),
    ("requirements_sprint", "Requirement Definition"),
    ("backlog_created", "Backlog Created"),
    ("sprint_planning", "Sprint Planning"),
    ("pbi_pipeline_active", "PBI Development"),
    ("review", "Cross Review"),
    ("sprint_review", "Sprint Review"),
    ("retrospective", "Retrospective"),
    ("integration_sprint", "Integration Tests"),
    ("uat_release", "UAT & Release"),
    ("complete", "Complete"),
]


def format_phase(current_phase: str) -> str:
    """Render the project-level Scrum phase as a compact highlighted label.

    `current_phase` is the value from `state.json.phase` (project-level
    state machine), not a PBI status.
    """
    for phase_key, phase_label in PHASE_FLOW:
        if phase_key == current_phase:
            return f"[bold]Phase:[/bold] [bold white on blue] {phase_label} [/]"
    return f"[bold]Phase:[/bold] [bold white on red] {current_phase} [/]"


# Semantic colors for a raw `sprint.json.status` value. Replaces a plain
# unmapped print, which gave `complete`/`failed` no visual distinction.
_SPRINT_STATUS_COLORS = {
    "complete": "green",
    "failed": "red",
    "planning": "grey62",
    "active": "blue",
    "cross_review": "blue",
    "sprint_review": "blue",
}


def format_sprint_status(status: str) -> str:
    """Render a `sprint.json.status` value with a semantic color."""
    color = _SPRINT_STATUS_COLORS.get(status)
    return f"[{color}]{status}[/{color}]" if color else status


def format_status(status: str) -> str:
    """Render a 13-value PBI status with icon + color + short label."""
    # Actor glyph is derivable from the status: ◆ Developer-managed, ◇ any
    # other *known* status (SM-managed). An unknown / missing status (e.g. the
    # "?" placeholder) gets no glyph, preserving the pre-derivation default.
    if status in DEV_MANAGED_STATUSES:
        icon = "◆"
    elif status in STATUS_LABELS:
        icon = "◇"
    else:
        icon = ""
    label = STATUS_LABELS.get(status, status)
    color = STATUS_COLORS.get(status, "")
    body = f"{icon} {label}".strip()
    if color:
        return f"[{color}]{body}[/{color}]"
    return body


def get_backlog_items(backlog: dict | None) -> list:
    """Return PBI items from a schema-validated backlog dict.

    The backlog schema declares ``items`` as the canonical list, so callers
    do not need any alternative key fallback. ``None`` (e.g. missing or
    invalid file) yields an empty list.
    """
    if backlog is None:
        return []
    return backlog.get("items", [])


def read_json(path: Path) -> dict | list | None:
    """Read a JSON file, returning None if missing or invalid."""
    try:
        if path.exists():
            return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError, UnicodeDecodeError):
        pass
    return None


def read_json_validated(path: Path) -> dict | None:
    """Read a `.scrum/<name>.json` file and validate against its SSOT schema.

    Returns None on missing file, invalid JSON, schema violation, or any I/O
    error. Schema violations are logged at warning level so the dashboard
    degrades to a "stale data" placeholder rather than crashing.

    Files unknown to ``_SCHEMA_FOR_FILE`` (e.g. ``test-results.json``,
    ``session-map.json``) fall back to plain ``read_json``.

    When ``jsonschema`` is unavailable (import failed at module load), this
    delegates unconditionally to ``read_json``.
    """
    data, _ = read_json_with_validation_status(path)
    return data


def read_json_with_validation_status(path: Path) -> tuple[dict | None, str | None]:
    """Variant of read_json_validated that also surfaces a validation error
    string so panels can render a visible banner instead of degrading to an
    empty view (which makes schema regressions hard to diagnose).

    Returns ``(data, None)`` on success and ``(None, message)`` when the file
    exists but fails JSON parsing or schema validation. ``(None, None)`` when
    the file is simply missing or schema validation is disabled.
    """
    schema_name = _SCHEMA_FOR_FILE.get(path.name)
    if schema_name is None or not _SCHEMA_VALIDATION:
        result = read_json(path)
        return (result if isinstance(result, dict) else None, None)
    try:
        if not path.exists():
            return (None, None)
        data = json.loads(path.read_text(encoding="utf-8"))
        schema = json.loads((SCRUM_STATE_DIR / schema_name).read_text(encoding="utf-8"))
        _jsonschema_validate(data, schema)
        return (data if isinstance(data, dict) else None, None)
    except ValidationError as exc:
        logger.warning("Schema validation failed for %s: %s", path.name, exc.message)
        return (None, f"schema: {exc.message}")
    except json.JSONDecodeError as exc:
        return (None, f"invalid JSON: {exc.msg}")
    except (OSError, UnicodeDecodeError) as exc:
        return (None, f"read error: {exc}")


class SprintOverview(Static):
    """Panel (a): Sprint Goal, project phase, PBI count, Developer assignments."""

    DEFAULT_CSS = """
    SprintOverview {
        height: auto;
        min-height: 5;
        border: solid $accent;
        padding: 0 1;
    }
    """

    def update_content(self) -> None:
        state = read_json_validated(SCRUM_DIR / "state.json")
        sprint = read_json_validated(SCRUM_DIR / "sprint.json")
        backlog = read_json_validated(SCRUM_DIR / "backlog.json")

        if not state:
            self.update("[bold]No project state[/bold]\nRun scrum-start.sh to begin.")
            return

        phase = state.get("phase", "unknown")
        product_goal = state.get("product_goal", "Not defined")

        lines = [f"[bold]Product Goal:[/bold] {product_goal}"]
        lines.append(format_phase(phase))

        # Integration Sprint / UAT & Release are post-development stages: the
        # last dev Sprint is already `complete`, so the *phase* is the
        # protagonist and the closed Sprint recedes to a context line. Without
        # this, the panel reads "Sprint-N | Status: complete" next to
        # "Phase: Integration Tests", which looks self-contradictory.
        release_stage = phase in ("integration_sprint", "uat_release")

        if sprint and isinstance(sprint, dict):
            sprint_id = sprint.get("id", "?")
            goal = sprint.get("goal") or "No goal"
            sprint_status = sprint.get("status", "?")

            # Derive PBI counts from backlog.items where sprint_id matches —
            # sprint.pbi_ids was demoted to a derived field in OD-4 (1c240b4).
            pbi_count = 0
            done_count = 0
            if backlog:
                for item in get_backlog_items(backlog):
                    if item.get("sprint_id") == sprint_id:
                        status = item.get("status")
                        if status == "cancelled":
                            continue  # terminal non-delivery; not in progress ratio
                        pbi_count += 1
                        if status == "done":
                            done_count += 1

            devs = sprint.get("developers") or []
            dev_count = len(devs)

            if release_stage:
                stage_label = dict(PHASE_FLOW).get(phase, phase)
                lines.append(
                    f"[bold white on dark_orange] {stage_label} · ACTIVE [/]"
                    f"  [dim]following {sprint_id} · closed[/dim]"
                )
                lines.append(
                    f"[bold]Delivered:[/bold] {done_count}/{pbi_count} PBIs"
                    f" | [bold]Goal:[/bold] {goal}"
                )
            else:
                lines.append(
                    f"[bold]Sprint:[/bold] {sprint_id}"
                    f" | [bold]Status:[/bold] {format_sprint_status(sprint_status)}"
                    f" | [bold]Goal:[/bold] {goal}"
                )

                lines.append(
                    f"[bold]PBIs:[/bold] {done_count}/{pbi_count} done"
                    f" | [bold]Developers:[/bold] {dev_count}"
                )

                if devs:
                    dev_parts = []
                    for d in devs:
                        did = d.get("id", "?")
                        status = d.get("status", "?")
                        impl = d.get("assigned_work", {}).get("implement", [])
                        dev_parts.append(f"{did}:{status}({','.join(impl)})")
                    lines.append(f"[bold]Agents:[/bold] {' | '.join(dev_parts)}")
        else:
            lines.append("[dim]No active Sprint — waiting for Sprint Planning[/dim]")

        self.update("\n".join(lines))


def _truncate_to_cells(s: str, budget: int) -> str:
    """Truncate ``s`` so its terminal display width fits within ``budget`` cells.

    Uses Rich's ``cell_len`` so CJK / full-width characters are counted as 2
    cells — ``len()`` would undercount them and let the title overflow the
    DataTable column, which triggers horizontal scroll on the PBI board.
    Appends a one-cell ellipsis when truncation actually happens.
    """
    if cell_len(s) <= budget:
        return s
    target = max(0, budget - 1)
    out: list[str] = []
    width = 0
    for ch in s:
        w = cell_len(ch)
        if width + w > target:
            break
        out.append(ch)
        width += w
    return "".join(out) + "…"


class UnifiedPbiBoard(DataTable):
    """Single PBI board driven by the 13-value status SSOT.

    Columns: ID, Title, Status, Round, Dev, Updated.

    Status comes exclusively from ``backlog.json.items[].status`` — the
    SSOT after the status/phase unification. Per-PBI round counters and
    last_updated come from ``pbi/<id>/state.json`` (which no longer
    carries a phase field).
    """

    DEFAULT_CSS = """
    UnifiedPbiBoard {
        height: 1fr;
        border: solid $accent;
    }
    """

    # Cell-width budget used the last time titles were rendered. Tracked so
    # ``on_resize`` only re-renders when the budget actually changes (avoids
    # row-rebuild jitter on every minor resize event).
    _last_title_budget: int = -1

    def on_mount(self) -> None:
        self.add_columns("ID", "Title", "Status", "Round", "Dev", "Updated")
        self.cursor_type = "row"
        self.update_content()

    def on_resize(self) -> None:
        new_budget = self._compute_title_budget()
        if new_budget != self._last_title_budget:
            self.update_content()

    def _compute_title_budget(self) -> int:
        # Non-title chrome (ID/Status/Round/Dev/Updated widths + per-cell
        # padding + border) caps out around 55 cells in the worst case.
        non_title_chrome = 55
        container_w = self.size.width or 80
        return max(10, container_w - non_title_chrome)

    def update_content(self) -> None:
        backlog, backlog_error = read_json_with_validation_status(SCRUM_DIR / "backlog.json")
        sprint = read_json_validated(SCRUM_DIR / "sprint.json")
        self.clear()

        # Surface schema violations so an "empty board" never silently masks a
        # malformed backlog.json (e.g. wrong type for a single field).
        if backlog_error:
            truncated = backlog_error if len(backlog_error) <= 80 else backlog_error[:77] + "..."
            self.add_row(
                "[red]⚠[/red]",
                f"[red]backlog.json invalid — {truncated}[/red]",
                "[red]see .scrum/dashboard.log[/red]",
                "-",
                "-",
                "-",
                key="__backlog_invalid__",
            )
            return

        # PBI → developer (lowercase keys for case-insensitive lookup)
        pbi_impl_map: dict[str, str] = {}
        if sprint and isinstance(sprint, dict):
            for dev in sprint.get("developers") or []:
                did = dev.get("id", "?")
                for pbi_id in (dev.get("assigned_work") or {}).get("implement") or []:
                    pbi_impl_map[pbi_id.lower()] = did

        items = get_backlog_items(backlog)
        now = datetime.now(timezone.utc)

        # Truncate titles dynamically so the board fits the container width
        # (no horizontal scroll). Measured in terminal cells, not str length,
        # so CJK / full-width characters don't overflow the column.
        title_budget = self._compute_title_budget()
        self._last_title_budget = title_budget

        for item in items:
            pbi_id = item.get("id") or "?"
            pbi_key = pbi_id.lower()
            raw_title = item.get("title") or "Untitled"
            title = _truncate_to_cells(raw_title, title_budget)

            status = item.get("status", "?")
            status_display = format_status(status)

            # Per-PBI pipeline state for round/last_updated. After the
            # status/phase unification this file no longer carries a
            # `phase` field; we only read round counters and updated_at.
            state = read_json(SCRUM_DIR / "pbi" / pbi_id / "state.json") or read_json(
                SCRUM_DIR / "pbi" / pbi_key / "state.json"
            )
            if not isinstance(state, dict):
                state = None

            # Pick the round counter relevant to the current status:
            # design uses design_round; everything else uses impl_round.
            round_no = None
            if state:
                if status == "in_progress_design":
                    round_no = state.get("design_round")
                elif status in DEV_MANAGED_STATUSES:
                    round_no = state.get("impl_round")
                else:
                    round_no = state.get("impl_round") or state.get("design_round")

            round_cell = _format_round(round_no) if round_no is not None else "[dim]-[/dim]"

            updated_at = state.get("updated_at") if state else None
            updated_cell = _humanize_age(updated_at, now) if updated_at else "[dim]-[/dim]"

            dev = pbi_impl_map.get(pbi_key) or item.get("implementer_id") or "-"

            # Escape user-authored strings: titles often contain "[tag]"
            # decorations from agent generation, and any unbalanced "[" would
            # otherwise be parsed as an unknown Rich markup tag and wipe the
            # cell. ``dev`` comes from sprint/backlog data too, so escape it
            # for the same reason. ``status_display`` / ``round_cell`` /
            # ``updated_cell`` are intentionally Rich-formatted by us, so
            # they pass through untouched.
            self.add_row(
                pbi_id,
                escape(title),
                status_display,
                round_cell,
                escape(str(dev)),
                updated_cell,
                key=pbi_id,
            )

        # Scroll to the last row so the latest PBI is visible
        if self.row_count:
            self.move_cursor(row=self.row_count - 1)


class TestResultsPanel(Static):
    """Panel: Test results from Integration Sprint smoke-test."""

    DEFAULT_CSS = """
    TestResultsPanel {
        height: auto;
        min-height: 3;
        border: solid $accent;
        padding: 0 1;
    }
    """

    STATUS_STYLES = {
        "passed": "[bold green]PASSED[/bold green]",
        "passed_with_skips": "[bold yellow]PASSED (with skips)[/bold yellow]",
        "failed": "[bold red]FAILED[/bold red]",
        "running": "[bold yellow]RUNNING[/bold yellow]",
        "pending": "[bold dim]PENDING[/bold dim]",
        "skipped": "[dim]SKIPPED[/dim]",
    }

    def update_content(self) -> None:
        results = read_json(SCRUM_DIR / "test-results.json")
        if not results:
            self.display = False
            return

        self.display = True
        overall = results.get("overall_status", "unknown")
        overall_styled = self.STATUS_STYLES.get(overall, f"[bold]{overall}[/bold]")

        lines = [f"[bold]Test Results:[/bold] {overall_styled}"]

        for cat in results.get("categories", []):
            if not isinstance(cat, dict):
                continue
            name = cat.get("name", "?")
            status = cat.get("status", "?")
            total = cat.get("total", 0)
            passed = cat.get("passed", 0)
            failed = cat.get("failed", 0)

            if status == "passed":
                line = f"  [green]{name}: {passed}/{total} passed[/green]"
            elif status == "failed":
                line = f"  [red]{name}: {passed}/{total} passed ({failed} failed)[/red]"
            elif status == "skipped":
                line = f"  [dim]{name}: skipped[/dim]"
            else:
                line = f"  [yellow]{name}: {status}[/yellow]"
            lines.append(line)

            # Show first 3 errors for failed categories
            if status == "failed":
                errors = cat.get("errors", [])
                for err in errors[:3]:
                    if not isinstance(err, dict):
                        continue
                    test_name = err.get("test_name", "?")
                    message = err.get("message", "?")
                    lines.append(f"    [red]- {test_name}: {message}[/red]")
                if len(errors) > 3:
                    lines.append(f"    [dim]  (+{len(errors) - 3} more errors)[/dim]")

        self.update("\n".join(lines))


# Stable per-agent colors so each agent's lines are visually traceable.
# Red is excluded — it is reserved for deletions/escalations/errors.
_AGENT_PALETTE = (
    "cyan",
    "green",
    "yellow",
    "blue",
    "magenta",
    "bright_cyan",
    "bright_green",
    "bright_blue",
)


def _agent_color(name: str) -> str:
    if not name or name == "?":
        return "white"
    return _AGENT_PALETTE[zlib.crc32(name.encode("utf-8")) % len(_AGENT_PALETTE)]


def _format_comm_line(msg: dict) -> str:
    """Render one communications.json message as a Rich markup line."""
    ts_short = _format_ts_short(msg.get("timestamp", "?"))
    sender = str(msg.get("sender_id") or "?")
    role = msg.get("sender_role") or ""
    recipient = msg.get("recipient_id")
    mtype = msg.get("type", "")
    content = escape(str(msg.get("content") or ""))
    color = _agent_color(sender)

    parts = [f"[dim]{ts_short}[/dim]", f"[bold {color}]{escape(sender)}[/bold {color}]"]
    if role:
        parts.append(f"[dim]({escape(str(role))})[/dim]")
    if recipient and recipient != "all":
        parts.append(f"→ [bold]{escape(str(recipient))}[/bold]")
    if mtype == "message":
        parts.append("✉")
    elif mtype == "escalation":
        content = f"[red]{content}[/red]"
    parts.append(content)
    return " ".join(parts)


def _format_event_line(evt: dict) -> str:
    """Render one dashboard.json work event as a Rich markup line.

    Leads with the agent name (same as comms lines) so the merged Work Log
    consistently reads "who did what".
    """
    ts_short = _format_ts_short(evt.get("timestamp", "?"))
    evt_type = evt.get("type", "?")
    agent = str(evt.get("agent_id") or "?")
    color = _agent_color(agent)
    agent_str = f"[bold {color}]{escape(agent)}[/bold {color}]"
    file_path = evt.get("file_path") or ""
    change = evt.get("change_type") or ""
    detail = escape(str(evt.get("detail") or ""))

    if evt_type == "file_changed" and file_path:
        ccolor = {"created": "green", "modified": "yellow", "deleted": "red"}.get(change, "")
        change_str = f"[{ccolor}]{change}[/{ccolor}]" if ccolor else change
        return f"[dim]{ts_short}[/dim] {agent_str} {change_str} {escape(str(file_path))}"
    if evt_type == "teammate_idle":
        # schema-permitted; no current producer (external writers may emit)
        return f"[dim]{ts_short}[/dim] {agent_str} [cyan]idle[/cyan] {detail}"
    if evt_type == "status_transition":
        # status_from/status_to: schema-permitted; no current producer
        # (external writers may emit) — falls back to detail when absent.
        status_from = evt.get("status_from") or ""
        status_to = evt.get("status_to") or ""
        arrow = f"{status_from} → {status_to}" if status_from or status_to else detail
        return f"[dim]{ts_short}[/dim] {agent_str} [magenta]status[/magenta] {arrow}"
    if evt_type == "stop_failure":
        return f"[dim]{ts_short}[/dim] {agent_str} [red]failed[/red] {detail}"
    if detail:
        return f"[dim]{ts_short}[/dim] {agent_str} {detail}"
    return f"[dim]{ts_short}[/dim] {agent_str} {evt_type}"


class UnifiedLog(RichLog):
    """Panel (c): merged chronological log of agent messages and work events.

    Reads communications.json (messages) and dashboard.json (work events),
    normalizes new entries to ``(timestamp, category, line)`` and appends
    them in timestamp order. New-entry detection is cursor-based — last
    seen timestamp plus the count of entries sharing it — so the log keeps
    flowing after the SSOT arrays hit their max_messages/max_events caps
    and get head-trimmed (a length-delta cursor freezes at the cap).
    """

    DEFAULT_CSS = """
    UnifiedLog {
        height: 1fr;
        border: solid $accent;
    }
    """

    MAX_ENTRIES = 300
    FILTER_MODES = ("all", "messages", "work")

    def __init__(self, **kwargs) -> None:
        super().__init__(highlight=True, markup=True, wrap=True, **kwargs)
        self._cursors: dict[str, tuple[str, int]] = {}
        self._entries: deque[tuple[str, str, str]] = deque(maxlen=self.MAX_ENTRIES)
        self._filter = "all"

    @property
    def filter_mode(self) -> str:
        return self._filter

    def cycle_filter(self) -> str:
        """Advance the filter (all → messages → work) and re-render."""
        modes = self.FILTER_MODES
        self._filter = modes[(modes.index(self._filter) + 1) % len(modes)]
        self.clear()
        for _ts, category, line in self._entries:
            if self._matches_filter(category):
                self.write(line)
        return self._filter

    def _matches_filter(self, category: str) -> bool:
        if self._filter == "all":
            return True
        return (self._filter == "messages") == (category == "message")

    def update_content(self) -> None:
        batch: list[tuple[str, str, str]] = []

        comms = read_json_validated(SCRUM_DIR / "communications.json")
        if comms:
            for msg in self._fresh(comms.get("messages", []), "comms"):
                batch.append((str(msg.get("timestamp") or ""), "message", _format_comm_line(msg)))

        dashboard = read_json_validated(SCRUM_DIR / "dashboard.json")
        if dashboard:
            for evt in self._fresh(dashboard.get("events", []), "events"):
                batch.append((str(evt.get("timestamp") or ""), "work", _format_event_line(evt)))

        if not batch:
            return

        # Stable sort: equal timestamps keep their within-source file order.
        batch.sort(key=lambda entry: entry[0])
        for entry in batch:
            self._entries.append(entry)
            if self._matches_filter(entry[1]):
                self.write(entry[2])

    def _fresh(self, items: list, source: str) -> list[dict]:
        """Return entries not yet rendered, advancing the source cursor."""
        last_ts, seen_at_ts = self._cursors.get(source, ("", 0))
        skipped = 0
        fresh: list[dict] = []
        for item in items:
            if not isinstance(item, dict):
                continue
            ts = str(item.get("timestamp") or "")
            if ts < last_ts:
                continue
            if ts == last_ts and skipped < seen_at_ts:
                skipped += 1
                continue
            fresh.append(item)
        if fresh:
            max_ts = str(fresh[-1].get("timestamp") or "")
            at_max = sum(
                1
                for item in items
                if isinstance(item, dict) and str(item.get("timestamp") or "") == max_ts
            )
            self._cursors[source] = (max_ts, at_max)
        return fresh


# Round count above this is highlighted as a stagnation hint.
PIPELINE_ROUND_WARN_THRESHOLD = 2


def _format_ts_short(ts: str | None) -> str:
    """Render an ISO-8601 timestamp as ``HH:MM:SS``.

    Falls back to the first 8 characters of the raw value when parsing
    fails (matches prior inline behavior across both message and event
    log panels).
    """
    try:
        dt = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
        return dt.strftime("%H:%M:%S")
    except (ValueError, AttributeError, TypeError):
        return str(ts)[:8]


def _humanize_age(ts: str | None, now: datetime) -> str:
    """Render an ISO-8601 timestamp as ``Ns ago`` / ``Nm ago`` / ``Nh ago``.

    Returns a dim ``?`` placeholder when the timestamp is missing or
    cannot be parsed. Naive timestamps are treated as UTC, matching how
    the SSOT writers stamp ``last_event_at``.
    """
    if not ts or ts == "?":
        return "[dim]?[/dim]"
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except (ValueError, AttributeError, TypeError):
        return "[dim]?[/dim]"
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    delta = (now - dt).total_seconds()
    if delta < 0:
        return "now"
    if delta < 60:
        return f"{int(delta)}s ago"
    if delta < 3600:
        return f"{int(delta // 60)}m ago"
    if delta < 86400:
        return f"{int(delta // 3600)}h ago"
    return f"{int(delta // 86400)}d ago"


def _format_round(round_no) -> str:
    if not isinstance(round_no, int):
        return "[dim]-[/dim]"
    if round_no > PIPELINE_ROUND_WARN_THRESHOLD:
        return f"[red]{round_no}[/red]"
    return str(round_no)


class ScrumFileHandler(FileSystemEventHandler):
    """Watchdog handler that triggers debounced dashboard updates on .scrum/ changes.

    Uses a 200ms debounce timer so that rapid writes (e.g., tmp-file + mv)
    are coalesced into a single refresh rather than causing redundant redraws.
    """

    DEBOUNCE_SECONDS = 0.2

    def __init__(self, app: ScrumDashboard) -> None:
        super().__init__()
        self.app = app
        self._lock = Lock()
        self._pending_timer: object | None = None

    def on_modified(self, event) -> None:
        if event.is_directory:
            return
        self._schedule_update()

    def on_created(self, event) -> None:
        if event.is_directory:
            return
        self._schedule_update()

    def on_moved(self, event) -> None:
        self._schedule_update()

    def _schedule_update(self) -> None:
        with self._lock:
            # Cancel any pending debounce timer and start a new one
            if self._pending_timer is not None:
                self._pending_timer.cancel()
            self._pending_timer = Timer(
                self.DEBOUNCE_SECONDS,
                lambda: self.app.call_from_thread(self.app.refresh_panels),
            )
            self._pending_timer.daemon = True
            self._pending_timer.start()


class ScrumDashboard(App):
    """Main Textual TUI dashboard application."""

    # Preserve the terminal's native ANSI palette instead of converting named
    # colors (red/green/cyan/...) to RGB through Textual's theme. This keeps
    # status colors readable on terminals with limited or buggy truecolor
    # support (e.g. Apple Terminal), at the cost of transparency effects we
    # do not use here. Requires textual >= 0.80.
    ansi_color = True

    TITLE = "Maul Team Dashboard"
    CSS = """
    Screen {
        layout: grid;
        grid-size: 1 3;
        grid-rows: auto 1fr 1fr;
    }
    #log-title {
        height: 1;
        text-style: bold;
        color: $text;
        padding: 0 1;
    }
    """

    BINDINGS = [
        Binding("q", "quit", "Quit"),
        Binding("r", "refresh", "Refresh"),
        Binding("f", "cycle_log_filter", "Log Filter"),
        Binding("tab", "focus_next", "Next Panel"),
    ]

    def compose(self) -> ComposeResult:
        yield Header()
        yield SprintOverview(id="overview")
        yield Vertical(
            TestResultsPanel(id="test-results"),
            Static(
                "[bold]PBI Board[/bold] [dim](status • round • dev • updated)[/dim]",
                id="pbi-title",
            ),
            UnifiedPbiBoard(id="pbi-board"),
        )
        yield Vertical(
            Static("[bold]Work Log[/bold] [dim](all)[/dim]", id="log-title"),
            UnifiedLog(id="work-log"),
        )
        yield Footer()

    def on_mount(self) -> None:
        self.refresh_panels()
        self._start_watcher()
        # Periodic fallback: refresh every 1 second in case watchdog misses events
        self.set_interval(1, self.refresh_panels)

    def _start_watcher(self) -> None:
        """Start watchdog observer for .scrum/ directory."""
        if not SCRUM_DIR.exists():
            SCRUM_DIR.mkdir(parents=True, exist_ok=True)

        # Use absolute path to avoid working directory issues
        watch_path = str(SCRUM_DIR.resolve())

        self._observer = Observer()
        self._observer.schedule(
            ScrumFileHandler(self),
            watch_path,
            recursive=True,
        )
        self._observer.daemon = True
        self._observer.start()

    def refresh_panels(self) -> None:
        """Refresh all dashboard panels from disk."""
        overview = self.query_one("#overview", SprintOverview)
        overview.update_content()

        pbi_board = self.query_one("#pbi-board", UnifiedPbiBoard)
        pbi_board.update_content()

        test_results = self.query_one("#test-results", TestResultsPanel)
        test_results.update_content()

        work_log = self.query_one("#work-log", UnifiedLog)
        work_log.update_content()

    def action_refresh(self) -> None:
        self.refresh_panels()

    def action_cycle_log_filter(self) -> None:
        mode = self.query_one("#work-log", UnifiedLog).cycle_filter()
        self.query_one("#log-title", Static).update(f"[bold]Work Log[/bold] [dim]({mode})[/dim]")

    def on_unmount(self) -> None:
        if hasattr(self, "_observer"):
            self._observer.stop()
            self._observer.join(timeout=2)


if __name__ == "__main__":
    app = ScrumDashboard()
    app.run()
