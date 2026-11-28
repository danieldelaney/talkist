import Foundation

struct Config: Codable {
    var hotkey: String
    var startAtLogin: Bool
    var numThreads: Int

    static let defaults = Config(hotkey: "F9", startAtLogin: false, numThreads: 4)

    static func load() -> Config {
        let d = UserDefaults.standard
        return Config(
            hotkey: d.string(forKey: "hotkey") ?? defaults.hotkey,
            startAtLogin: d.object(forKey: "startAtLogin") as? Bool ?? defaults.startAtLogin,
            numThreads: d.object(forKey: "numThreads") as? Int ?? defaults.numThreads
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(hotkey, forKey: "hotkey")
        d.set(startAtLogin, forKey: "startAtLogin")
        d.set(numThreads, forKey: "numThreads")
    }
}

enum Paths {
    static var dataDir: URL {
        if let custom = ProcessInfo.processInfo.environment["PARAKEET_MODEL_DIR"] {
            return URL(fileURLWithPath: custom).deletingLastPathComponent()
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("talkist", isDirectory: true)
    }

    static var modelDir: URL {
        if let custom = ProcessInfo.processInfo.environment["PARAKEET_MODEL_DIR"] {
            return URL(fileURLWithPath: custom)
        }
        return dataDir.appendingPathComponent("sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8", isDirectory: true)
    }

    static var cacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("talkist", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

enum AppRelaunch {
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Replace `targetPath` with `newPath` using macOS's native administrator
    /// prompt (for standard non-admin accounts updating /Applications).
    static func replaceWithAdminPrivileges(
        newPath: String,
        targetPath: String,
        cleanupPaths: [String] = []
    ) throws {
        let src = shellQuote(newPath)
        let dst = shellQuote(targetPath)
        let incoming = shellQuote(targetPath + ".incoming")
        var cmd = "mv \(src) \(incoming) && rm -rf \(dst) && mv \(incoming) \(dst)"
        for path in cleanupPaths {
            cmd += "; rm -rf \(shellQuote(path))"
        }
        let script = "do shell script \"\(appleScriptEscape(cmd))\" with administrator privileges"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw NSError(
                domain: "talkist",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Administrator permission is required to update Talkist."]
            )
        }
    }

    /// Spawn a detached shell that swaps in `newPath` (optional), cleans up
    /// temporary update files, and reopens the app after this process exits.
    static func relaunch(replacing newPath: String?, cleanupPaths: [String] = []) {
        let app = Bundle.main.bundlePath
        let qApp = shellQuote(app)
        var script = "sleep 1\n"
        if let newPath {
            let qNew = shellQuote(newPath)
            let qIncoming = shellQuote(app + ".incoming")
            script += """
            if mv \(qNew) \(qIncoming) 2>/dev/null; then
                rm -rf \(qApp)
                mv \(qIncoming) \(qApp)
            fi
            """
        }
        for path in cleanupPaths {
            script += "\nrm -rf \(shellQuote(path))"
        }
        script += "\nopen \(qApp)\n"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()
        exit(0)
    }
}

enum SingleInstance {
    static func acquire() -> Bool {
        let path = NSHomeDirectory() + "/Library/Caches/talkist.lock"
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        return true // fd stays open for the process lifetime: holds the lock
    }
}
