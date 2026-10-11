import AppKit
import CryptoKit
import LoupecastCore
import SwiftUI

/// Self-update from GitHub releases: checks at launch and daily; when a newer tag exists and the app
/// is idle (no recording, no editor), swaps the running bundle for the release zip and relaunches.
// ponytail: the signing key lives in a GitHub Actions secret, so a compromised GitHub account can still ship an
// update; move to Sparkle (EdDSA key kept offline) if that ever matters.
@MainActor
enum Updater {
    static let repo = "dunzkoi/loupecast"
    /// Only bundles signed by the release identity (release-please.yml imports it) are installed.
    static let requirement = #"=identifier "com.flowoodz.loupecast" and certificate leaf = H"14483067735e80133538834400a7dc458392ad4c""#
    /// Newer release tag ("v0.3.0") found by the last check, until it is installed.
    private(set) static var available: String?
    private static var isIdle: () -> Bool = { false }
    private static var installing = false
    /// Tag whose automatic install failed; retried after the next daily check, not on every editor close.
    private static var failed: String?
    /// This launch is the first after an automatic update (the menu says so; a manual one gets an alert).
    private(set) static var justUpdated = false
    private static let updatedToKey = "updatedTo", updatedManuallyKey = "updatedManually"
    /// The manual path's window; set by the menu, so a click during an automatic install also shows progress.
    private static var progress: UpdateProgress?

    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }

    /// A bundle we can replace: a real .app, not App Translocation's read-only copy, in a writable folder.
    static var canInstall: Bool {
        let app = Bundle.main.bundleURL
        return app.pathExtension == "app" && !app.path.contains("/AppTranslocation/")
            && FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    static func start(isIdle: @escaping () -> Bool) {
        self.isIdle = isIdle
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }   // `swift run` debug binary
        Task { await check() }
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            Task { @MainActor in await check() }
        }
    }

    static func check() async {
        do { try await fetchLatest(); installIfIdle() }
        catch { NSLog("Loupecast: update check failed: %@", "\(error)") }
    }

    /// Sets `available` when the latest release is newer than this build.
    static func fetchLatest() async throws {
        struct Release: Decodable { let tag_name: String }
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        let tag = try JSONDecoder().decode(Release.self, from: data).tag_name
        guard Version.isNewer(tag, than: current) else { return }
        available = tag
        failed = nil
    }

    /// Menu "업데이트 확인…": installs a newer release right away when idle, otherwise says why not.
    static func checkFromMenu() {
        Task {
            do { try await fetchLatest() } catch { return show(String(localized: "Couldn’t check for updates"), error.localizedDescription) }
            guard let tag = available else { return show(String(localized: "You’re up to date"), String(localized: "Loupecast \(current) is the latest version.")) }
            guard isIdle() || !canInstall else { return show(String(localized: "\(tag) is available"), String(localized: "It installs once recording and exports finish and every editor window is closed.")) }
            installFromMenu()
        }
    }

    /// Called after a check, an editor closes, or an export ends.
    static func installIfIdle() {
        guard let tag = available, tag != failed, canInstall, isIdle() else { return }
        Task {
            do { try await install() } catch {
                failed = tag
                NSLog("Loupecast: update to %@ failed: %@", tag, "\(error)")
                if progress != nil {   // a menu click joined this install: don't leave its window hanging
                    closeProgress()
                    show(String(localized: "Couldn’t install the update"), error.localizedDescription)
                }
            }
        }
    }

    /// Manual install from the menu; a non-replaceable bundle gets the release page instead.
    static func installFromMenu() {
        guard let tag = available else { return }
        guard canInstall else {
            NSWorkspace.shared.open(URL(string: "https://github.com/\(repo)/releases/tag/\(tag)")!)
            return
        }
        let window = progress ?? UpdateProgress()
        progress = window
        window.show(String(localized: "Downloading \(tag)…"))
        Task {
            do { try await install() } catch {
                closeProgress()
                show(String(localized: "Couldn’t install the update"), error.localizedDescription)
            }
        }
    }

    /// Silent unless the menu asked (`progress`); a menu click during a running install joins it.
    private static func install() async throws {
        guard let tag = available, !installing else { return }
        installing = true
        defer { installing = false }
        let base = "https://github.com/\(repo)/releases/download/\(tag)/"
        let (zip, _) = try await URLSession.shared.download(from: URL(string: base + "Loupecast.zip")!)
        let (sums, _) = try await URLSession.shared.data(from: URL(string: base + "SHA256SUMS.txt")!)
        defer { try? FileManager.default.removeItem(at: zip) }
        let digest = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        guard String(decoding: sums, as: UTF8.self).split(separator: "\n")
                .contains(where: { $0.hasPrefix(digest) && $0.hasSuffix("Loupecast.zip") }) else {
            throw UpdateError("The downloaded file’s checksum doesn’t match.")
        }

        let app = Bundle.main.bundleURL
        // same volume as the app, so the swap below is a rename
        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: app, create: true)
        defer { try? FileManager.default.removeItem(at: work) }
        // off the main actor, so the progress window keeps drawing
        try await Task.detached { try run("/usr/bin/ditto", "-x", "-k", zip.path, work.path) }.value
        let fresh = work.appendingPathComponent("Loupecast.app")
        let version = Bundle(url: fresh)?.infoDictionary?["CFBundleShortVersionString"] as? String
        guard let version, "v" + version == tag else {
            throw UpdateError("The downloaded app’s version (\(version ?? "?")) isn’t \(tag).")
        }
        let req = requirement
        try await Task.detached { try run("/usr/bin/codesign", "--verify", "--strict", "-R", req, fresh.path) }.value
        guard isIdle() else {   // a recording may have started during the download
            if progress != nil {
                closeProgress()
                show(String(localized: "Update postponed"), String(localized: "It installs once recording and exports finish and every editor window is closed."))
            }
            return
        }

        _ = try FileManager.default.replaceItemAt(app, withItemAt: fresh)
        try? FileManager.default.removeItem(at: work)   // terminate() below skips the defers
        try? FileManager.default.removeItem(at: zip)

        // Start the new copy first, then quit. A helper child that waits for us to exit doesn't survive:
        // macOS can tear down an app's children with it (a manual update quit and never came back).
        progress?.show(String(localized: "Restarting…"))
        let defaults = UserDefaults.standard
        defaults.set(tag, forKey: updatedToKey)   // also tells the new instance it is a relaunch
        defaults.set(progress != nil, forKey: updatedManuallyKey)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        cfg.activates = false
        do { _ = try await NSWorkspace.shared.openApplication(at: app, configuration: cfg) } catch {
            defaults.removeObject(forKey: updatedToKey)
            defaults.removeObject(forKey: updatedManuallyKey)
            throw UpdateError("The new version is installed but couldn’t be opened. Open Loupecast again yourself. (\(error.localizedDescription))")
        }
        quit()
    }

    /// Quits from a run-loop block, not from this task. A quit that has to wait (a recording started meanwhile)
    /// spins a nested run loop, and that loop doesn't run the main queue while a main-queue job is on the stack.
    static func quit() {
        RunLoop.main.perform { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    }

    /// At launch. After a self-update the old instance is still quitting and still holds the hot key, so `then`
    /// runs once it is gone (≤ 5 s). Polls instead of blocking: the old instance may be waiting for this launch.
    static func finishRelaunch(then: @escaping @MainActor () -> Void) {
        let defaults = UserDefaults.standard
        guard let tag = defaults.string(forKey: updatedToKey) else { return then() }
        defaults.removeObject(forKey: updatedToKey)
        let deadline = Date().addingTimeInterval(5)
        Task {
            while Date() < deadline, NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                    .contains(where: { $0.processIdentifier != getpid() }) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            then()
        }
        guard "v" + current == tag else { return }   // the relaunch failed and this is an older copy
        if defaults.bool(forKey: updatedManuallyKey) {
            DispatchQueue.main.async { show(String(localized: "Updated to \(tag)"), String(localized: "Loupecast restarted with the new version."), link: tag) }
        } else {
            justUpdated = true
        }
    }

    /// `link`: a release tag; adds a button that opens its release notes.
    private static func show(_ title: String, _ info: String, link: String? = nil) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        if let link { a.addButton(withTitle: String(localized: "OK")); a.addButton(withTitle: String(localized: "View Changes")) }
        NSApp.activate(ignoringOtherApps: true)   // a menu-bar app is not active, so the alert would open behind
        if a.runModal() == .alertSecondButtonReturn, let link {
            NSWorkspace.shared.open(URL(string: "https://github.com/\(repo)/releases/tag/\(link)")!)
        }
    }

    private static func closeProgress() {
        progress?.close()
        progress = nil
    }

    nonisolated private static func run(_ tool: String, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("\(tool) failed (\(String(p.terminationStatus)))") }
    }
}

/// The manual update's progress window: the app visibly downloads, installs and restarts instead of vanishing.
@MainActor @Observable
final class UpdateProgress {
    var text = ""
    private var window: NSWindow?

    func show(_ text: String) {
        self.text = text
        guard window == nil else { return }
        let w = LoupecastWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        w.title = String(localized: "Loupecast Update")
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: UpdateProgressView(model: self))
        w.center()
        window = w
        w.bringToFront()
    }

    func close() {
        window?.close()
        window = nil
    }
}

struct UpdateProgressView: View {
    let model: UpdateProgress
    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(model.text)
        }
        .padding(20)
        .frame(width: 320, alignment: .leading)
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String.LocalizationValue) { errorDescription = String(localized: message) }
}
