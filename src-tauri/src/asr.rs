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
    wayland_paster: Option<paste::WaylandPasteHandle>,
) -> Result<SyncSender<Vec<f32>>> {
    let mut cfg = OfflineRecognizerConfig::default();
    let mc = &mut cfg.model_config;
    mc.transducer.encoder = Some(model_dir.join("encoder.int8.onnx").display().to_string());
    mc.transducer.decoder = Some(model_dir.join("decoder.int8.onnx").display().to_string());
    mc.transducer.joiner = Some(model_dir.join("joiner.int8.onnx").display().to_string());
    mc.tokens = Some(model_dir.join("tokens.txt").display().to_string());
    mc.model_type = Some("nemo_transducer".into());
    mc.num_threads = num_threads;

    // Load the recognizer synchronously on the caller's setup thread so a
    // corrupt or missing model fails cleanly and can be retried in the UI.
    let recognizer = OfflineRecognizer::create(&cfg)
        .context("failed to load the Parakeet model")?;
    eprintln!("asr ready");

    let (tx, rx) = sync_channel::<Vec<f32>>(1);
    std::thread::spawn(move || {
        let mut paster = match paste::Paster::new(wayland_paster) {
            Ok(p) => Some(p),
            Err(e) => {
                eprintln!("clipboard unavailable, transcription will not paste: {e:#}");
                None
            }
        };

        while let Ok(samples) = rx.recv() {
            let started = std::time::Instant::now();
            let stream = recognizer.create_stream();
            stream.accept_waveform(16000, &samples);
            recognizer.decode(&stream);
            if let Some(res) = stream.get_result() {
                let text = res.text.trim();
                eprintln!(
                    "decode: {:.2}s, text={text:?}",
                    started.elapsed().as_secs_f32()
                );
                if !text.is_empty() {
                    eprintln!("transcript: {text}");
                    if let Some(p) = paster.as_mut() {
                        if let Err(e) = p.paste(text) {
                            eprintln!("paste failed: {e:#}");
                        }
                    }
                }
            }
            let _ = status_tx.send(crate::audio::Status::Idle);
        }
    });

    Ok(tx)
}
