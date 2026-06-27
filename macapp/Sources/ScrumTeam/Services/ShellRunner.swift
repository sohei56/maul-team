import Foundation

/// Runs a non-interactive Command to completion and captures its output.
/// Used for one-shot steps (project setup) where no terminal pane is needed.
enum ShellRunner {
    struct Result {
        let exitCode: Int32
        let output: String   // merged stdout+stderr
    }

    static func run(_ command: ProcessLauncher.Command) async -> Result {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.args

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            // Read to end after exit. Safe here because setup-user.sh emits only
            // a few lines — far below the pipe buffer limit that would deadlock.
            process.terminationHandler = { proc in
                let out = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                let output = String(data: out, encoding: .utf8) ?? ""
                continuation.resume(returning: Result(exitCode: proc.terminationStatus, output: output))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: Result(exitCode: -1, output: "Failed to launch: \(error.localizedDescription)"))
            }
        }
    }
}
