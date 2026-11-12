import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI

// In-app updates without third-party code.
//
// Checking: once a day (first ~1 min after launch) one anonymous GET of the latest GitHub release.
// Nothing about the Mac or the user is sent – only the request itself, with a generic user agent.
// Installing: the DMG and its Ed25519 signature are downloaded, the signature is checked against the
// public key below, the app is copied out of the mounted image (nothing on it is ever run), its bundle
// id, version and code signature are checked, and only then the running bundle is replaced.

/// A published release, as read from the GitHub API (or the test feed).
struct UpdateRelease: Equatable, Sendable {
    let version: String
    let notes: String
    let page: URL
    let dmg: URL?
    let signature: URL?
}

enum UpdateFeed {
    static let github = URL(string: "https://api.github.com/repos/filiphajduch420/iSnow/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/filiphajduch420/iSnow/releases")!
    /// Ed25519 public key of the release signing key (scripts/sign-update.swift pubkey).
    static let publicKey = "HErKE9PAIz0B5ylLFeoEnyKXtym9WC0rcnlVV04Ydug="

    /// Test override: ISNOW_UPDATE_FEED=<file:// or http://localhost URL of a JSON shaped like the GitHub API>.
    static let override: URL? = {
        guard let s = ProcessInfo.processInfo.environment["ISNOW_UPDATE_FEED"], !s.isEmpty else { return nil }
        guard let u = URL(string: s), u.isFileURL || isLocal(u) else {
            NSLog("iSnow: ISNOW_UPDATE_FEED must be a file:// or http://localhost URL – ignored")
            return nil
        }
        return u
    }()

    static var url: URL { override ?? github }

    static func isLocal(_ u: URL) -> Bool {
        guard u.scheme == "http" || u.scheme == "https", let h = u.host else { return false }
        return h == "localhost" || h == "127.0.0.1" || h == "::1"
    }

    /// Downloads come from GitHub over HTTPS (the test feed: from this Mac only).
    static func isAllowedAsset(_ u: URL) -> Bool {
        if override != nil { return u.isFileURL || isLocal(u) }
        return u.scheme == "https" && u.host == "github.com"
    }

    private static func isAllowedPage(_ u: URL) -> Bool {
        if override != nil, u.isFileURL || isLocal(u) { return true }
        return u.scheme == "https" && u.host == "github.com"
    }

    /// The release in a GitHub API response; nil for drafts, prereleases and odd version tags.
    static func parse(_ data: Data) -> UpdateRelease? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              var tag = json["tag_name"] as? String else { return nil }
        if tag.hasPrefix("v") || tag.hasPrefix("V") { tag.removeFirst() }
        guard Version.parts(tag) != nil else { return nil }
        var page = releasesPage
        if let s = json["html_url"] as? String, let u = URL(string: s), isAllowedPage(u) { page = u }
        var dmg: URL?, sig: URL?
        for asset in json["assets"] as? [[String: Any]] ?? [] {
            guard let name = asset["name"] as? String, let s = asset["browser_download_url"] as? String,
                  let u = URL(string: s), isAllowedAsset(u) else { continue }
            if name == "iSnow-v\(tag).dmg" { dmg = u }
            if name == "iSnow-v\(tag).dmg.sig" { sig = u }
        }
        return UpdateRelease(version: tag, notes: json["body"] as? String ?? "", page: page, dmg: dmg, signature: sig)
    }

    /// One shared session: no cookies, no cache, no credentials, short timeouts.
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCredentialStorage = nil
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 600
        c.waitsForConnectivity = false
        // Only what GitHub requires; no version, locale or system details.
        c.httpAdditionalHeaders = ["User-Agent": "iSnow", "Accept-Language": "en"]
        return c.makeSession()
    }()

    enum FetchResult: Sendable {
        case notModified
        case fresh(Data, etag: String?)
    }

    static func fetch(etag: String?) async throws -> FetchResult {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        if !url.isFileURL {
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { return .fresh(data, etag: nil) }   // file://
        if http.statusCode == 304 { return .notModified }
        guard http.statusCode == 200 else {
            throw UpdateError(http.statusCode == 404 ? String(localized: "No release found.")
                                                     : String(localized: "The server answered \(http.statusCode)."))
        }
        return .fresh(data, etag: http.value(forHTTPHeaderField: "ETag"))
    }
}

