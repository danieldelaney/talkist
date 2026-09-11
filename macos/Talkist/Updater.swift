import Foundation
import CryptoKit

struct UpdateManifest: Codable {
    let version: String
    let package: String
    let architecture: String
    let url: String
    let size: Int
    let sha256: String
}

/// Self-updater: minisign-verified `update-mac.json` manifest (same signing
/// key as Linux, separate manifest), downloaded zip verified by sha256 +
/// size, then a detached shell swaps the bundle and relaunches.
final class Updater {
    static let manifestURL = "https://github.com/danieldelaney/talkist/releases/latest/download/update-mac.json"
    static let signatureURL = "https://github.com/danieldelaney/talkist/releases/latest/download/update-mac.json.minisig"

    private(set) var available: UpdateManifest?
    private let lock = NSLock()

    func currentVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    /// Poll for updates; calls onAvailable on the main thread when one is
    /// found, then rechecks every 24 h (same cadence as the Linux build).
    func startChecks(onAvailable: @escaping (UpdateManifest) -> Void) {
        Thread.detachNewThread { [weak self] in
            while true {
                if let self, let update = self.check() {
                    self.lock.lock()
                    self.available = update
                    self.lock.unlock()
                    DispatchQueue.main.async { onAvailable(update) }
                }
                Thread.sleep(forTimeInterval: 24 * 60 * 60)
            }
        }
    }

    func check() -> UpdateManifest? {
        guard let manifestBytes = fetchSmall(Self.manifestURL, limit: 64 * 1024),
              let sigText = fetchSmall(Self.signatureURL, limit: 16 * 1024).map({ String(decoding: $0, as: UTF8.self) }) else {
            return nil
        }
        guard Minisign.verify(message: manifestBytes, signatureText: sigText) else {
            logStderr("update signature failed")
            return nil
        }
        guard let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: manifestBytes) else {
            logStderr("update manifest is malformed")
            return nil
        }
        guard manifest.package == "talkist", manifest.architecture == "arm64" else {
            logStderr("update manifest targets another package")
            return nil
        }
        guard manifest.url.hasPrefix("https://github.com/danieldelaney/talkist/releases/download/") else {
            logStderr("update manifest has an unexpected URL")
            return nil
        }
        guard Self.isNewer(manifest.version, than: currentVersion()) else { return nil }
        return manifest
    }

    /// Downloads the zip, verifies it, extracts it, then swaps + relaunches
    /// (the process exits). On failure the error is reported and the app stays.
    func downloadAndInstall(
        manifest: UpdateManifest,
        onProgress: @escaping (Int) -> Void,
        onStage: @escaping (String) -> Void,
        onError: @escaping (String) -> Void
    ) {
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            do {
                try self.install(manifest: manifest, onProgress: onProgress, onStage: onStage)
            } catch {
                DispatchQueue.main.async { onError(error.localizedDescription) }
            }
        }
    }

    private func install(manifest: UpdateManifest, onProgress: @escaping (Int) -> Void, onStage: @escaping (String) -> Void) throws {
        let dir = Paths.cacheDir
        let zip = dir.appendingPathComponent("Talkist_\(manifest.version)_arm64.zip")

        DispatchQueue.main.async { onProgress(0) }
        let delegate = DownloadDelegate { pct in
            DispatchQueue.main.async { onProgress(pct) }
        } onComplete: { _ in }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let sem = DispatchSemaphore(value: 0)
        var outcome: Result<URL, Error>!
        delegate.completion = { result in
            outcome = result
            sem.signal()
        }
        let task = session.downloadTask(with: URL(string: manifest.url)!)
        task.resume()
        sem.wait()
        let localURL = try outcome.get()
        try? FileManager.default.removeItem(at: zip)
        try FileManager.default.moveItem(at: localURL, to: zip)

        let data = try Data(contentsOf: zip, options: .mappedIfSafe)
        let actualSize = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? 0
        guard actualSize == manifest.size,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == manifest.sha256 else {
            try? FileManager.default.removeItem(at: zip)
            throw NSError(domain: "talkist", code: 1, userInfo: [NSLocalizedDescriptionKey: "downloaded update failed verification"])
        }

        onStage("Installing...")
        let extractDir = dir.appendingPathComponent("update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, extractDir.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw NSError(domain: "talkist", code: 2, userInfo: [NSLocalizedDescriptionKey: "update extraction failed"])
        }
        let newApp = extractDir.appendingPathComponent("Talkist.app")
        guard FileManager.default.fileExists(atPath: newApp.path),
              bundleVersion(at: newApp) == manifest.version else {
            try? FileManager.default.removeItem(at: extractDir)
            throw NSError(domain: "talkist", code: 3, userInfo: [NSLocalizedDescriptionKey: "update has incorrect version"])
        }
        let cs = Process()
        cs.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        cs.arguments = ["--verify", newApp.path]
        try cs.run()
        cs.waitUntilExit()
        guard cs.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: extractDir)
            throw NSError(domain: "talkist", code: 4, userInfo: [NSLocalizedDescriptionKey: "update failed its signature check"])
        }
        DispatchQueue.main.async { onStage("Restarting...") }
        AppRelaunch.relaunch(replacing: newApp.path)
    }

    private func bundleVersion(at url: URL) -> String? {
        let info = Bundle(url: url)?.infoDictionary
        return info?["CFBundleShortVersionString"] as? String
    }

    private func fetchSmall(_ url: String, limit: Int) -> Data? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let sem = DispatchSemaphore(value: 0)
        var data: Data?
        var error: Error?
        let task = URLSession.shared.dataTask(with: request) { d, r, e in
            if let e { error = e }
            if let http = r as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                // No manifest published yet: stay silent (parity with ureq's
                // error-on-non-2xx in the Rust updater).
                data = nil
            } else {
                data = d
            }
            sem.signal()
        }
        task.resume()
        sem.wait()
        if error != nil { return nil }
        guard let data, data.count <= limit else { return nil }
        return data
    }

    /// Small semver compare for x.y.z strings.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let aParts = parts(a), bParts = parts(b)
        for i in 0..<max(aParts.count, bParts.count) {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }
}