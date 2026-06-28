import Foundation

/// How the Scrum team is launched for a project. Chosen in the picker before a
/// fresh session starts; ignored when re-attaching to an already-running
/// background session (the existing process keeps its original mode).
///
/// Both modes shell out to the same `scrum-start.sh`; autonomous adds the
/// `--autonomous` flag, which starts the Ralph-Loop watchdog with an agent
/// Product Owner instead of a human at the keyboard.
enum LaunchMode: String, CaseIterable, Identifiable, Codable {
    /// Human drives the team. The Scrum Master runs interactively in the pane
    /// and the human user fills the Product Owner seat (approvals, requirements,
    /// demo acceptance). This is the default.
    case normal

    /// Autonomous PO mode (`--autonomous`). The watchdog re-launches Claude
    /// iterations end-to-end with an agent Product Owner; no human input is
    /// required. A product brief anchors scope — if none exists, the pane walks
    /// you through co-authoring one before the run starts.
    case autonomous

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal:     return "Normal"
        case .autonomous: return "Autonomous"
        }
    }

    var subtitle: String {
        switch self {
        case .normal:     return "You drive — interactive"
        case .autonomous: return "Hands-off — runs on its own"
        }
    }

    var systemImage: String {
        switch self {
        case .normal:     return "person.fill"
        case .autonomous: return "infinity"
        }
    }

    /// One-paragraph explanation shown in the launch-mode picker.
    var explanation: String {
        switch self {
        case .normal:
            return "You sit in the Product Owner seat. The Scrum Master talks to "
                + "you in the terminal — it elicits requirements, asks for approvals, "
                + "and waits for your decisions at every ceremony. Best for new "
                + "products you want to shape interactively, or when you want full "
                + "control over scope and acceptance."
        case .autonomous:
            return "The team runs end-to-end without you. A watchdog re-launches "
                + "Claude iterations and an agent Product Owner makes the scope and "
                + "acceptance decisions, bounded by safety valves (max sprints / "
                + "hours / failures). It needs a product brief to anchor scope — if "
                + "one doesn't exist yet, the terminal guides you through writing it "
                + "first. Best for letting the team build unattended."
        }
    }
}
