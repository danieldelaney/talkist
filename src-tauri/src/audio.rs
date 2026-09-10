// Mic capture adapted from sherpa-onnx rust-api-examples
// (parakeet_tdt_simulate_streaming_microphone.rs).
//
// cpal::Stream is !Send on Linux, so streams are created and owned by a
// dedicated actor thread; the UI thread only sends commands.
use anyhow::{anyhow, Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::SampleFormat;
use sherpa_onnx::LinearResampler;
use std::sync::mpsc::{channel, Sender, SyncSender};
use std::sync::{Arc, Mutex};

pub enum Cmd {
    Start,
    StopSend,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Idle,
    Recording,
    Transcribing,
}

/// Spawn the capture actor. Returns a command sender; the actor owns the
/// cpal stream and forwards finished 16 kHz mono utterances to `asr_tx`.
pub fn spawn_actor(
    asr_tx: SyncSender<Vec<f32>>,
    status_tx: Sender<Status>,
) -> Sender<Cmd> {
    let (tx, rx) = channel::<Cmd>();
    std::thread::spawn(move || {
        let mut slot: Option<Recorder> = None;
        for cmd in rx {
            match cmd {
                Cmd::Start => {
                    if slot.is_none() {
                        match Recorder::start() {
                            Ok(r) => {
                                slot = Some(r);
                                let _ = status_tx.send(Status::Recording);
                            }
                            Err(e) => eprintln!("mic start failed: {e:#}"),
                        }
                    }
                }
                Cmd::StopSend => stop_and_send(&mut slot, &asr_tx, &status_tx),
            }
        }
    });
    tx
}

fn stop_and_send(
    slot: &mut Option<Recorder>,
    asr_tx: &SyncSender<Vec<f32>>,
    status_tx: &Sender<Status>,
) {
    if let Some(rec) = slot.take() {
        match rec.stop() {
            Ok(samples) => {
                if samples.len() < 3200 {
                    let _ = status_tx.send(Status::Idle);
                    return; // under 0.2 s, ignore
                }
                let _ = status_tx.send(Status::Transcribing);
                if asr_tx.try_send(samples).is_err() {
                    eprintln!("asr busy, utterance dropped");
                    let _ = status_tx.send(Status::Idle);
                }
            }
            Err(e) => {
                eprintln!("recorder stop failed: {e:#}");
                let _ = status_tx.send(Status::Idle);
            }
        }
    }
}

pub struct Recorder {
    _stream: cpal::Stream,
    buffer: Arc<Mutex<Vec<f32>>>,
    input_rate: i32,
}

impl Recorder {
    pub fn start() -> Result<Self> {
        let host = cpal::default_host();
        let device = host
            .default_input_device()
            .context("no default input device")?;
        let supported = device.default_input_config()?;
        let cfg = supported.config();
        let ch = cfg.channels as usize;
        let rate = cfg.sample_rate.0;
        let format = supported.sample_format();

        let buffer = Arc::new(Mutex::new(Vec::<f32>::new()));
        let sink = buffer.clone();
        let err_fn = move |e| eprintln!("audio: {e}");

        let stream = match format {
            SampleFormat::F32 => device.build_input_stream(
                &cfg,
                move |d: &[f32], _| {
                    if d.is_empty() {
                        return;
                    }
                    sink.lock().unwrap().extend(
                        d.chunks(ch).map(|f| f.iter().copied().sum::<f32>() / ch as f32),
                    );
                },
                err_fn,
                None,
            )?,
            SampleFormat::I16 => device.build_input_stream(
                &cfg,
                move |d: &[i16], _| {
                    if d.is_empty() {
                        return;
                    }
                    sink.lock().unwrap().extend(d.chunks(ch).map(|f| {
                        f.iter().map(|&s| s as f32 / 32768.0).sum::<f32>() / ch as f32
                    }));
                },
                err_fn,
                None,
            )?,
            SampleFormat::U16 => device.build_input_stream(
                &cfg,
                move |d: &[u16], _| {
                    if d.is_empty() {
                        return;
                    }
                    sink.lock().unwrap().extend(d.chunks(ch).map(|f| {
                        f.iter()
                            .map(|&s| (s as f32 - 32768.0) / 32768.0)
                            .sum::<f32>()
                            / ch as f32
                    }));
                },
                err_fn,
                None,
            )?,
            other => return Err(anyhow!("unsupported sample format {other:?}")),
        };

        stream.play()?;
        eprintln!("recording: {rate} Hz, {} ch, {format:?}", cfg.channels);
        Ok(Self {
            _stream: stream,
            buffer,
            input_rate: rate as i32,
        })
    }

    /// Stop capturing and return mono samples resampled to 16 kHz.
    pub fn stop(self) -> Result<Vec<f32>> {
        drop(self._stream);
        let raw = std::mem::take(&mut *self.buffer.lock().unwrap());
        if self.input_rate == 16000 || raw.is_empty() {
            return Ok(raw);
        }
        let resampler = LinearResampler::create(self.input_rate, 16000)
            .context("failed to create resampler")?;
        Ok(resampler.resample(&raw, true))
    }
}
