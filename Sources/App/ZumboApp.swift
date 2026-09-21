import AppKit
import SwiftUI

/// Zumbo is an LSUIElement app: no dock icon, no main window. The whole UI is
/// the menu bar item and the notch panel, both owned by the delegate.
@main
struct ZumboApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        Self.migrateApplicationSupportFolderIfNeeded()

        // AppKit's default for apps linked against a modern SDK is to abort on
        // any uncaught Objective-C exception reaching the run loop. A layout
        // exception inside the notch panel took the whole app down three
        // times on 2026-09-18 (see docs/ARCHITECTURE.md). With this off,
        // AppKit logs the exception and keeps running; the handler below
        // writes the reason to a file so the cause can be read afterwards.
        UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": false])
        NSSetUncaughtExceptionHandler { exception in
            let line = "\(Date()) \(exception.name.rawValue): \(exception.reason ?? "")\n\(exception.callStackSymbols.prefix(12).joined(separator: "\n"))\n\n"
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Zumbo", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("exceptions.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// One-time rename: the app was called Vesper until 2026-09-20 and
    /// stored history.json, AddOns and exceptions.log under
    /// `Application Support/Vesper`. If that folder is still there and the
    /// new `Zumbo` one is not, move it wholesale so nothing is lost.
    private static func migrateApplicationSupportFolderIfNeeded() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldDir = base.appendingPathComponent("Vesper", isDirectory: true)
        let newDir = base.appendingPathComponent("Zumbo", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: oldDir.path), !fm.fileExists(atPath: newDir.path) else { return }
        try? fm.moveItem(at: oldDir, to: newDir)
    }

    var body: some Scene {
        // A Settings scene keeps SwiftUI happy without opening a window at
        // launch. The real settings surface is not built yet.
        Settings {
            EmptyView()
        }
    }
}
