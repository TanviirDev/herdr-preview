// Herdr Preview Web: a real WebKit view glued over the Herdr app's Preview panel.
// Part of herdr-preview. Built and installed by install.sh.
//
// Herdr can't host a web view, so this app floats a borderless window exactly over the
// Preview panel's body and follows Herdr: it moves and resizes with the window and the panel,
// and hides whenever the panel is hidden, not in web mode, or Herdr isn't the frontmost app.
// The window is a non-activating panel, so clicking and typing in it keep Herdr frontmost.
//
// Inputs (all files):
//   ~/.local/state/herdr-preview/target          line 1, what to show: a URL or an .html path
//                                                (the herdr-preview command writes it); line 2
//                                                is a label for the mod
//   ~/.config/herdr-app/herdr-preview/panel.json where the panel is, written by the preview mod
//                                                ({visible, right, top, width, height, zoom}; a
//                                                heartbeat: older than 3 s means hide)
//   ~/.config/herdr-app/herdr-preview/reload     any write reloads the page
//   ~/.config/herdr-app/herdr-preview/snapshot   a PNG path: save what the view shows there,
//                                                then delete this file (herdr-preview --snapshot)
// Output: ~/.config/herdr-app/herdr-preview/helper.json (the last frame, for debugging).
// It quits when the Herdr app does.

import AppKit
import WebKit

let home = FileManager.default.homeDirectoryForCurrentUser.path
let herdrBundleID = "dev.herdr.app"
let stateDir = home + "/.config/herdr-app/herdr-preview"
let panelPath = stateDir + "/panel.json"
let reloadPath = stateDir + "/reload"
let debugPath = stateDir + "/helper.json"
let snapshotPath = stateDir + "/snapshot"
let currentPath = home + "/.local/state/herdr-preview/target"

struct Geometry: Decodable {
    var visible: Bool
    var right: Double
    var top: Double
    var width: Double
    var height: Double
    var zoom: Double?
}

func modified(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}

