import Foundation
import AVFoundation
import AVFAudio

/// Bounded mailbox with capacity 1 (the Swift equivalent of Rust's
/// `sync_channel(1)`): `trySend` drops when the consumer hasn't picked up the
/// previous item ("asr busy, utterance dropped").
final class BoundedMailbox<T> {
    private let slots = DispatchSemaphore(value: 1) // one free slot
    private let ready = DispatchSemaphore(value: 0) // item present
    private let lock = NSLock()
    private var item: T?

    func trySend(_ value: T) -> Bool {
        guard slots.wait(timeout: .now()) == .success else { return false }
        lock.lock()
        item = value
        lock.unlock()
        ready.signal()
        return true
    }

    func receive() -> T {
        ready.wait()
        lock.lock()
        let value = item!
        item = nil
        lock.unlock()
        slots.signal()
        return value
    }
}

/// Multi-producer channel for tray status, with the `recv_timeout` behavior
/// the tray state machine needs.
final class StatusChannel {
    private let cond = NSCondition()
    private var queue: [Status] = []

    func send(_ status: Status) {
        cond.lock()
        queue.append(status)
        cond.signal()
        cond.unlock()
    }

    func recv(timeout: TimeInterval?) -> Status? {
        cond.lock()
        defer { cond.unlock() }
        if queue.isEmpty {
            if let timeout {
                if !cond.wait(until: Date().addingTimeInterval(timeout)) { return nil }
            } else {
                cond.wait()
            }
        }
        return queue.isEmpty ? nil : queue.removeFirst()
    }
}

enum Cmd { case start, stopSend }
enum Status: Equatable { case idle, recording, transcribing }

/// Mic capture actor: a serial queue owns the AVAudioEngine (the AVFoundation
/// equivalent of the cpal stream the Rust actor thread owns); commands arrive
/// from the hotkey path, 16 kHz mono utterances leave for the recognizer.
final class AudioCapture {
    private let queue = DispatchQueue(label: "com.talkist.audio")
    private let asrMailbox: BoundedMailbox<[Float]>
    private let statusChannel: StatusChannel
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var nativeFormat: AVAudioFormat?
    private var samples: [Float] = []
    private var recording = false
    private var startRequested = false

    init(asrMailbox: BoundedMailbox<[Float]>, statusChannel: StatusChannel) {
        self.asrMailbox = asrMailbox
        self.statusChannel = statusChannel
    }

    func send(_ cmd: Cmd) {
        queue.async { [weak self] in self?.handle(cmd) }
    }

    private func handle(_ cmd: Cmd) {
        switch cmd {
        case .start:
            startRequested = true
            guard !recording else { return }
            if #available(macOS 14.0, *) {
                switch AVAudioApplication.shared.recordPermission {
                case .granted:
                    beginRecording()
                case .undetermined:
                    AVAudioApplication.requestRecordPermission { [weak self] granted in
                        self?.queue.async {
                            guard let self, self.startRequested, granted else { return }
                            self.beginRecording()
                        }
                    }
                case .denied:
                    logStderr("microphone permission not granted")
                @unknown default:
                    logStderr("unknown microphone authorization state")
                }
                return
            }
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                beginRecording()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    self?.queue.async {
                        guard let self, self.startRequested, granted else { return }
                        self.beginRecording()
                    }
                }
            case .denied, .restricted:
                logStderr("microphone permission not granted")
            @unknown default:
                logStderr("unknown microphone authorization state")
            }
        case .stopSend:
            startRequested = false
            stopAndSend()
        }
    }

    private func beginRecording() {
        do {
            try startRecording()
            recording = true
            statusChannel.send(.recording)
        } catch {
            logStderr("mic start failed: \(error.localizedDescription)")
            teardownEngine()
        }
    }

    private func startRecording() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        samples = []
        converter = nil
        nativeFormat = native

        // Tap at the device's native format and convert to 16 kHz mono
        // ourselves (AVAudioConverter). The Rust build does the same thing in
        // two steps (cpal capture + LinearResampler); this is one engine call
        // and does not depend on the engine accepting a converted tap format.
        if native.sampleRate != 16000 || native.channelCount != 1 {
            let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            converter = try AVAudioConverter(from: native, to: target)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: native) { [weak self] buffer, _ in
            guard let self else { return }
            if self.converter != nil {
                self.convert(buffer)
            } else if buffer.format.channelCount == 1 {
                self.appendDirect(buffer)
            } else {
                self.appendMixdown(buffer)
            }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        logStderr("recording: \(native.sampleRate) Hz, \(native.channelCount) ch")
    }

    private func appendDirect(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        appendFrames(Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
    }

    private func appendMixdown(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let frames = Int(buffer.frameLength)
        let ch = Int(buffer.format.channelCount)
        var mixed = [Float](repeating: 0, count: frames)
        for c in 0..<ch {
            let p = UnsafeBufferPointer(start: channel[c], count: frames)
            for i in 0..<frames { mixed[i] += p[i] }
        }
        for i in 0..<frames { mixed[i] /= Float(ch) }
        appendFrames(mixed)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) {
        guard let converter, buffer.frameLength > 0 else { return }
        let ratio = 16000.0 / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio) + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }
        var fed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            logStderr("resample failed: \(err?.localizedDescription ?? "?")")
            return
        }
        if status == .haveData, let channel = out.floatChannelData?[0] {
            appendFrames(Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength))))
        }
    }

    private func appendFrames(_ frames: [Float]) {
        queue.async { [weak self] in
            guard let self, self.recording else { return }
            self.samples.append(contentsOf: frames)
        }
    }

    private func teardownEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        converter = nil
    }

    private func stopAndSend() {
        guard recording, let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        converter = nil
        recording = false
        let captured = samples
        samples = []
        let peak = captured.lazy.map { abs($0) }.max() ?? 0
        let rms = captured.isEmpty ? 0 : sqrt(captured.reduce(0) { $0 + $1 * $1 } / Float(captured.count))
        logStderr("captured: \(captured.count) samples, peak \(peak), rms \(rms)")
        if captured.count < 3200 {
            statusChannel.send(.idle)
            return // under 0.2 s, ignore
        }
        statusChannel.send(.transcribing)
        if !asrMailbox.trySend(captured) {
            logStderr("asr busy, utterance dropped")
            statusChannel.send(.idle)
        }
    }
}

func logStderr(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
