// Herdr Preview Links: makes Cmd-clicked .md links in the Herdr app open in its Preview panel.
// Part of herdr-preview. Built and installed by install.sh.
//
// It becomes the Mac's default app for Markdown files. A file opened while the Herdr app is
// frontmost (a Cmd-click on a link in a Herdr terminal) goes to the Preview panel through the
// `herdr-preview` command. A file opened from anywhere else (Finder, another app) goes to the
// app that opened Markdown before, which --install records. HTML is never taken over.
//
//   HerdrPreviewLinks --install [--cli <path>]   record the current .md app, then take .md over
//   HerdrPreviewLinks --uninstall                give .md back to the recorded app
//
// Settings: ~/.config/herdr-preview/settings.json  {"cli": ..., "md_fallback": <bundle id>}
// Log:      ~/Library/Logs/HerdrPreviewLinks.log (one line per opened file)

import AppKit
import UniformTypeIdentifiers

let herdrBundleID = "dev.herdr.app"
let selfBundleID = Bundle.main.bundleIdentifier ?? "io.github.tanviirdev.herdr-preview.links"
let lastResort = "com.apple.TextEdit"
let markdownType = "net.daringfireball.markdown"
let home = FileManager.default.homeDirectoryForCurrentUser.path
let settingsDir = home + "/.config/herdr-preview"
let settingsPath = settingsDir + "/settings.json"
let logPath = home + "/Library/Logs/HerdrPreviewLinks.log"

struct Settings: Codable {
    var cli: String?
    var md_fallback: String?
}

func loadSettings() -> Settings {
    guard let data = FileManager.default.contents(atPath: settingsPath),
          let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
    return settings
}

func saveSettings(_ settings: Settings) throws {
    try FileManager.default.createDirectory(atPath: settingsDir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(settings).write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
}

func log(_ line: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let data = Data("\(stamp) \(line)\n".utf8)
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: data)
    }
}

/// The bundle ID of the app that opens Markdown right now, if any.
func currentMarkdownApp() -> String? {
    guard let type = UTType(markdownType),
          let app = NSWorkspace.shared.urlForApplication(toOpen: type) else { return nil }
    return Bundle(url: app)?.bundleIdentifier
}

func fallbackApp() -> URL? {
    let settings = loadSettings()
    for id in [settings.md_fallback, lastResort].compactMap({ $0 }) where id != selfBundleID {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
    }
    return nil
}

// MARK: - Install and uninstall

/// Sets the default Markdown app, then checks it took: on recent macOS some calls report
/// success without saving anything, so only the re-read result counts.
func setMarkdownDefault(_ bundleID: String) -> Bool {
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
          let type = UTType(markdownType) else {
        print("cannot find \(bundleID)")
        return false
    }
    var finished = false
    var failure: Error?
    NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
        DispatchQueue.main.async { failure = error; finished = true }
    }
    let deadline = Date().addingTimeInterval(120) // macOS may ask the person to confirm
    while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    if let failure { print("macOS refused: \(failure.localizedDescription)") }
    let now = currentMarkdownApp()
    if now != bundleID { print("Markdown still opens with \(now ?? "nothing")") }
    return now == bundleID
}

func install(cli: String?) -> Int32 {
    var settings = loadSettings()
    if let cli { settings.cli = cli }
    let before = currentMarkdownApp()
    // Re-installing keeps the original fallback rather than recording ourselves.
    if let before, before != selfBundleID { settings.md_fallback = before }
    if settings.md_fallback == nil { settings.md_fallback = lastResort }
    do { try saveSettings(settings) } catch {
        print("cannot write \(settingsPath): \(error.localizedDescription)")
        return 1
    }
    print("Markdown opened with \(before ?? "nothing"); files opened outside Herdr will go to \(settings.md_fallback!)")
    return setMarkdownDefault(selfBundleID) ? 0 : 1
}

func uninstall() -> Int32 {
    let target = loadSettings().md_fallback ?? lastResort
    if currentMarkdownApp() != selfBundleID {
        print("Markdown doesn't open with Herdr Preview Links; leaving it alone")
        return 0
    }
    if setMarkdownDefault(target) { print("Markdown opens with \(target) again"); return 0 }
    if target != lastResort, setMarkdownDefault(lastResort) { print("Markdown opens with \(lastResort)"); return 0 }
    return 1
}

// MARK: - Opening files

/// Runs `herdr-preview <file>`, which shows the file in the Herdr app's Preview panel.
func preview(_ url: URL) -> Bool {
    let cli = loadSettings().cli ?? home + "/.local/bin/herdr-preview"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: cli)
    process.arguments = [url.path]
    var env = ProcessInfo.processInfo.environment
    // A GUI app gets a bare PATH; herdr-preview needs herdr-app from ~/.local/bin.
    env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    process.environment = env
    let errors = Pipe()
    process.standardError = errors
    process.standardOutput = Pipe()
    do { try process.run() } catch {
        log("cannot run \(cli): \(error.localizedDescription)")
        return false
    }
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        log("\(cli) exited \(process.terminationStatus): \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        return false
    }
    return true
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var quit: DispatchWorkItem?

    // Stay only as long as there is work: quit a moment after the last open.
    private func scheduleQuit() {
        quit?.cancel()
        let item = DispatchWorkItem { NSApp.terminate(nil) }
        quit = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    func applicationDidFinishLaunching(_ notification: Notification) { scheduleQuit() }

    func application(_ application: NSApplication, open urls: [URL]) {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        var passOn: [URL] = []
        for url in urls {
            if front == herdrBundleID, url.isFileURL, preview(url) {
                log("panel front=\(front) \(url.path)")
            } else {
                passOn.append(url)
            }
        }
        if !passOn.isEmpty {
            if let app = fallbackApp() {
                for file in passOn { log("pass  front=\(front) \(file.path) -> \(app.lastPathComponent)") }
                NSWorkspace.shared.open(passOn, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error { log("open failed: \(error.localizedDescription)") }
                }
            } else {
                log("no app to pass \(passOn.count) file(s) to")
            }
        }
        scheduleQuit()
    }
}

let args = CommandLine.arguments
if args.contains("--install") {
    let cli = args.firstIndex(of: "--cli").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    exit(install(cli: cli))
}
if args.contains("--uninstall") { exit(uninstall()) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
