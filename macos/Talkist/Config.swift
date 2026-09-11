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
        return dataDir.appendingPathComponent("sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8", isDirectory: true)
    }

    static var cacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("talkist", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

enum AppRelaunch {
    /// Spawn a detached shell that swaps in `newPath` (optional) and reopens
    /// the app after this process exits.
    static func relaunch(replacing newPath: String?) {
        let app = Bundle.main.bundlePath
        var script = "sleep 1\n"
        if let newPath {
            script += """
            if mv '\(newPath)' '\(app).incoming' 2>/dev/null; then
                rm -rf '\(app)'
                mv '\(app).incoming' '\(app)'
            fi
            """
        }
        script += "\nopen '\(app)'\n"
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