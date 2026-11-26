import PacerCore
import Foundation

struct EngineGLMHookSetup: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case disabled, settingUp, ready, needsSetup, missingHome, failed }
    let state: State
    var hooksConfigured = false
    var updateAvailable = false
    init(_ state: State) { self.state = state }
}

/// The GLM hook helper follows the Claude one: the shared installer helper
/// does the work synchronously with its own deadline, and the engine only
/// schedules ensure/remove passes while the module state asks for them.
struct EngineGLMHookServices: Sendable {
    enum Action: Sendable { case ensure, remove }
    var perform: @Sendable (Action, URL) async -> EngineGLMHookSetup
    static func live(root: URL) -> Self {
        let helper = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("PacerInstallerHooks.exe")
        return Self { action, home in
            let operation = action == .ensure ? "--ensure-glm" : "--uninstall-glm-home"
            guard let data = await WindowsSubprocess.capture(executable: helper, arguments: [operation, home.path, root.path], timeout: 5, limit: 4096) else { return .init(.failed) }
            if action == .remove { return .init(.disabled) }
            return (try? JSONDecoder().decode(EngineGLMHookSetup.self, from: data)) ?? .init(.failed)
        }
    }
}