private extension URLSessionConfiguration {
    func makeSession() -> URLSession { URLSession(configuration: self) }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Dotted version numbers: 1.10 > 1.9, 1.2 == 1.2.0.
enum Version {
    static func parts(_ s: String) -> [Int]? {
        let comps = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(comps.count) else { return nil }
        var out: [Int] = []
        for c in comps {
            guard !c.isEmpty, c.count <= 6, c.allSatisfy(\.isASCII), let n = Int(c), n >= 0 else { return nil }
            out.append(n)
        }
        return out
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parts(a), let y = parts(b) else { return false }
        for i in 0..<max(x.count, y.count) {
            let l = x[safe: i] ?? 0, r = y[safe: i] ?? 0
            if l != r { return l > r }
        }
        return false
    }
}

/// Release notes (GitHub Markdown) as plain lines: no checksum block, images, links or emphasis marks.
enum ReleaseNotes {
    enum Kind { case heading, bullet, text, gap }
    struct Line: Identifiable {
        let id: Int
        let kind: Kind
        let text: String
    }

    static func lines(_ markdown: String) -> [Line] {
        var out: [(Kind, String)] = []
        var inCode = false
        for raw in markdown.components(separatedBy: .newlines) {
            var s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("```") || s.hasPrefix("~~~") { inCode.toggle(); continue }
            if inCode { continue }                                  // code blocks (the checksum)
            if s.contains("![") || s.hasPrefix("<img") { continue } // images
            let lower = s.lowercased()
            if lower.contains("checksum") || lower.hasPrefix("sha-256") || lower.hasPrefix("sha256") { continue }
            if s.allSatisfy({ "-*_= ".contains($0) }) && !s.isEmpty { continue }   // rules
            if s.isEmpty { out.append((.gap, "")); continue }
            var kind = Kind.text
            while s.hasPrefix(">") { s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if s.hasPrefix("#") {
                kind = .heading
                s = String(s.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            } else if s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ") {
                kind = .bullet
                s = String(s.dropFirst(2))
            }
            s = inline(s)
            if !s.isEmpty { out.append((kind, s)) }
        }
        // No gaps at either end or twice in a row; a heading brings its own space.
        var cleaned: [(Kind, String)] = []
        for item in out {
            if item.0 == .gap && (cleaned.isEmpty || cleaned.last?.0 == .gap) { continue }
            cleaned.append(item)
        }
        while cleaned.last?.0 == .gap { cleaned.removeLast() }
        return cleaned.enumerated().map { Line(id: $0.offset, kind: $0.element.0, text: $0.element.1) }
    }

    private static let rules: [(NSRegularExpression, String)] = [
        (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),          // [text](url) → text
        (#"<[^>]+>"#, ""),                           // HTML tags and comments
        (#"(\*\*|__)(.+?)\1"#, "$2"),                // **bold**
        (#"(?<![\w*])\*(?!\s)([^*]+?)\*(?!\w)"#, "$1"),   // *italic*
        (#"`([^`]*)`"#, "$1"),                       // `code`
    ].compactMap { p, t in (try? NSRegularExpression(pattern: p)).map { ($0, t) } }

    static func inline(_ s: String) -> String {
        var t = s
        for (re, template) in rules {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: template)
        }
        return t.trimmingCharacters(in: .whitespaces)
    }
}

@MainActor @Observable
final class Updater {
    static let shared = Updater()

    enum CheckState: Equatable { case idle, checking, upToDate, failed(String) }
    enum InstallState: Equatable { case idle, downloading(Double?), verifying, installing, failed(String) }

    private(set) var checkState: CheckState = .idle
    /// The newest release when it is newer than this copy.
    private(set) var latest: UpdateRelease?
    private(set) var installState: InstallState = .idle
    private(set) var lastCheck: Date?
    private(set) var skippedVersion: String?
    let currentVersion: String

    /// What the menu offers: a newer release the user did not skip.
    var menuRelease: UpdateRelease? {
        guard let latest, latest.version != skippedVersion else { return nil }
        return latest
    }

    var isInstalling: Bool {
        switch installState {
        case .downloading, .verifying, .installing: true
        default: false
        }
    }

    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var checking = false
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var windowObserver: NSObjectProtocol?

    private static let interval: TimeInterval = 24 * 3600
    private static let retryAfterError: TimeInterval = 3 * 3600
    private enum Key {
        static let lastCheck = "updateLastCheck"
        static let skipped = "updateSkippedVersion"
        static let etag = "updateETag"
        static let cache = "updateCache"
    }

    private init() {
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let d = UserDefaults.standard
        let t = d.double(forKey: Key.lastCheck)
        // A test feed is checked at every launch (its checks are not stored as the daily one).
        lastCheck = t > 0 && UpdateFeed.override == nil ? Date(timeIntervalSince1970: t) : nil
        skippedVersion = d.string(forKey: Key.skipped)
    }

    /// Called once at launch: restores what the last check found and schedules the next check.
    func start() {
        if UpdateFeed.override == nil, Settings.shared.config.checkUpdates,
           let data = UserDefaults.standard.data(forKey: Key.cache) {
            adopt(UpdateFeed.parse(data))
        }
        reschedule()
    }

    /// (Re)arms the daily check; none while automatic checks are off. A wall-clock timer, so a Mac that
    /// slept through the due time checks soon after waking.
    func reschedule(retry: Bool = false) {
        timer?.cancel()
        timer = nil
        guard Settings.shared.config.checkUpdates else { return }
        let firstDelay: TimeInterval = UpdateFeed.override != nil ? 3 : 60
        let due = retry ? Self.retryAfterError : (lastCheck.map { $0.timeIntervalSinceNow + Self.interval } ?? 0)
        let delay = max(firstDelay, due)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(wallDeadline: .now() + delay, leeway: .seconds(UpdateFeed.override != nil ? 1 : 60))
        t.setEventHandler {
            MainActor.assumeIsolated { Updater.shared.check(userInitiated: false) }
        }
        t.resume()
        timer = t
    }

    /// "Check for Updates" – also shows a release the user skipped.
    func checkNow() { check(userInitiated: true) }

    private func check(userInitiated: Bool) {
        guard !checking else { return }
        checking = true
        checkState = .checking
        let useCache = UpdateFeed.override == nil
        let d = UserDefaults.standard
        let etag = useCache && d.data(forKey: Key.cache) != nil ? d.string(forKey: Key.etag) : nil
        Task {
            var failed = false
            do {
                let data: Data
                switch try await UpdateFeed.fetch(etag: etag) {
                case .notModified:
                    data = d.data(forKey: Key.cache) ?? Data()
                case let .fresh(fresh, newTag):
                    data = fresh
                    if useCache {
                        d.set(fresh, forKey: Key.cache)
                        d.set(newTag, forKey: Key.etag)
                    }
                }
                adopt(UpdateFeed.parse(data))
                checkState = .upToDate          // the views tell "up to date" from "available" by `latest`
                lastCheck = Date()
                if useCache { d.set(lastCheck!.timeIntervalSince1970, forKey: Key.lastCheck) }
                NSLog("iSnow: update check – latest \(latest?.version ?? "none newer than \(currentVersion)")")
            } catch {
                failed = true
                checkState = .failed(error.localizedDescription)
                NSLog("iSnow: update check failed – \(error.localizedDescription)")
            }
            checking = false
            if !userInitiated || timer != nil { reschedule(retry: failed) }
            if let latest, userInitiated || autoInstallForTesting {
                if userInitiated || latest.version != skippedVersion { showWindow() }
                if autoInstallForTesting { install() }
            }
        }
    }

    /// Test hook: with a local test feed, ISNOW_UPDATE_AUTOINSTALL=1 presses "Install and Relaunch".
    private var autoInstallForTesting: Bool {
        UpdateFeed.override != nil && ProcessInfo.processInfo.environment["ISNOW_UPDATE_AUTOINSTALL"] == "1"
    }

    private func adopt(_ release: UpdateRelease?) {
        let newer = release.flatMap { Version.isNewer($0.version, than: currentVersion) ? $0 : nil }
        if latest != newer { latest = newer }
    }

    func skipLatest() {
        skippedVersion = latest?.version
        UserDefaults.standard.set(skippedVersion, forKey: Key.skipped)
        closeWindow()
    }

    func openDownloadPage() {
        NSWorkspace.shared.open(latest?.page ?? UpdateFeed.releasesPage)
    }

    // MARK: Window

    func showWindow() {
        guard latest != nil else { return }
        if window == nil {
            let host = NSHostingController(rootView: UpdateView(updater: self))
            host.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable]
            w.title = String(localized: "Software Update")
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { Updater.shared.windowWillClose() }
            }
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func closeWindow() {
        window?.close()
    }

    private func windowWillClose() {
        if !isInstalling, case .failed = installState { installState = .idle }
        // Drop the window shortly after it closed (a busy install keeps its state here, not in the view).
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let u = Updater.shared
                guard let w = u.window, !w.isVisible else { return }
                if let o = u.windowObserver { NotificationCenter.default.removeObserver(o) }
                u.windowObserver = nil
                w.contentViewController = nil
                u.window = nil
            }
        }
    }

    // MARK: Install

    func install() {
        guard let release = latest, !isInstalling else { return }
        let bundle = Bundle.main.bundleURL
        if let reason = UpdateInstaller.blocker(for: bundle) {
            installState = .failed(reason + " " + String(localized: "The download page has been opened."))
            NSLog("iSnow: cannot update in place – \(reason)")
            NSWorkspace.shared.open(release.page)
            return
        }
        guard let dmgURL = release.dmg, let sigURL = release.signature,
              let bundleID = Bundle.main.bundleIdentifier else {
            installState = .failed(String(localized: "This release has no signed installer. Get it from the download page."))
            return
        }
        installState = .downloading(nil)
        Task {
            var dir: URL?
            do {
                let tmp = try UpdateInstaller.makePrivateTempDir()
                dir = tmp
                let dmg = tmp.appendingPathComponent("iSnow-v\(release.version).dmg")
                let sig = tmp.appendingPathComponent("iSnow-v\(release.version).dmg.sig")
                try await UpdateInstaller.download(sigURL, to: sig, progress: nil)
                try await UpdateInstaller.download(dmgURL, to: dmg) { p in
                    Task { @MainActor in
                        if case .downloading = Updater.shared.installState { Updater.shared.installState = .downloading(p) }
                    }
                }
                installState = .verifying
                let staged = try await UpdateInstaller.verifyAndStage(
                    dmg: dmg, signature: sig, workDir: tmp, bundle: bundle, bundleID: bundleID, version: release.version)
                installState = .installing
                let installed = try UpdateInstaller.replace(bundle: bundle, with: staged)
                try? FileManager.default.removeItem(at: tmp)
                dir = nil
                NSLog("iSnow: updated to \(release.version) – relaunching")
                try UpdateInstaller.relaunch(installed)
                Settings.shared.saveNow()
                NSApp.terminate(nil)
            } catch {
                if let dir { try? FileManager.default.removeItem(at: dir) }
                NSLog("iSnow: update failed – \(error.localizedDescription)")
                installState = .failed(error.localizedDescription)
            }
        }
    }
}

/// The steps of an update install. Nothing here runs code from the downloaded image.
enum UpdateInstaller {
    /// Why this copy cannot replace itself (nil when it can).
    static func blocker(for bundle: URL) -> String? {
        let path = bundle.standardizedFileURL.path
        guard bundle.pathExtension == "app", Bundle.main.bundleIdentifier != nil else {
            return String(localized: "iSnow is not running from an app bundle.")
        }
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? true
        if path.contains("/AppTranslocation/") || readOnly {
            return String(localized: "iSnow is running from the disk image or a temporary location – move it to the Applications folder first.")
        }
        let parent = bundle.deletingLastPathComponent()
        if Bundle.main.object(forInfoDictionaryKey: "ISnowDeveloperBuild") as? Bool == true
            || path.contains("/.build/") || path.contains("/DerivedData/")
            || ["build", "Build", "Products", "dist"].contains(parent.lastPathComponent) {
            return String(localized: "This copy was built from source – update it with build.sh.")
        }
        let fm = FileManager.default
        if !fm.isWritableFile(atPath: parent.path) || !fm.isWritableFile(atPath: bundle.path)
            || !fm.isWritableFile(atPath: bundle.appendingPathComponent("Contents").path) {
            return String(localized: "iSnow cannot replace itself in this folder (no permission).")
        }
        return nil
    }

    static func makePrivateTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iSnow-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return dir
    }

    static func download(_ url: URL, to dest: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        guard UpdateFeed.isAllowedAsset(url) else { throw UpdateError(String(localized: "Unexpected download address.")) }
        if url.isFileURL {
            try FileManager.default.copyItem(at: url, to: dest)
            return
        }
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let delegate = progress.map { DownloadProgress(onProgress: $0) }
        let (tmp, response) = try await UpdateFeed.session.download(for: req, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError(String(localized: "The download failed."))
        }
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    /// Checks the signature, copies the app out of the image next to the running bundle and checks the copy.
    /// Returns the staged app.
    static func verifyAndStage(dmg: URL, signature: URL, workDir: URL, bundle: URL,
                               bundleID: String, version: String) async throws -> URL {
        // 1. Ed25519 signature over the whole DMG.
        guard let keyData = Data(base64Encoded: UpdateFeed.publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let sigText = try? String(contentsOf: signature, encoding: .utf8), sigText.count < 1000,
              let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let image = try? Data(contentsOf: dmg, options: .mappedIfSafe),
              key.isValidSignature(sig, for: image) else {
            throw UpdateError(String(localized: "The download's signature does not match – nothing was installed. Get the update from the download page."))
        }

        // 2. Mount read-only, without Finder, at a random place inside our private dir.
        let attach = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                                  "-mountrandom", workDir.path, "-plist", dmg.path])
        guard attach.status == 0 else { throw UpdateError(String(localized: "The disk image could not be opened.")) }
        guard let plist = try? PropertyListSerialization.propertyList(from: attach.output, format: nil) as? [String: Any],
              let mount = (plist["system-entities"] as? [[String: Any]])?
                .compactMap({ $0["mount-point"] as? String }).first else {
            // Mounted, but the output could not be read: detach whatever landed in our private dir.
            let fm = FileManager.default
            for m in (try? fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)) ?? []
            where (try? m.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                _ = try? run("/usr/bin/hdiutil", ["detach", m.path, "-force", "-quiet"])
            }
            throw UpdateError(String(localized: "The disk image could not be opened."))
        }
        defer {
            if (try? run("/usr/bin/hdiutil", ["detach", mount, "-quiet"]))?.status != 0 {
                _ = try? run("/usr/bin/hdiutil", ["detach", mount, "-force", "-quiet"])
            }
        }

        // 3. Copy the app to a temporary folder on the same volume as the running bundle.
        let source = URL(fileURLWithPath: mount).appendingPathComponent("iSnow.app")
        let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            throw UpdateError(String(localized: "The disk image does not contain iSnow."))
        }
        let fm = FileManager.default
        let stagingDir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: bundle, create: true)
        let staged = stagingDir.appendingPathComponent("iSnow.app")
        do {
            guard try run("/usr/bin/ditto", [source.path, staged.path]).status == 0 else {
                throw UpdateError(String(localized: "Copying the new version failed."))
            }

            // 4. The copy must be iSnow, the expected version, and intact (code signature).
            let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
            guard info?["CFBundleIdentifier"] as? String == bundleID else {
                throw UpdateError(String(localized: "The downloaded app is not iSnow."))
            }
            guard info?["CFBundleShortVersionString"] as? String == version else {
                throw UpdateError(String(localized: "The downloaded app has an unexpected version."))
            }
            guard try run("/usr/bin/codesign", ["--verify", "--strict", staged.path]).status == 0 else {
                throw UpdateError(String(localized: "The downloaded app's code signature is broken."))
            }
        } catch {
            try? fm.removeItem(at: stagingDir)
            throw error
        }
        return staged
    }

    /// Swaps the new app in place of the running one (atomic on the same volume). Returns the installed app.
    static func replace(bundle: URL, with staged: URL) throws -> URL {
        let fm = FileManager.default
        let stagingDir = staged.deletingLastPathComponent()
        defer { try? fm.removeItem(at: stagingDir) }
        do {
            let result = try fm.replaceItemAt(bundle, withItemAt: staged, backupItemName: nil, options: [])
            return result ?? bundle
        } catch {
            throw UpdateError(String(localized: "iSnow could not replace itself: \(error.localizedDescription)"))
        }
    }

    /// Opens the new app once this process has quit (a detached shell, at most ~30 s of waiting).
    static func relaunch(_ app: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c",
                       "i=0; while kill -0 \"$1\" 2>/dev/null && [ $i -lt 150 ]; do sleep 0.2; i=$((i+1)); done; exec /usr/bin/open \"$2\"",
                       "isnow-relaunch", String(ProcessInfo.processInfo.processIdentifier), app.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    /// Runs a system tool and waits for it; returns its exit status and standard output.
    private static func run(_ tool: String, _ args: [String]) throws -> (status: Int32, output: Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }
}

