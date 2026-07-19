#[tauri::command]
pub fn save_text_file(path: String, content: String) -> Result<(), String> {
    std::fs::write(&path, &content).map_err(|e| format!("写入文件失败: {e}"))
}

#[tauri::command]
pub fn read_text_file(path: String) -> Result<String, String> {
    let bytes = std::fs::read(&path).map_err(|e| format!("读取文件失败: {e}"))?;
    if let Ok(s) = String::from_utf8(bytes.clone()) {
        return Ok(s);
    }
    use encoding_rs::GBK;
    let (cow, _, had_errors) = GBK.decode(&bytes);
    if had_errors {
        Err("文件编码不是 UTF-8 或 GBK".to_string())
    } else {
        Ok(cow.into_owned())
    }
}