/// Lets the panel take the keyboard without activating this app, and gives the page the
/// usual editing shortcuts, which normally come from a menu bar this app doesn't have.
final class WebPanel: NSPanel {
    weak var web: WKWebView?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() {
            let shift = flags.contains(.shift)
            let action: Selector? = switch key {
            case "c": #selector(NSText.copy(_:))
            case "v": #selector(NSText.paste(_:))
            case "x": #selector(NSText.cut(_:))
            case "a": #selector(NSResponder.selectAll(_:))
            case "z": shift ? Selector(("redo:")) : Selector(("undo:"))
            default: nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
            if key == "r" { web?.reload(); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class Controller: NSObject, WKNavigationDelegate, WKUIDelegate {
    let panel: WebPanel
    let web: WKWebView
    var geometry: Geometry?
    var geometryStamp: Date?
    var currentStamp: Date?
    var reloadStamp: Date?
    var loaded: String?
    var herdrPID: pid_t?
    var windowID: CGWindowID?
    var lastFrame = NSRect.zero
    var shown = false
    var ticks = 0

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        web = WKWebView(frame: .zero, configuration: config)
        web.isInspectable = true
        panel = WebPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        panel.web = web
        panel.contentView = web
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    func start() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Inputs

    func readInputs() {
        if let stamp = modified(panelPath), stamp != geometryStamp {
            geometryStamp = stamp
            if let data = FileManager.default.contents(atPath: panelPath) {
                geometry = try? JSONDecoder().decode(Geometry.self, from: data)
            }
        }
        if let stamp = modified(currentPath), stamp != currentStamp {
            currentStamp = stamp
            // Line 1 is what to show; line 2, when present, is a label for the mod's header.
            let text = (try? String(contentsOfFile: currentPath, encoding: .utf8)) ?? ""
            let first = text.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
            load(first.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let stamp = modified(reloadPath), stamp != reloadStamp {
            if reloadStamp != nil, loaded != nil { web.reload() }
            reloadStamp = stamp
        }
        if FileManager.default.fileExists(atPath: snapshotPath) { snapshot() }
    }

    /// Saves what the view shows to the PNG path named in the snapshot request file.
    /// Only a shown view is painted in full, so a hidden one answers with an error file.
    func snapshot() {
        let out = ((try? String(contentsOfFile: snapshotPath, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try? FileManager.default.removeItem(atPath: snapshotPath)
        guard !out.isEmpty else { return }
        guard shown else {
            try? "the web view isn't showing".write(toFile: out + ".error", atomically: true, encoding: .utf8)
            return
        }
        web.takeSnapshot(with: nil) { image, error in
            guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                try? (error?.localizedDescription ?? "no image").write(toFile: out + ".error", atomically: true, encoding: .utf8)
                return
            }
            try? png.write(to: URL(fileURLWithPath: out), options: .atomic)
        }
    }

    func load(_ target: String) {
        guard !target.isEmpty else { loaded = nil; return }
        if target == loaded { return }
        let lower = target.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: target) else { return }
            web.load(URLRequest(url: url))
        } else if lower.hasPrefix("file://") || lower.hasSuffix(".html") || lower.hasSuffix(".htm") || lower.hasSuffix(".xhtml") {
            let url = lower.hasPrefix("file://") ? URL(string: target) : URL(fileURLWithPath: target)
            guard let url else { return }
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            loaded = nil // Markdown: the mod draws it natively.
            return
        }
        loaded = target
    }

    // MARK: - Herdr's window

    func herdrWindow() -> CGRect? {
        guard let pid = herdrPID else { return nil }
        func bounds(_ info: [String: Any]) -> CGRect? {
            guard let dict = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: dict as CFDictionary)
        }
        if let id = windowID,
           let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
           let info = list.first, (info[kCGWindowIsOnscreen as String] as? Bool) == true,
           let rect = bounds(info) {
            return rect
        }
        windowID = nil
        guard let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        var best: (CGWindowID, CGRect)?
        for info in all {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let rect = bounds(info), rect.width > 200, rect.height > 200 else { continue }
            if best == nil || rect.width * rect.height > best!.1.width * best!.1.height { best = (id, rect) }
        }
        windowID = best?.0
        return best?.1
    }

    // MARK: - Loop

    func hide() {
        if shown { panel.orderOut(nil); shown = false }
    }

    func tick() {
        ticks += 1
        // Hidden: check ten times a second. Shown: every frame, to keep up with window drags.
        if !shown && ticks % 6 != 0 { return }
        if ticks % 60 == 0 || herdrPID == nil {
            guard let herdr = NSRunningApplication.runningApplications(withBundleIdentifier: herdrBundleID).first else {
                NSApp.terminate(nil)
                return
            }
            herdrPID = herdr.processIdentifier
        }
        readInputs()
        let fresh = geometryStamp.map { Date().timeIntervalSince($0) < 3 } ?? false
        // This app being frontmost counts as Herdr in use: it only ever comes forward from Herdr
        // (a click in its panel, or a stray `open`), so hiding then would yank the page away.
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let front = frontPID == herdrPID || frontPID == ProcessInfo.processInfo.processIdentifier
        guard let g = geometry, g.visible, fresh, front, loaded != nil,
              g.width > 20, g.height > 20, let win = herdrWindow() else {
            hide()
            return
        }
        let zoom = (g.zoom ?? 1) > 0 ? (g.zoom ?? 1) : 1
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let width = g.width * zoom, height = g.height * zoom
        let x = win.maxX - g.right * zoom - width
        let top = win.minY + g.top * zoom
        let frame = NSRect(x: x, y: primaryHeight - top - height, width: width, height: height)
        if frame != lastFrame {
            panel.setFrame(frame, display: true)
            lastFrame = frame
            let debug = "{\"window\":[\(win.minX),\(win.minY),\(win.width),\(win.height)],\"frame_cg\":[\(x),\(top),\(width),\(height)]}"
            try? debug.write(toFile: debugPath, atomically: true, encoding: .utf8)
        }
        if !shown { panel.orderFrontRegardless(); shown = true }
    }

    // MARK: - WebKit

    // Links that ask for a new window open in the default browser rather than replacing the page.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
controller.start()
app.run()
