import Foundation
import CryptoKit

enum ModelError: LocalizedError {
    case checksum
    case extraction
    case missingFiles
    var errorDescription: String? {
        switch self {
        case .checksum: return "downloaded model failed its checksum"
        case .extraction: return "model extraction failed"
        case .missingFiles: return "archive did not contain the expected model files"
        }
    }
}

enum ModelStore {
    static let modelURL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2"
    static let modelSHA256 = "157c157bc51155e03e37d2466522a3a737dd9c72bb25f36eb18912964161e1ad"

    static func isReady(at dir: URL) -> Bool {
        hasSize(dir, "encoder.int8.onnx", 500 * 1024 * 1024)
            && hasSize(dir, "decoder.int8.onnx", 1024 * 1024)
            && hasSize(dir, "joiner.int8.onnx", 512 * 1024)
            && hasSize(dir, "tokens.txt", 1024)
    }

    /// Downloads, verifies and extracts the model. Progress is the download
    /// percentage 0-100. Runs synchronously on the calling thread.
    static func downloadAndExtract(progress: @escaping (Int) -> Void) throws {
        let env = ProcessInfo.processInfo.environment
        let customURL = env["PARAKEET_MODEL_URL"]
        let url = customURL ?? modelURL
        let expectedSHA = env["PARAKEET_MODEL_SHA256"] ?? (customURL == nil ? modelSHA256 : nil)
        let dataDir = Paths.dataDir
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let archive = dataDir.appendingPathComponent("model.tar.bz2")
        try? FileManager.default.removeItem(at: archive)

        let sem = DispatchSemaphore(value: 0)
        var result: Result<URL, Error>!
        let delegate = DownloadDelegate { pct in
            DispatchQueue.main.async { progress(pct) }
        } onComplete: { r in
            result = r
            sem.signal()
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: URL(string: url)!)
        task.resume()
        sem.wait()
        let localURL = try result.get()

        let data = try Data(contentsOf: localURL, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let expectedSHA, actual != expectedSHA {
            try? FileManager.default.removeItem(at: localURL)
            throw ModelError.checksum
        }
        try FileManager.default.moveItem(at: localURL, to: archive)

        DispatchQueue.main.async { progress(100) }
        if FileManager.default.fileExists(atPath: Paths.modelDir.path) {
            try FileManager.default.removeItem(at: Paths.modelDir)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-xjf", archive.path, "-C", dataDir.path]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw ModelError.extraction
        }
        try? FileManager.default.removeItem(at: archive)
        if !isReady(at: Paths.modelDir) { throw ModelError.missingFiles }
    }

    private static func hasSize(_ dir: URL, _ name: String, _ minimum: UInt64) -> Bool {
        guard let m = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path) else { return false }
        return (m[.size] as? UInt64).map { $0 >= minimum } ?? false
    }
}

final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Int) -> Void
    var completion: (Result<URL, Error>) -> Void

    init(onProgress: @escaping (Int) -> Void, onComplete: @escaping (Result<URL, Error>) -> Void) {
        self.onProgress = onProgress
        self.completion = onComplete
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Int(totalBytesWritten * 100 / totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { completion(.failure(error)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            completion(.failure(NSError(domain: "talkist.model", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "download failed (HTTP \(http.statusCode))"])))
            return
        }
        completion(.success(location))
    }
}