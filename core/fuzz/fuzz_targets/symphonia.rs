#![no_main]

/// Symphonia probe + decode 模糊测试
/// 用随机字节喂给 Symphonia 的解码管线，检测崩溃/死循环/内存问题
use std::io::Cursor;

use libfuzzer_sys::fuzz_target;
use symphonia::core::codecs::audio::AudioDecoderOptions;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, TrackType};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;

/// 所有支持的扩展名，逐个尝试
const EXTENSIONS: &[&str] = &[
    "mp3", "flac", "ogg", "opus", "wav", "aiff",
    "m4a", "mp4", "aac",
];

fuzz_target!(|data: &[u8]| {
    if data.len() < 4 || data.len() > 1024 * 1024 {
        return;
    }

    for &ext in EXTENSIONS {
        let cursor = Cursor::new(data);
        let mss = MediaSourceStream::new(Box::new(cursor), Default::default());

        let mut hint = Hint::new();
        hint.with_extension(ext);

        let probe = symphonia::default::get_probe().probe(
            &hint,
            mss,
            FormatOptions::default(),
            MetadataOptions::default(),
        );

        if let Ok(mut format) = probe {
            let track_id = match format.default_track(TrackType::Audio) {
                Some(t) => t.id,
                None => continue,
            };
            let cp = {
                let track = format.default_track(TrackType::Audio).unwrap();
                match &track.codec_params {
                    Some(symphonia::core::codecs::CodecParameters::Audio(a)) => a.clone(),
                    _ => continue,
                }
            };

            let mut decoder: Box<dyn symphonia::core::codecs::audio::AudioDecoder> =
                match symphonia::default::get_codecs()
                    .make_audio_decoder(&cp, &AudioDecoderOptions::default())
                {
                    Ok(d) => d,
                    Err(_) => continue,
                };

            // 尝试解码最多 50 个 packet，防止死循环
            for _ in 0..50 {
                match format.next_packet() {
                    Ok(Some(pkt)) => {
                        if pkt.track_id != track_id {
                            continue;
                        }
                        let _ = decoder.decode(&pkt);
                    }
                    _ => break,
                }
            }
        }
    }
});