/// Download progress for the update window.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    let onProgress: @Sendable (Double) -> Void
    init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

// MARK: - Window

struct UpdateView: View {
    let updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("iSnow \(updater.latest?.version ?? "") Is Available")
                        .font(.title3.weight(.semibold))
                    Text("You have version \(updater.currentVersion).")
                        .foregroundStyle(.secondary)
                }
            }
            notes
            Text("After updating, macOS may ask you to allow Accessibility again – iSnow tells you when it does.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            status
            buttons
        }
        .padding(20)
        .frame(width: 500)
    }

    private var notes: some View {
        let lines = ReleaseNotes.lines(updater.latest?.notes ?? "")
        return ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                if lines.isEmpty {
                    Text("No release notes.").foregroundStyle(.secondary)
                }
                ForEach(lines) { line in
                    switch line.kind {
                    case .heading:
                        Text(verbatim: line.text).font(.headline).padding(.top, line.id == 0 ? 0 : 4)
                    case .bullet:
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: "•")
                            Text(verbatim: line.text)
                        }
                    case .text:
                        Text(verbatim: line.text)
                    case .gap:
                        Spacer().frame(height: 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(12)
        }
        .frame(height: 220)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var status: some View {
        switch updater.installState {
        case .idle:
            EmptyView()
        case let .downloading(p):
            HStack {
                if let p { ProgressView(value: p) } else { ProgressView().progressViewStyle(.linear) }
                Text("Downloading…").foregroundStyle(.secondary)
            }
        case .verifying:
            HStack { ProgressView().controlSize(.small); Text("Verifying…").foregroundStyle(.secondary) }
        case .installing:
            HStack { ProgressView().controlSize(.small); Text("Installing…").foregroundStyle(.secondary) }
        case let .failed(message):
            Label { Text(verbatim: message) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var failed: Bool {
        if case .failed = updater.installState { return true }
        return false
    }

    private var buttons: some View {
        HStack {
            Button("Skip This Version") { updater.skipLatest() }
            Spacer()
            Button("Later") { updater.closeWindow() }
            if failed {
                Button("Download Page") { updater.openDownloadPage() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Download Page") { updater.openDownloadPage() }
                Button("Install and Relaunch") { updater.install() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .disabled(updater.isInstalling)
    }
}

/// The "Software Update" section of the About tab.
struct UpdateSection: View {
    private var settings: Settings { Settings.shared }
    private var updater: Updater { Updater.shared }

    var body: some View {
        Section("Software Update") {
            HStack {
                status
                Spacer()
                if updater.latest != nil {
                    Button("Show Update…") { updater.showWindow() }
                }
                Button("Check for Updates") { updater.checkNow() }
                    .disabled(updater.checkState == .checking || updater.isInstalling)
            }
            Toggle("Check for updates automatically", isOn: Binding(
                get: { settings.config.checkUpdates },
                set: { settings.config.checkUpdates = $0; updater.reschedule() }))
            Text("Once a day iSnow asks GitHub for the latest version. Nothing else is sent.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var status: some View {
        if updater.checkState == .checking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…")
            }
        } else if let r = updater.latest {
            Text("Version \(r.version) is available")
        } else if case let .failed(message) = updater.checkState {
            Text("Couldn't check for updates: \(message)")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if let d = updater.lastCheck {
            VStack(alignment: .leading, spacing: 2) {
                Text("iSnow is up to date")
                Text("Last checked \(d.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("Not checked yet").foregroundStyle(.secondary)
        }
    }
}
