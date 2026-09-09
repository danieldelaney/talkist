// Offline Parakeet decode worker. One thread owns the recognizer; utterances
// arrive as 16 kHz mono f32 buffers and get pasted at the cursor.
use crate::paste;
use anyhow::{Context, Result};
use sherpa_onnx::{OfflineRecognizer, OfflineRecognizerConfig};
use std::path::PathBuf;
use std::sync::mpsc::{sync_channel, SyncSender};

pub fn spawn(
    model_dir: PathBuf,
    num_threads: i32,
    status_tx: std::sync::mpsc::Sender<crate::audio::Status>,
) -> Result<SyncSender<Vec<f32>>> {
    let mut cfg = OfflineRecognizerConfig::default();
    let mc = &mut cfg.model_config;
    mc.transducer.encoder = Some(model_dir.join("encoder.int8.onnx").display().to_string());
    mc.transducer.decoder = Some(model_dir.join("decoder.int8.onnx").display().to_string());
    mc.transducer.joiner = Some(model_dir.join("joiner.int8.onnx").display().to_string());
    mc.tokens = Some(model_dir.join("tokens.txt").display().to_string());
    mc.model_type = Some("nemo_transducer".into());
    mc.num_threads = num_threads;

    // Initialize ONNX Runtime before GTK/WebKit starts. This is also where a
    // corrupt model fails, rather than later on an opaque worker thread.
    let recognizer = OfflineRecognizer::create(&cfg)
        .context("failed to load the Parakeet model")?;
    eprintln!("asr ready");

    let (tx, rx) = sync_channel::<Vec<f32>>(1);
    std::thread::spawn(move || {
        let mut paster = match paste::Paster::new() {
            Ok(p) => Some(p),
            Err(e) => {
                eprintln!("clipboard unavailable, transcription will not paste: {e:#}");
                None
            }
        };

        while let Ok(samples) = rx.recv() {
            let stream = recognizer.create_stream();
            stream.accept_waveform(16000, &samples);
            recognizer.decode(&stream);
            if let Some(res) = stream.get_result() {
                let text = res.text.trim();
                if text.is_empty() {
                    continue;
                }
                eprintln!("transcript: {text}");
                if let Some(p) = paster.as_mut() {
                    if let Err(e) = p.paste(text) {
                        eprintln!("paste failed: {e:#}");
                    }
                }
            }
            let _ = status_tx.send(crate::audio::Status::Idle);
        }
    });

    Ok(tx)
}
