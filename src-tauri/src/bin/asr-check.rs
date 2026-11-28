// Headless decode check: prints the transcript of a wav through the same
// model config the app uses. Usage: asr-check <model_dir> <wav>
use sherpa_onnx::{OfflineRecognizer, OfflineRecognizerConfig};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: asr-check <model_dir> <wav>");
        std::process::exit(2);
    }
    let (dir, wav) = (args[1].clone(), args[2].clone());

    let mut cfg = OfflineRecognizerConfig::default();
    let mc = &mut cfg.model_config;
    mc.transducer.encoder = Some(format!("{dir}/encoder.int8.onnx"));
    mc.transducer.decoder = Some(format!("{dir}/decoder.int8.onnx"));
    mc.transducer.joiner = Some(format!("{dir}/joiner.int8.onnx"));
    mc.tokens = Some(format!("{dir}/tokens.txt"));
    mc.model_type = Some("nemo_transducer".into());
    mc.num_threads = 4;

    let recognizer = OfflineRecognizer::create(&cfg).expect("model load failed");
    let w = sherpa_onnx::Wave::read(&wav).expect("wav read failed");
    let stream = recognizer.create_stream();
    stream.accept_waveform(w.sample_rate(), w.samples());
    let t0 = std::time::Instant::now();
    recognizer.decode(&stream);
    let res = stream.get_result().expect("result");
    eprintln!("decoded in {:?}", t0.elapsed());
    println!("{}", res.text);
}
