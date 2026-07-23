use tauri::State;
use sdk::dsp::{default_peq_bands, preset_bands, PeqBand, PresetName};
use crate::state::AppState;

#[tauri::command]
pub fn get_eq_bands(state: State<AppState>) -> Result<Vec<PeqBand>, String> {
    let bands = state.peq_bands.lock().map_err(|e| format!("lock failed: {e}"))?;
    Ok(bands.clone())
}

#[tauri::command]
pub fn set_peq_band(
    index: usize,
    freq: f32,
    gain_db: f32,
    q: f32,
    state: State<AppState>,
) -> Result<(), String> {
    let mut bands = state.peq_bands.lock().map_err(|e| format!("lock failed: {e}"))?;
    if index < bands.len() {
        bands[index] = PeqBand { freq, gain_db, q };
        state.engine.set_peq_band(index, PeqBand { freq, gain_db, q });
    }
    Ok(())
}

#[tauri::command]
pub fn reset_eq(state: State<AppState>) -> Result<(), String> {
    let defaults = default_peq_bands();
    *state.peq_bands.lock().map_err(|e| format!("lock failed: {e}"))? = defaults.clone();
    for (i, band) in defaults.iter().enumerate() {
        state.engine.set_peq_band(i, band.clone());
    }
    Ok(())
}

#[tauri::command]
pub fn set_eq_preset(preset: PresetName, state: State<AppState>) -> Result<(), String> {
    let new_bands = preset_bands(preset);
    *state.peq_bands.lock().map_err(|e| format!("lock failed: {e}"))? = new_bands.clone();
    for (i, band) in new_bands.iter().enumerate() {
        state.engine.set_peq_band(i, band.clone());
    }
    for i in 10..31 {
        state.engine.set_peq_band(i, PeqBand { freq: 0.0, gain_db: 0.0, q: 1.41 });
    }
    Ok(())
}
