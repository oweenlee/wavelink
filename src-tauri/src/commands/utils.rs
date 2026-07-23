#[tauri::command]
pub fn save_text_file(path: String, content: String) -> Result<(), String> {
    std::fs::write(&path, &content).map_err(|e| format!("write file failed: {e}"))
}

#[tauri::command]
pub fn read_text_file(path: String) -> Result<String, String> {
    let bytes = std::fs::read(&path).map_err(|e| format!("read file failed: {e}"))?;
    if let Ok(s) = String::from_utf8(bytes.clone()) {
        return Ok(s);
    }
    use encoding_rs::GBK;
    let (cow, _, had_errors) = GBK.decode(&bytes);
    if had_errors {
        Err("encoding is neither UTF-8 nor GBK".to_string())
    } else {
        Ok(cow.into_owned())
    }
}
