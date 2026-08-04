use std::path::PathBuf;
use sdk::{probe_sample_rate, probe_bit_depth, read_replaygain, ReplayGain};
use sdk::output::{enumerate_devices, decide_output, SourceFormat, OutputDecision};

#[tauri::command]
pub fn probe_sample_rate_cmd(path: String) -> i32 {
    probe_sample_rate(&PathBuf::from(&path)).unwrap_or(0) as i32
}

#[tauri::command]
pub fn probe_bit_depth_cmd(path: String) -> i32 {
    probe_bit_depth(&PathBuf::from(&path)).unwrap_or(0) as i32
}

#[tauri::command]
pub fn read_replaygain_tags(path: String) -> Result<ReplayGain, String> {
    read_replaygain(&PathBuf::from(&path)).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn decide_output_cmd(
    device_id: String,
    source_sample_rate: u32,
    source_bit_depth: u8,
    source_channels: u16,
    is_dsd: bool,
    dsd_rate: Option<u32>,
    prefer_exclusive: bool,
) -> Result<OutputDecision, String> {
    let source = SourceFormat {
        sample_rate: source_sample_rate,
        bit_depth: source_bit_depth,
        channels: source_channels,
        is_dsd,
        dsd_rate,
    };
    let devices = enumerate_devices();
    let device = devices
        .iter()
        .find(|d| d.id == device_id)
        .ok_or_else(|| format!("Device '{}' not found", device_id))?;
    decide_output(device, &source, prefer_exclusive).map_err(|e| format!("{:?}", e))
}
