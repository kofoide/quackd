// Quackd menu bar app: shows the quack server's state and controls it.
//
// The app bundles a copy of the `quackd` script (Contents/Resources/quackd) and
// installs it to ~/Library/Application Support/quackd/quackd, a stable path that the
// launchd service can point at even if the app is moved. Every action shells out to
// that script, so the menu and the CLI always behave identically. State comes from
// `quackd status --porcelain`, polled every few seconds.
//
// The script asks the app to post notifications by opening quackd://notify?title=…&message=…
//
// https://github.com/kofoide/quackd — MIT License

import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Status model

struct ServiceStatus: Equatable {
    var version = ""
    var installed = false
    var loaded = false
    var state = ""          // launchd's state, e.g. "running", "not running", "spawn scheduled"
    var pid = ""
    var failures = 0
    var maxFailures = 5
    var listening = false
    var host = "localhost"
    var port = "9494"
    var log = ""
    var config = ""
    var configured = false
    var configError = ""
    var duckdb = ""
    var serviceScript = ""  // script path recorded in the installed launchd plist
    var error: String?      // set when the status command itself failed

    enum Phase {
        case unknown, noDuckDB, notConfigured, notInstalled
        case stopped, starting, running, retrying, gaveUp
    }

    var phase: Phase {
        if error != nil { return .unknown }
        if loaded && state == "running" { return listening ? .running : .starting }
        if duckdb.isEmpty { return .noDuckDB }
        if !configured { return .notConfigured }
        if !installed { return .notInstalled }
        if maxFailures > 0 && failures >= maxFailures { return .gaveUp }
        if loaded && state == "spawn scheduled" { return .retrying }
        return .stopped
    }

    /// Parse `quackd status --porcelain` (key=value per line).
    static func parse(_ text: String) -> ServiceStatus {
        var s = ServiceStatus()
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]), value = String(line[line.index(after: eq)...])
            switch key {
            case "version": s.version = value
            case "installed": s.installed = value == "yes"
            case "loaded": s.loaded = value == "yes"
            case "state": s.state = value
            case "pid": s.pid = value
            case "failures": s.failures = Int(value) ?? 0
            case "max_failures": s.maxFailures = Int(value) ?? 5
            case "listening": s.listening = value == "yes"
            case "host": s.host = value
            case "port": s.port = value
            case "log": s.log = value
            case "config": s.config = value
            case "configured": s.configured = value == "yes"
            case "config_error": s.configError = value
            case "duckdb": s.duckdb = value
            case "service_script": s.serviceScript = value
            default: break
            }
        }
        return s
    }
}

// MARK: - Running the quackd script

struct CommandResult {
    let code: Int32
    let output: String
}

enum Shell {
    /// Stable location of the script the app (and the launchd service) uses.
    static let scriptPath: String = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("quackd/quackd").path
    }()

    /// Copy the bundled script to `scriptPath` if it's missing or different, so the
    /// stable copy always matches this app's version. Returns an error message on failure.
    static func installBundledScript() -> String? {
        guard let bundled = Bundle.main.path(forResource: "quackd", ofType: nil) else {
            return "The app bundle is missing its quackd script. Rebuild it with: make app"
        }
        let fm = FileManager.default
        if fm.contentsEqual(atPath: bundled, andPath: scriptPath) { return nil }
        do {
            try fm.createDirectory(atPath: (scriptPath as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: scriptPath) { try fm.removeItem(atPath: scriptPath) }
            try fm.copyItem(atPath: bundled, toPath: scriptPath)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            return nil
        } catch {
            return "Could not install the quackd script to \(scriptPath): \(error.localizedDescription)"
        }
    }

    /// Run `/bin/bash quackd <args>` off the main thread; returns exit code and combined output.
    static func quackd(_ args: [String]) async -> CommandResult {
        await run("/bin/bash", [scriptPath] + args)
    }

    static func run(_ executable: String, _ args: [String]) async -> CommandResult {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            // Apps launched from Finder get a minimal PATH; add Homebrew for duckdb.
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return CommandResult(code: -1, output: "Could not run \(executable): \(error.localizedDescription)")
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(code: process.terminationStatus,
                                 output: String(decoding: data, as: UTF8.self))
        }.value
    }
}

