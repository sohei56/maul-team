//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//

import XCTest
@testable import MaulTeam

/// Pins the argument list handed to `scrum-start.sh`: flag order, the
/// per-seat `--agent-model` spelling, the legacy fallback, and the shell
/// quoting used inside the `-lc` string.
final class ProcessLauncherTests: XCTestCase {
    private let seatOrder = ["scrum-master", "product-owner", "codex-reviewers"]

    private var table: TeamModelConfig {
        TeamModelConfig(choices: [
            "scrum-master": ModelChoice(provider: .claude, model: "opus", effort: "high"),
            "product-owner": ModelChoice(provider: .claude, model: "fable"),
            "codex-reviewers": ModelChoice(provider: .codex, model: nil),
        ])
    }

    func testAgentModelFlagsFollowSeatOrder() {
        let args = ProcessLauncher.scrumStartArguments(
            LaunchOptions(mode: .normal, teamModels: table, flagStyle: .agentModel), seatOrder: seatOrder)
        XCTAssertEqual(args, [
            "--agent-model", "scrum-master=claude:opus@high",
            "--agent-model", "product-owner=claude:fable",
            "--agent-model", "codex-reviewers=codex:default",
        ])
    }

    func testAutonomousComesFirst() {
        let args = ProcessLauncher.scrumStartArguments(
            LaunchOptions(mode: .autonomous, teamModels: table, flagStyle: .agentModel), seatOrder: seatOrder)
        XCTAssertEqual(args.first, "--autonomous")
        XCTAssertEqual(args.count, 7)
    }

    func testSeatsMissingFromTableAreSkippedAndExtrasIgnored() {
        var t = table
        t["unknown-seat"] = ModelChoice(provider: .claude, model: "opus")
        t["product-owner"] = nil
        let args = ProcessLauncher.scrumStartArguments(
            LaunchOptions(teamModels: t, flagStyle: .agentModel), seatOrder: seatOrder)
        XCTAssertEqual(args, [
            "--agent-model", "scrum-master=claude:opus@high",
            "--agent-model", "codex-reviewers=codex:default",
        ])
    }

    func testLegacyStyleNormalMode() {
        let args = ProcessLauncher.scrumStartArguments(
            LaunchOptions(mode: .normal, teamModels: table, flagStyle: .legacy), seatOrder: seatOrder)
        XCTAssertEqual(args, ["--sm-model", "opus"])
    }

    func testLegacyStyleAutonomousAddsPoModel() {
        let args = ProcessLauncher.scrumStartArguments(
            LaunchOptions(mode: .autonomous, teamModels: table, flagStyle: .legacy), seatOrder: seatOrder)
        XCTAssertEqual(args, ["--autonomous", "--sm-model", "opus", "--po-model", "fable"])
    }

    func testLegacyStyleOmitsSeatsWithoutModel() {
        let t = TeamModelConfig(choices: ["scrum-master": ModelChoice(provider: .claude, model: nil)])
        XCTAssertEqual(
            ProcessLauncher.scrumStartArguments(LaunchOptions(mode: .autonomous, teamModels: t, flagStyle: .legacy),
                                                seatOrder: seatOrder),
            ["--autonomous"])
    }

    func testEmptyTableYieldsNoFlagsInNormalMode() {
        XCTAssertEqual(ProcessLauncher.scrumStartArguments(LaunchOptions(), seatOrder: seatOrder), [])
    }

    func testShellQuoteEscapesSingleQuote() {
        XCTAssertEqual(ProcessLauncher.shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(ProcessLauncher.shellQuote("--agent-model"), "'--agent-model'")
    }

    func testScrumMasterCommandEmbedsQuotedFlagsAfterScript() {
        let project = Project(path: "/tmp/my proj", lastOpened: Date())
        let cmd = ProcessLauncher.scrumMaster(
            project: project, frameworkPath: "/fw",
            options: LaunchOptions(mode: .autonomous, teamModels: table, flagStyle: .agentModel),
            seatOrder: seatOrder)
        XCTAssertEqual(cmd.args.first, "-lc")
        let inner = cmd.args[1]
        XCTAssertTrue(inner.hasPrefix("cd '/tmp/my proj' && SCRUM_NO_TMUX=1 sh '/fw/scrum-start.sh' "
            + "'--autonomous' '--agent-model' 'scrum-master=claude:opus@high' "
            + "'--agent-model' 'product-owner=claude:fable' "
            + "'--agent-model' 'codex-reviewers=codex:default'; code=$?;"), inner)
        XCTAssertTrue(inner.contains("read -r _;"))
    }

    func testScrumMasterCommandWithoutFlagsIsUnchanged() {
        let project = Project(path: "/p", lastOpened: Date())
        let cmd = ProcessLauncher.scrumMaster(project: project, frameworkPath: "/fw")
        XCTAssertTrue(cmd.args[1].hasPrefix("cd '/p' && SCRUM_NO_TMUX=1 sh '/fw/scrum-start.sh'; code=$?;"), cmd.args[1])
    }

    func testFlagStyleFollowsCatalogSource() {
        XCTAssertEqual(LaunchOptions.flagStyle(for: .builtin), .legacy)
        var fw = ModelCatalog.builtin
        fw.source = .framework
        XCTAssertEqual(LaunchOptions.flagStyle(for: fw), .agentModel)
    }
}
