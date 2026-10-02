import AppKit
import CryptoKit
import LoupecastCore

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
            do { try await fetchLatest() } catch { return show("업데이트를 확인하지 못했습니다", error.localizedDescription) }
            guard let tag = available else { return show("최신 버전입니다", "Loupecast \(current)이 최신 버전입니다.") }
            guard isIdle() || !canInstall else { return show("\(tag) 업데이트가 있습니다", "녹화를 멈추고 편집 창을 모두 닫으면 설치됩니다.") }
            installFromMenu()
        }
    }

    /// Called after a check, a recording stops, or an editor closes.
    static func installIfIdle() {
        guard let tag = available, tag != failed, canInstall, isIdle() else { return }
        Task {
            do { try await install() } catch {
                failed = tag
                NSLog("Loupecast: update to %@ failed: %@", tag, "\(error)")
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
        Task {
            do { try await install() } catch { show("업데이트를 설치하지 못했습니다", error.localizedDescription) }
        }
    }

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
            throw UpdateError("다운로드한 파일의 체크섬이 맞지 않습니다.")
        }

        let app = Bundle.main.bundleURL
        // same volume as the app, so the swap below is a rename
        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: app, create: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try run("/usr/bin/ditto", "-x", "-k", zip.path, work.path)
        let fresh = work.appendingPathComponent("Loupecast.app")
        let version = Bundle(url: fresh)?.infoDictionary?["CFBundleShortVersionString"] as? String
        guard let version, "v" + version == tag else {
            throw UpdateError("받은 앱의 버전(\(version ?? "?"))이 \(tag)와 다릅니다.")
        }
        try run("/usr/bin/codesign", "--verify", "--strict", "-R", requirement, fresh.path)
        guard isIdle() else { return }   // a recording may have started during the download

        _ = try FileManager.default.replaceItemAt(app, withItemAt: fresh)
        try? FileManager.default.removeItem(at: work)   // terminate() below skips the defers
        try? FileManager.default.removeItem(at: zip)
        // reopen once this process is gone
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; open \"$0\"", app.path]
        try relaunch.run()
        NSApp.terminate(nil)
    }

    private static func show(_ title: String, _ info: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        NSApp.activate(ignoringOtherApps: true)   // a menu-bar app is not active, so the alert would open behind
        a.runModal()
    }

    private static func run(_ tool: String, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("\(tool) 실패 (\(p.terminationStatus))") }
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
