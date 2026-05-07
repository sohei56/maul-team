"""Textual TUI Dashboard for AI-Powered Scrum Team.

Four-panel real-time dashboard that monitors .scrum/ JSON files via
watchdog filesystem events. Designed to run in a tmux side pane alongside
Claude Code.

Panels:
  (a) Sprint Overview — Sprint Goal, project phase, PBI count, Developer
      assignments
  (b) Unified PBI Board — single DataTable showing each PBI's 12-value
      status (SSOT lives in `backlog.json.items[].status`). Per-PBI round
      counters come from `pbi/<id>/state.json`, but the status displayed
      is always the backlog SSOT — there is no separate phase column.
  (c) Communication Log — scrollable agent message log
  (d) Work Log — scrollable activity/work log
"""

from __future__ import annotations

import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from threading import Lock, Timer

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
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

# 12-value status SSOT — see docs/contracts/scrum-state/backlog.schema.json.
# Actor-split coloring: SM-managed states use green family, Developer-managed
# in_progress_* states use blue/cyan family. Terminal/escalated use red.
STATUS_COLORS = {
    # SM-managed (green family + neutrals)
    "draft": "dim",
    "refined": "green",
    "blocked": "red",
    "awaiting_cross_review": "bright_green",
    "cross_review": "bright_green",
    "escalated": "red",
    "done": "green",
    # Developer-managed (blue/cyan family)
    "in_progress_design": "cyan",
    "in_progress_impl": "blue",
    "in_progress_pbi_review": "bright_blue",
    "in_progress_ut_run": "bright_cyan",
    "in_progress_merge": "magenta",
}

# Compact display labels for the 12-value status enum. Keep short enough
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
}

# Optional unicode glyphs prefixed to the status cell for at-a-glance
# actor identification: ◇ for SM-managed, ◆ for Developer-managed.
STATUS_ICONS = {
    "draft": "◇",
    "refined": "◇",
    "blocked": "◇",
    "awaiting_cross_review": "◇",
    "cross_review": "◇",
    "escalated": "◇",
    "done": "◇",
    "in_progress_design": "◆",
    "in_progress_impl": "◆",
    "in_progress_pbi_review": "◆",
    "in_progress_ut_run": "◆",
    "in_progress_merge": "◆",
}

# Developer-managed status set — used to pick which round counter to
# surface (design_round vs impl_round) for live PBIs.
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
    ("requirements_sprint", "Requirements"),
    ("backlog_created", "Backlog Created"),
    ("sprint_planning", "Sprint Planning"),
    ("design", "Design"),
    ("implementation", "Implementation"),
    ("pbi_pipeline_active", "PBI Pipelines Running"),
    ("review", "Review"),
    ("sprint_review", "Sprint Review"),
    ("retrospective", "Retrospective"),
    ("integration_sprint", "Integration"),
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


