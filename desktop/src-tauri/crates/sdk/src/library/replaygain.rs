use std::path::Path;

/// 用 FFmpeg ebur128 滤波器分析音频响度
/// 返回集成响度 (LUFS)
pub fn analyze_loudness(path: &Path) -> Result<f64, String> {
    let path_str = path.to_string_lossy();

    if !path.exists() {
        return Err(format!("文件不存在: {path_str}"));
    }

    let output = std::process::Command::new("ffmpeg")
        .args([
            "-i", &path_str,
            "-filter_complex", "ebur128",
            "-f", "null",
            "-",
        ])
        .output()
        .map_err(|e| format!("ffmpeg 执行失败: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        // ebur128 即使成功也会写 stderr (ffmpeg 行为)
        return parse_loudness(&stderr);
    }

    let stderr = String::from_utf8_lossy(&output.stderr);
    parse_loudness(&stderr)
}

/// 从 ffmpeg stderr 输出中解析集成响度
/// 示例行: "I: -15.8 LUFS"
/// 示例行: "Integrated loudness: I: -15.8 LUFS"
fn parse_loudness(stderr: &str) -> Result<f64, String> {
    for line in stderr.lines() {
        // 匹配 "I: -XX.X LUFS"
        if let Some(val) = line
            .find("I: ")
            .and_then(|pos| {
                let rest = &line[pos + 3..];
                rest.split_whitespace().next()
            })
            .and_then(|s| s.parse::<f64>().ok())
        {
            return Ok(val);
        }
        // 也匹配 "Integrated loudness: I: -XX.X LUFS"
        if line.contains("Integrated loudness") {
            if let Some(val) = line
                .find("I: ")
                .and_then(|pos| {
                    let rest = &line[pos + 3..];
                    rest.split_whitespace().next()
                })
                .and_then(|s| s.parse::<f64>().ok())
            {
                return Ok(val);
            }
        }
    }
    Err("无法从 ffmpeg 输出中解析响度".to_string())
}

/// 根据响度值 (LUFS) 计算推荐增益 (dB)
/// 目标响度: -14 LUFS (串流平台标准, 如 Spotify/Youtube)
pub fn gain_for_loudness(loudness_lufs: f64) -> f64 {
    -14.0 - loudness_lufs
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_loudness_standard() {
        let output = "\
[Parsed_ebur128_0 @ 0x...] I: -15.8 LUFS
[Parsed_ebur128_0 @ 0x...] LRA: 3.2 LU
[Parsed_ebur128_0 @ 0x...] LRA threshold: -25.3 LUFS
";
        let lufs = parse_loudness(output).unwrap();
        assert!((lufs + 15.8).abs() < 0.01, "解析错误: {lufs}");
    }

    #[test]
    fn test_parse_loudness_alternative() {
        let output = "\
Integrated loudness:
  I: -12.3 LUFS
  LRA: 2.1 LU
";
        let lufs = parse_loudness(output).unwrap();
        assert!((lufs + 12.3).abs() < 0.01, "解析错误: {lufs}");
    }

    #[test]
    fn test_gain_for_loudness() {
        // -20 LUFS → +6 dB gain
        let g = gain_for_loudness(-20.0);
        assert!((g - 6.0).abs() < 0.01, "增益计算错误: {g}");

        // -14 LUFS → 0 dB (target)
        let g = gain_for_loudness(-14.0);
        assert!((g - 0.0).abs() < 0.01, "增益计算错误: {g}");

        // -8 LUFS → -6 dB (reduce)
        let g = gain_for_loudness(-8.0);
        assert!((g + 6.0).abs() < 0.01, "增益计算错误: {g}");
    }
}