// MARK: - Notifications and URL handling

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Log path for "click notification → open log"; kept current by the Controller.
    static var logPath = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// quackd://notify?title=…&message=… (sent by the script's notify()).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "quackd" && url.host == "notify" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in items.first { $0.name == name }?.value ?? "" }
            let content = UNMutableNotificationContent()
            content.title = "quackd"
            content.subtitle = value("title")
            content.body = value("message")
            content.sound = UNNotificationSound(named: UNNotificationSoundName("Basso"))
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // Show banners even while the app is "active".
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Clicking a notification opens the log in Console.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if !Self.logPath.isEmpty {
            NSWorkspace.shared.open([URL(fileURLWithPath: Self.logPath)],
                                    withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        }
        completionHandler()
    }
}

// MARK: - Controller

@MainActor
final class Controller: ObservableObject {
    @Published var status = ServiceStatus()
    @Published var busy: String?            // name of the action in progress, if any
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var setupError: String?

    let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    private var timer: Timer?
    private var repairedService = false

    init() {
        setupError = Shell.installBundledScript()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        Task {
            if let setupError {
                var s = ServiceStatus()
                s.error = setupError
                status = s
                return
            }
            let result = await Shell.quackd(["status", "--porcelain"])
            var s = ServiceStatus.parse(result.output)
            if result.code != 0 { s.error = result.output.trimmingCharacters(in: .whitespacesAndNewlines) }
            status = s
            AppDelegate.logPath = s.log
            openAtLogin = SMAppService.mainApp.status == .enabled
            await repairServiceIfNeeded(s)
        }
    }

    /// If the installed service points at a script that no longer exists (e.g. an old
    /// checkout was moved or deleted), re-run `install` so it uses the app's copy.
    private func repairServiceIfNeeded(_ s: ServiceStatus) async {
        guard !repairedService, s.installed, s.configured, !s.serviceScript.isEmpty,
              !FileManager.default.fileExists(atPath: s.serviceScript) else { return }
        repairedService = true
        _ = await Shell.quackd(["install"])
    }

    /// Run a quackd subcommand (start/stop/restart/install), then refresh a few times
    /// so the icon catches the server coming up.
    func perform(_ args: [String]) {
        busy = args[0]
        Task {
            let result = await Shell.quackd(args)
            busy = nil
            if result.code != 0 {
                showAlert("quackd \(args[0]) failed", result.output)
            }
            for delay in [0.0, 1.0, 3.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                refresh()
            }
        }
    }

    /// First-run setup: pick a database, then `quackd init <db>` and `quackd install`.
    func setUp() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose the DuckDB database to serve"
        panel.prompt = "Serve This Database"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let duckdbType = UTType(filenameExtension: "duckdb") {
            panel.allowedContentTypes = [duckdbType, .data]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = "setup"
        Task {
            let initResult = await Shell.quackd(["init", url.path])
            if initResult.code != 0 {
                busy = nil
                showAlert("quackd init failed", initResult.output)
                return
            }
            let installResult = await Shell.quackd(["install"])
            busy = nil
            if installResult.code != 0 {
                showAlert("quackd install failed", installResult.output)
            }
            refresh()
        }
    }