def format_status(status: str) -> str:
    """Render a 12-value PBI status with icon + color + short label."""
    icon = STATUS_ICONS.get(status, "")
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
    schema_name = _SCHEMA_FOR_FILE.get(path.name)
    if schema_name is None or not _SCHEMA_VALIDATION:
        result = read_json(path)
        return result if isinstance(result, dict) else None
    try:
        if not path.exists():
            return None
        data = json.loads(path.read_text(encoding="utf-8"))
        schema = json.loads((SCRUM_STATE_DIR / schema_name).read_text(encoding="utf-8"))
        _jsonschema_validate(data, schema)
        return data if isinstance(data, dict) else None
    except ValidationError as exc:
        logger.warning("Schema validation failed for %s: %s", path.name, exc.message)
        return None
    except (json.JSONDecodeError, OSError, UnicodeDecodeError):
        return None


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

        if sprint and isinstance(sprint, dict):
            sprint_id = sprint.get("id", "?")
            goal = sprint.get("goal") or "No goal"
            sprint_status = sprint.get("status", "?")

            pbi_ids = list(sprint.get("pbi_ids") or [])
            pbi_count = len(pbi_ids)

            # Count done PBIs by joining sprint.pbi_ids[] against backlog items.
            done_count = 0
            if backlog and pbi_ids:
                for item in get_backlog_items(backlog):
                    if item.get("id", "") in pbi_ids and item.get("status") == "done":
                        done_count += 1

            devs = sprint.get("developers") or []
            dev_count = sprint.get("developer_count") or len(devs) or 0

            lines.append(
                f"[bold]Sprint:[/bold] {sprint_id}"
                f" | [bold]Status:[/bold] {sprint_status}"
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


class UnifiedPbiBoard(DataTable):
    """Single PBI board driven by the 12-value status SSOT.

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

    def on_mount(self) -> None:
        self.add_columns("ID", "Title", "Status", "Round", "Dev", "Updated")
        self.cursor_type = "row"
        self.update_content()

    def update_content(self) -> None:
        backlog = read_json_validated(SCRUM_DIR / "backlog.json")
        sprint = read_json_validated(SCRUM_DIR / "sprint.json")
        self.clear()

        # PBI → developer (lowercase keys for case-insensitive lookup)
        pbi_impl_map: dict[str, str] = {}
        if sprint and isinstance(sprint, dict):
            for dev in sprint.get("developers") or []:
                did = dev.get("id", "?")
                for pbi_id in (dev.get("assigned_work") or {}).get("implement") or []:
                    pbi_impl_map[pbi_id.lower()] = did

        items = get_backlog_items(backlog)
        now = datetime.now(timezone.utc)

        for item in items:
            pbi_id = item.get("id") or "?"
            pbi_key = pbi_id.lower()
            title = (item.get("title") or "Untitled")[:35]

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

            self.add_row(
                pbi_id,
                title,
                status_display,
                round_cell,
                dev,
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


class CommunicationLog(RichLog):
    """Panel (c): Scrollable agent message log."""

    DEFAULT_CSS = """
    CommunicationLog {
        height: 1fr;
        border: solid $accent;
    }
    """

    def __init__(self, **kwargs) -> None:
        super().__init__(highlight=True, markup=True, wrap=True, **kwargs)
        self._last_count = 0

    def update_content(self) -> None:
        comms = read_json_validated(SCRUM_DIR / "communications.json")
        if not comms:
            return

        messages = comms.get("messages", [])
        new_messages = messages[self._last_count :]
        self._last_count = len(messages)

        for msg in new_messages:
            ts = msg.get("timestamp", "?")
            sender = msg.get("sender_id", "?")
            role = msg.get("sender_role", "")
            recipient = msg.get("recipient_id") or "all"
            content = msg.get("content", "")

            # Format timestamp to HH:MM:SS
            try:
                dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                ts_short = dt.strftime("%H:%M:%S")
            except (ValueError, AttributeError, TypeError):
                ts_short = str(ts)[:8]

            role_str = f" ({role})" if role else ""
            recipient_str = f" → {recipient}" if recipient != "all" else ""
            self.write(
                f"[dim]{ts_short}[/dim] [bold]{sender}[/bold]{role_str}{recipient_str} {content}"
            )


# Round count above this is highlighted as a stagnation hint.
PIPELINE_ROUND_WARN_THRESHOLD = 2


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


class WorkLog(RichLog):
    """Panel (d): Scrollable activity/work log."""

    DEFAULT_CSS = """
    WorkLog {
        height: 1fr;
        border: solid $accent;
    }
    """

    def __init__(self, **kwargs) -> None:
        super().__init__(highlight=True, markup=True, wrap=True, **kwargs)
        self._last_count = 0

    def update_content(self) -> None:
        dashboard = read_json_validated(SCRUM_DIR / "dashboard.json")
        if not dashboard:
            return

        events = dashboard.get("events", [])
        new_events = events[self._last_count :]
        self._last_count = len(events)

        for evt in new_events:
            ts = evt.get("timestamp", "?")
            evt_type = evt.get("type", "?")
            agent = evt.get("agent_id") or "?"
            file_path = evt.get("file_path") or ""
            change = evt.get("change_type") or ""
            detail = evt.get("detail", "")

            try:
                dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                ts_short = dt.strftime("%H:%M:%S")
            except (ValueError, AttributeError, TypeError):
                ts_short = str(ts)[:8]

            if evt_type == "file_changed" and file_path:
                color = {"created": "green", "modified": "yellow", "deleted": "red"}.get(change, "")
                change_str = f"[{color}]{change}[/{color}]" if color else change
                self.write(f"[dim]{ts_short}[/dim] {change_str} {file_path} ({agent})")
            elif evt_type == "teammate_idle":
                self.write(f"[dim]{ts_short}[/dim] [cyan]idle[/cyan] {detail} ({agent})")
            elif evt_type == "status_transition":
                status_from = evt.get("status_from") or ""
                status_to = evt.get("status_to") or ""
                arrow = (
                    f"{status_from} → {status_to}" if status_from or status_to else (detail or "")
                )
                self.write(f"[dim]{ts_short}[/dim] [magenta]status[/magenta] {arrow} ({agent})")
            elif detail:
                self.write(f"[dim]{ts_short}[/dim] {detail} ({agent})")
            else:
                self.write(f"[dim]{ts_short}[/dim] {evt_type} ({agent})")


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

    TITLE = "Scrum Team Dashboard"
    CSS = """
    Screen {
        layout: grid;
        grid-size: 1 3;
        grid-rows: auto 1fr 1fr;
    }
    #logs-row {
        layout: grid;
        grid-size: 2 1;
    }
    #comm-title, #work-title {
        height: 1;
        text-style: bold;
        color: $text;
        padding: 0 1;
    }
    """

    BINDINGS = [
        Binding("q", "quit", "Quit"),
        Binding("r", "refresh", "Refresh"),
        Binding("tab", "focus_next", "Next Panel"),
    ]

    def compose(self) -> ComposeResult:
        yield Header()
        yield SprintOverview(id="overview")
        yield Vertical(
            TestResultsPanel(id="test-results"),
            Static(
                "[bold]PBI Board[/bold] [dim](status • round • dev • agents)[/dim]",
                id="pbi-title",
            ),
            UnifiedPbiBoard(id="pbi-board"),
        )
        with Horizontal(id="logs-row"):
            yield Vertical(
                Static("[bold]Communication Log[/bold]", id="comm-title"),
                CommunicationLog(id="comm-log"),
            )
            yield Vertical(
                Static("[bold]Work Log[/bold]", id="work-title"),
                WorkLog(id="work-log"),
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

        comm_log = self.query_one("#comm-log", CommunicationLog)
        comm_log.update_content()

        work_log = self.query_one("#work-log", WorkLog)
        work_log.update_content()

    def action_refresh(self) -> None:
        self.refresh_panels()

    def on_unmount(self) -> None:
        if hasattr(self, "_observer"):
            self._observer.stop()
            self._observer.join(timeout=2)


if __name__ == "__main__":
    app = ScrumDashboard()
    app.run()
