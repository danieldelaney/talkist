import Foundation
import SherpaOnnx

// Offline Parakeet decode worker. One thread owns the recognizer; utterances
// arrive as 16 kHz mono f32 buffers and get pasted at the cursor.
enum Recognizer {
    /// Loads the model (this is where a corrupt model fails, visibly) and
    /// spawns the worker thread. Returns false if the model files are missing.
    static func spawn(
        modelDir: URL, numThreads: Int,
        mailbox: BoundedMailbox<[Float]>, statusChannel: StatusChannel
    ) -> Bool {
        let feat = sherpaOnnxFeatureConfig()
        let transducer = sherpaOnnxOfflineTransducerModelConfig(
            encoder: modelDir.appendingPathComponent("encoder.int8.onnx").path,
            decoder: modelDir.appendingPathComponent("decoder.int8.onnx").path,
            joiner: modelDir.appendingPathComponent("joiner.int8.onnx").path
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: modelDir.appendingPathComponent("tokens.txt").path,
            transducer: transducer,
            numThreads: numThreads,
            modelType: "nemo_transducer"
        )
        var recognizerConfig = sherpaOnnxOfflineRecognizerConfig(featConfig: feat, modelConfig: modelConfig)
        // The bridge wrapper crashes if the underlying load fails, matching
        // the Rust build's panic on model init failure.
        let recognizer = SherpaOnnxOfflineRecognizer(config: &recognizerConfig)
        logStderr("asr ready")

        Thread.detachNewThread {
                         while true {
                let samples = mailbox.receive()
                let started = Date()
                let result = recognizer.decode(samples: samples, sampleRate: 16000)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                logStderr("decode: \(Date().timeIntervalSince(started))s, text=\(String(reflecting: text))")
                if !text.isEmpty {
                    logStderr("transcript: \(text)")
                    Paster.paste(text)
                }
                statusChannel.send(.idle)
            }
        }
        return true
    }
}