    func copyConnectCommand() {
        Task {
            let result = await Shell.quackd(["connect"])
            if result.code == 0 {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.output.trimmingCharacters(in: .whitespacesAndNewlines),
                                               forType: .string)
            } else {
                showAlert("Could not build the connect command", result.output)
            }
        }
    }

    func openLog() {
        guard !status.log.isEmpty else { return }
        // Create it if missing so Console has something to open.
        if !FileManager.default.fileExists(atPath: status.log) {
            try? FileManager.default.createDirectory(
                atPath: (status.log as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: status.log, contents: nil)
        }
        Task { _ = await Shell.run("/usr/bin/open", ["-a", "Console", status.log]) }
    }

    func openConfig() {
        guard !status.config.isEmpty else { return }
        Task { _ = await Shell.run("/usr/bin/open", ["-t", status.config]) }
    }

    func openDuckDBInstallPage() {
        NSWorkspace.shared.open(URL(string: "https://duckdb.org/docs/installation/?environment=cli&platform=macos")!)
    }

    func openProjectPage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/kofoide/quackd")!)
    }

    func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            showAlert("Could not change Open at Login", error.localizedDescription)
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func showAlert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message.isEmpty ? "No output." : message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: Presentation

    var iconName: String {
        if busy != nil { return "arrow.triangle.2.circlepath" }
        switch status.phase {
        case .running: return "bird.fill"
        case .starting, .retrying: return "arrow.triangle.2.circlepath"
        case .gaveUp, .unknown, .noDuckDB: return "exclamationmark.triangle.fill"
        case .stopped, .notInstalled, .notConfigured: return "bird"
        }
    }

    var statusLine: String {
        if let busy { return "Running quackd \(busy)…" }
        let s = status
        switch s.phase {
        case .running: return "Running on \(s.host):\(s.port)"
        case .starting: return "Starting…"
        case .retrying: return "Failed \(s.failures) of \(s.maxFailures) — retrying"
        case .gaveUp: return "Gave up after \(s.failures) failures — check the log"
        case .stopped: return "Stopped"
        case .notInstalled: return "Not installed"
        case .notConfigured: return "Not set up yet"
        case .noDuckDB: return "DuckDB is not installed"
        case .unknown: return "Status unavailable"
        }
    }

    /// Extra explanation shown under the status line, if any.
    var detailLine: String? {
        switch status.phase {
        case .unknown: return status.error
        case .noDuckDB: return "Install it with: brew install duckdb"
        case .notConfigured:
            // A missing config just needs setup; any other config problem is worth showing.
            return status.configError.hasPrefix("no config at") ? nil : status.configError
        default: return nil
        }
    }
}

// MARK: - Menu

struct MenuContent: View {
    @ObservedObject var controller: Controller

    var body: some View {
        let phase = controller.status.phase
        let idle = controller.busy == nil

        Text("Quack server: \(controller.statusLine)")
        if let detail = controller.detailLine {
            Text(detail).lineLimit(3)
        }
        Divider()

        switch phase {
        case .noDuckDB:
            Button("How to Install DuckDB…") { controller.openDuckDBInstallPage() }
        case .notConfigured:
            Button("Set Up…") { controller.setUp() }.disabled(!idle)
        case .notInstalled:
            Button("Install Service") { controller.perform(["install"]) }.disabled(!idle)
        default:
            Button("Start") { controller.perform(["start"]) }
                .disabled(!idle || phase == .running || phase == .starting || phase == .unknown)
            Button("Stop") { controller.perform(["stop"]) }
                .disabled(!idle || phase == .stopped || phase == .gaveUp || phase == .unknown)
            Button("Restart") { controller.perform(["restart"]) }
                .disabled(!idle || phase == .unknown)
        }
        Divider()

        let configured = controller.status.configured
        Button("Copy DuckDB Connect Command") { controller.copyConnectCommand() }
            .disabled(!configured)
        Button("Open Log") { controller.openLog() }
            .disabled(controller.status.log.isEmpty)
        Button("Edit Config") { controller.openConfig() }
            .disabled(!configured)
        Divider()

        Toggle("Open Menu at Login", isOn: Binding(
            get: { controller.openAtLogin },
            set: { controller.setOpenAtLogin($0) }))
        Button("Quackd \(controller.appVersion) on GitHub…") { controller.openProjectPage() }
        Button("Quit Quackd Menu") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@main
struct QuackdMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = Controller()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            Image(systemName: controller.iconName)
        }
        .menuBarExtraStyle(.menu)
    }
}
