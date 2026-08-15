//! 临时：BPM / 调性算法准确度抽查（合成音频，已知答案）
use audio_core::analysis;

const SR: u32 = 44100;
const TAU: f32 = std::f32::consts::TAU;

fn tone(freq: f32, dur: f32, amp: f32) -> Vec<f32> {
    let n = (SR as f32 * dur) as usize;
    (0..n)
        .map(|i| {
            let t = i as f32 / SR as f32;
            // 简单衰减包络
            let env = (-t * 2.0).exp();
            amp * env * (TAU * freq * t).sin()
        })
        .collect()
}

/// 泛音丰富的音色（基频 + 泛音列，模拟真实乐器）
fn rich_tone(freq: f32, dur: f32, amp: f32) -> Vec<f32> {
    let n = (SR as f32 * dur) as usize;
    (0..n)
        .map(|i| {
            let t = i as f32 / SR as f32;
            let env = (-t * 1.5).exp();
            let mut s = 0.0;
            for h in 1..=6 {
                s += (TAU * freq * h as f32 * t).sin() / h as f32;
            }
            amp * env * s
        })
        .collect()
}

fn mix_chord(freqs: &[f32], dur: f32, rich: bool) -> Vec<f32> {
    let mut out = vec![0.0f32; (SR as f32 * dur) as usize];
    for (i, f) in freqs.iter().enumerate() {
        let partial = if rich {
            rich_tone(*f, dur, 1.0 / freqs.len() as f32)
        } else {
            tone(*f, dur, 1.0 / freqs.len() as f32)
        };
        for (o, p) in out.iter_mut().zip(partial) {
            *o += p;
        }
        let _ = i;
    }
    out
}

/// 和弦进行（每个和弦 dur 秒）
fn progression(chords: &[&[f32]], dur: f32, rich: bool) -> Vec<f32> {
    let mut out = Vec::new();
    for c in chords {
        out.extend(mix_chord(c, dur, rich));
    }
    out
}

fn key_of(samples: &[f32]) -> Option<String> {
    analysis::analyze_from_samples(samples, SR, 1).key
}

#[test]
fn key_c_major_pure_triad() {
    // C4 E4 G4 纯音三和弦，重复 8 次
    let chords: Vec<&[f32]> = vec![&[261.63, 329.63, 392.0]; 8];
    let s = progression(&chords, 2.5, false);
    let key = key_of(&s);
    println!("C 大三和弦(纯音) → {:?}", key);
    assert_eq!(key.as_deref(), Some("C"));
}

#[test]
fn key_a_minor_pure_triad() {
    // A3 C4 E4
    let chords: Vec<&[f32]> = vec![&[220.0, 261.63, 329.63]; 8];
    let s = progression(&chords, 2.5, false);
    let key = key_of(&s);
    println!("A 小三和弦(纯音) → {:?}", key);
    assert_eq!(key.as_deref(), Some("Am"));
}

#[test]
fn key_c_major_rich_harmonics() {
    // 泛音丰富的 C 大三和弦 —— 更接近真实乐器
    let chords: Vec<&[f32]> = vec![&[261.63, 329.63, 392.0]; 8];
    let s = progression(&chords, 2.5, true);
    let key = key_of(&s);
    println!("C 大三和弦(泛音) → {:?}", key);
    assert_eq!(key.as_deref(), Some("C"));
}

#[test]
fn key_c_major_progression() {
    // C - F - G - C 进行（古典终止式，强 C 大调信号）
    let c = &[261.63, 329.63, 392.0][..];
    let f = &[349.23, 440.0, 523.25][..];
    let g = &[392.0, 493.88, 587.33][..];
    let mut chords = Vec::new();
    for _ in 0..4 {
        chords.push(c);
        chords.push(f);
        chords.push(g);
        chords.push(c);
    }
    let s = progression(&chords, 1.5, true);
    let key = key_of(&s);
    println!("C-F-G-C 进行(泛音) → {:?}", key);
    assert_eq!(key.as_deref(), Some("C"));
}

#[test]
fn key_g_major_progression() {
    // G - C - D - G
    let g = &[196.0, 246.94, 293.66][..];
    let c = &[261.63, 329.63, 392.0][..];
    let d = &[293.66, 369.99, 440.0][..];
    let mut chords = Vec::new();
    for _ in 0..4 {
        chords.push(g);
        chords.push(c);
        chords.push(d);
        chords.push(g);
    }
    let s = progression(&chords, 1.5, true);
    let key = key_of(&s);
    println!("G-C-D-G 进行(泛音) → {:?}", key);
    assert_eq!(key.as_deref(), Some("G"));
}

#[test]
fn bpm_kick_120() {
    // 120 BPM 底鼓（低频衰减正弦模拟 kick）
    let dur_total = 20.0f32;
    let n = (SR as f32 * dur_total) as usize;
    let mut s = vec![0.0f32; n];
    let beat = (SR as f32 * 0.5) as usize; // 120 BPM = 0.5s/拍
    let kick_len = (SR as f32 * 0.15) as usize;
    let mut pos = 0;
    while pos + kick_len < n {
        for i in 0..kick_len {
            let t = i as f32 / SR as f32;
            let env = (-t * 30.0).exp();
            s[pos + i] += env * (TAU * 55.0 * t).sin();
        }
        pos += beat;
    }
    let bpm = analysis::analyze_from_samples(&s, SR, 1).bpm;
    println!("120 BPM kick → {:?}", bpm);
    let v = bpm.expect("应检测到 BPM");
    assert!(
        (v - 120.0).abs() < 1.0 || (v - 60.0).abs() < 1.0 || (v - 240.0).abs() < 1.0,
        "BPM {v} 偏离过大"
    );
    println!("  (实际 {v}，理想 120)");
}

#[test]
fn bpm_kick_90_with_offbeat_hat() {
    // 90 BPM kick + 反拍 hat（更接近真实 beat）
    let dur_total = 20.0f32;
    let n = (SR as f32 * dur_total) as usize;
    let mut s = vec![0.0f32; n];
    let beat = SR as f32 * 60.0 / 90.0; // 0.6667s
    let kick_len = (SR as f32 * 0.15) as usize;
    let hat_len = (SR as f32 * 0.03) as usize;
    // kick on beats
    let mut pos = 0.0f32;
    while (pos as usize) + kick_len < n {
        let p = pos as usize;
        for i in 0..kick_len {
            let t = i as f32 / SR as f32;
            s[p + i] += (-t * 30.0).exp() * (TAU * 55.0 * t).sin();
        }
        pos += beat;
    }
    // hat on offbeats (半拍偏移)
    let mut pos = beat / 2.0;
    while (pos as usize) + hat_len < n {
        let p = pos as usize;
        for i in 0..hat_len {
            let t = i as f32 / SR as f32;
            s[p + i] += 0.3 * (-t * 100.0).exp() * (TAU * 8000.0 * t).sin();
        }
        pos += beat;
    }
    let bpm = analysis::analyze_from_samples(&s, SR, 1).bpm;
    println!("90 BPM kick+hat → {:?}", bpm);
    let v = bpm.expect("应检测到 BPM");
    println!("  (实际 {v}，理想 90)");
    assert!(
        (v - 90.0).abs() < 1.0 || (v - 45.0).abs() < 1.0 || (v - 180.0).abs() < 1.0,
        "BPM {v} 偏离过大"
    );
}
