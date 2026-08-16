//! Subsonic 音乐服务器命令：连接测试 / 扫描 / 搜索 / 下载到本地缓存后播放。
//!
//! 协议对齐移动端 subsonic_service.dart：认证走 URL query 参数
//! `u/p/v=1.16.0/c=wavelink`（明文），JSON 响应。播放策略同移动端：
//! 全量下载到本地缓存目录再交给本地引擎播放。

use std::collections::HashMap;
use std::path::Path;

use reqwest::Method;
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Manager, State};

use crate::settings;
use crate::state::AppState;

/// settings.json 持久化 key（对齐移动端 subsonic_service 的 key 名）
const KEY_BASE_URL: &str = "subsonicBaseUrl";
const KEY_USERNAME: &str = "subsonicUsername";
const KEY_PASSWORD: &str = "subsonicPassword";

/// Subsonic 协议版本
const API_VERSION: &str = "1.16.0";
const CLIENT_NAME: &str = "wavelink";

/// 分页大小（getAlbumList2）
const PAGE_SIZE: u32 = 500;

/// 连接配置
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubsonicConfig {
    pub base_url: String,
    pub username: String,
    pub password: String,
}

/// 曲目（含 stream/cover URL 拼装）
#[derive(Debug, Clone, Serialize)]
pub struct SubsonicSong {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_ms: i64,
    pub stream_url: String,
    pub cover_url: Option<String>,
    /// 服务器端路径（仅展示用），用于推断扩展名
    pub path: String,
}

/// 读取持久化的 Subsonic 配置
#[tauri::command]
pub fn subsonic_get_config() -> SubsonicConfig {
    let saved = settings::load_settings().unwrap_or_default();
    SubsonicConfig {
        base_url: get_str(&saved, KEY_BASE_URL),
        username: get_str(&saved, KEY_USERNAME),
        password: get_str(&saved, KEY_PASSWORD),
    }
}

/// 保存 Subsonic 配置（合并写入）
#[tauri::command]
pub fn subsonic_save_config(config: SubsonicConfig) -> Result<(), String> {
    let mut saved = settings::load_settings().unwrap_or_default();
    saved.insert(KEY_BASE_URL.into(), serde_json::Value::String(config.base_url));
    saved.insert(KEY_USERNAME.into(), serde_json::Value::String(config.username));
    saved.insert(KEY_PASSWORD.into(), serde_json::Value::String(config.password));
    settings::save_settings(saved)
}

fn get_str(m: &HashMap<String, serde_json::Value>, key: &str) -> String {
    m.get(key)
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string()
}

fn trim_base_url(mut base: String) -> String {
    while base.ends_with('/') {
        base.pop();
    }
    base
}

/// 构建带认证 query 参数的完整 URL
fn build_url(base_url: &str, api_path: &str, username: &str, password: &str, extra: &[(&str, String)]) -> Result<String, String> {
    let mut url = reqwest::Url::parse(&format!("{base_url}/rest{api_path}")).map_err_str("无效 URL")?;
    {
        let mut pairs = url.query_pairs_mut();
        pairs.append_pair("u", username);
        pairs.append_pair("p", password);
        pairs.append_pair("v", API_VERSION);
        pairs.append_pair("c", CLIENT_NAME);
        pairs.append_pair("f", "json");
        for (k, v) in extra {
            pairs.append_pair(k, v);
        }
    }
    Ok(url.to_string())
}

/// 小的 Result 辅助（避免重复 map_err）
trait MapErrStr<T> {
    fn map_err_str(self, what: &str) -> Result<T, String>;
}
impl<T, E: std::fmt::Display> MapErrStr<T> for Result<T, E> {
    fn map_err_str(self, what: &str) -> Result<T, String> {
        self.map_err(|e| format!("{what}: {e}"))
    }
}

/// 发送 Subsonic GET 请求并解析 JSON（HTTP 非 200 或 status=failed 都报错）
fn subsonic_get_json(
    client: &reqwest::blocking::Client,
    base_url: &str,
    api_path: &str,
    username: &str,
    password: &str,
    extra: &[(&str, String)],
) -> Result<serde_json::Value, String> {
    let url = build_url(base_url, api_path, username, password, extra)?;
    let resp = client
        .request(Method::GET, &url)
        .header(reqwest::header::ACCEPT, "application/json")
        .send()
        .map_err_str("Subsonic 请求失败")?;
    if !resp.status().is_success() {
        return Err(format!("HTTP {}: {url}", resp.status()));
    }
    let text = resp.text().map_err_str("读取响应失败")?;
    let json: serde_json::Value = serde_json::from_str(&text).map_err_str("解析 Subsonic JSON 失败")?;
    let status = json
        .get("subsonic-response")
        .and_then(|r| r.get("status"))
        .and_then(|s| s.as_str())
        .unwrap_or("");
    if status == "failed" {
        let msg = json
            .get("subsonic-response")
            .and_then(|r| r.get("error"))
            .and_then(|e| e.get("message"))
            .and_then(|m| m.as_str())
            .unwrap_or("未知错误");
        return Err(format!("Subsonic 错误: {msg}"));
    }
    Ok(json)
}

fn get_str_field(obj: &serde_json::Value, key: &str) -> String {
    obj.get(key).and_then(|v| v.as_str()).unwrap_or("").to_string()
}

/// 单曲映射为 SubsonicSong（对齐移动端 _toSong）
fn to_song(track: &serde_json::Value, fallback_artist: &str, fallback_album: &str, base_url: &str, username: &str, password: &str) -> Option<SubsonicSong> {
    let id = get_str_field(track, "id");
    if id.is_empty() {
        return None;
    }
    let title = get_str_field(track, "title");
    let artist = {
        let a = get_str_field(track, "artist");
        if a.is_empty() {
            fallback_artist.to_string()
        } else {
            a
        }
    };
    let album = {
        let a = get_str_field(track, "album");
        if a.is_empty() {
            fallback_album.to_string()
        } else {
            a
        }
    };
    let path = get_str_field(track, "path");
    let duration = track.get("duration").and_then(|d| d.as_i64()).unwrap_or(0) * 1000;
    let cover = get_str_field(track, "coverArt");
    let cover_url = if cover.is_empty() {
        None
    } else {
        Some(format!(
            "{base_url}/rest/getCoverArt?id={cover}&u={username}&p={password}&v={API_VERSION}&c={CLIENT_NAME}"
        ))
    };
    let stream_url = format!(
        "{base_url}/rest/stream?id={id}&u={username}&p={password}&v={API_VERSION}&c={CLIENT_NAME}"
    );
    Some(SubsonicSong {
        id: format!("sub_{id}"),
        title,
        artist,
        album,
        duration_ms: duration,
        stream_url,
        cover_url,
        path,
    })
}

/// 测试连接：GET /rest/ping
#[tauri::command]
pub async fn subsonic_test_connection(
    base_url: String,
    username: String,
    password: String,
) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || {
        let base_url = trim_base_url(base_url);
        if !base_url.starts_with("http://") && !base_url.starts_with("https://") {
            return Err("URL 需以 http:// 或 https:// 开头".into());
        }
        let client = crate::remote::http_client()?;
        subsonic_get_json(&client, &base_url, "/ping", &username, &password, &[])?;
        Ok(())
    })
    .await
    .map_err(|e| format!("subsonic task failed: {e}"))?
}

/// 扫描曲库：getAlbumList2 分页 + 每专辑 getAlbum（对齐移动端 scanLibrary）
#[tauri::command]
pub async fn subsonic_scan(
    base_url: String,
    username: String,
    password: String,
) -> Result<Vec<SubsonicSong>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let base_url = trim_base_url(base_url);
        let client = crate::remote::http_client()?;
        let mut songs: Vec<SubsonicSong> = Vec::new();
        let mut offset: u32 = 0;

        loop {
            let extra = vec![
                ("type", "alphabeticalByName".to_string()),
                ("size", PAGE_SIZE.to_string()),
                ("offset", offset.to_string()),
            ];
            let json = subsonic_get_json(&client, &base_url, "/getAlbumList2", &username, &password, &extra)?;
            let albums: Vec<serde_json::Value> = json
                .get("subsonic-response")
                .and_then(|r| r.get("albumList2"))
                .and_then(|a| a.get("album"))
                .and_then(|a| a.as_array())
                .cloned()
                .unwrap_or_default();
            if albums.is_empty() {
                break;
            }
            for album in &albums {
                let album_id = get_str_field(album, "id");
                let album_name = get_str_field(album, "name");
                let artist = get_str_field(album, "artist");
                if album_id.is_empty() {
                    continue;
                }
                let extra = vec![("id", album_id.clone())];
                if let Ok(json) = subsonic_get_json(&client, &base_url, "/getAlbum", &username, &password, &extra) {
                    let tracks = json
                        .get("subsonic-response")
                        .and_then(|r| r.get("album"))
                        .and_then(|a| a.get("song"))
                        .and_then(|s| s.as_array())
                        .cloned()
                        .unwrap_or_default();
                    for t in &tracks {
                        if let Some(song) = to_song(t, &artist, &album_name, &base_url, &username, &password) {
                            songs.push(song);
                        }
                    }
                }
            }
            if albums.len() < PAGE_SIZE as usize {
                break;
            }
            offset += PAGE_SIZE;
        }
        Ok(songs)
    })
    .await
    .map_err(|e| format!("subsonic task failed: {e}"))?
}

/// 搜索曲目：GET /rest/search3
#[tauri::command]
pub async fn subsonic_search(
    base_url: String,
    username: String,
    password: String,
    query: String,
) -> Result<Vec<SubsonicSong>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let base_url = trim_base_url(base_url);
        let client = crate::remote::http_client()?;
        let extra = vec![
            ("query", query),
            ("songCount", "50".to_string()),
        ];
        let json = subsonic_get_json(&client, &base_url, "/search3", &username, &password, &extra)?;
        let songs: Vec<serde_json::Value> = json
            .get("subsonic-response")
            .and_then(|r| r.get("searchResult3"))
            .and_then(|s| s.get("song"))
            .and_then(|s| s.as_array())
            .cloned()
            .unwrap_or_default();
        Ok(songs
            .iter()
            .filter_map(|t| to_song(t, "", "", &base_url, &username, &password))
            .collect())
    })
    .await
    .map_err(|e| format!("subsonic task failed: {e}"))?
}

/// 从服务器路径推断扩展名（用于本地缓存文件名）
fn ext_from_path(path: &str, _stream_url: &str) -> String {
    let ext = path
        .rsplit('.')
        .next()
        .unwrap_or("")
        .to_lowercase();
    if !ext.is_empty() && ext.len() <= 5 && ext.chars().all(|c| c.is_ascii_alphanumeric()) {
        return ext;
    }
    // 兜底：从 stream_url 的 id 无法推断，取默认
    "bin".to_string()
}

/// 下载 Subsonic stream 到本地缓存（`.cache/subsonic/{id}.{ext}`），返回本地路径。
#[tauri::command]
pub async fn subsonic_download_to_cache(
    stream_url: String,
    song_id: String,
    path_hint: String,
    app: AppHandle,
) -> Result<String, String> {
    let cache_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?
        .join(".cache")
        .join("subsonic");
    tauri::async_runtime::spawn_blocking(move || {
        subsonic_download_to_cache_blocking(&stream_url, &song_id, &path_hint, &cache_dir)
    })
    .await
    .map_err(|e| format!("subsonic task failed: {e}"))?
}

fn subsonic_download_to_cache_blocking(
    stream_url: &str,
    song_id: &str,
    path_hint: &str,
    cache_dir: &Path,
) -> Result<String, String> {
    std::fs::create_dir_all(cache_dir).map_err(|e| e.to_string())?;

    let ext = ext_from_path(path_hint, stream_url);
    let safe_id: String = song_id
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '_' || c == '-' { c } else { '_' })
        .collect();
    let final_path = cache_dir.join(format!("{safe_id}.{ext}"));
    let final_str = final_path.to_string_lossy().to_string();

    if let Ok(meta) = std::fs::metadata(&final_path) {
        if meta.len() > 0 {
            return Ok(final_str);
        }
    }

    // stream URL 已含认证 query 参数，直接 GET 无需认证协商
    let client = crate::remote::http_client()?;
    let resp = client
        .request(Method::GET, stream_url)
        .header(reqwest::header::ACCEPT_ENCODING, "identity")
        .send()
        .map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("HTTP {}: {stream_url}", resp.status()));
    }

    let part_path = cache_dir.join(format!("{safe_id}.{ext}.part"));
    let mut file = std::fs::File::create(&part_path).map_err(|e| e.to_string())?;
    use std::io::Write;
    let mut body = resp;
    std::io::copy(&mut body, &mut file).map_err(|e| e.to_string())?;
    file.flush().map_err(|e| e.to_string())?;
    drop(file);

    if std::fs::metadata(&part_path).map(|m| m.len() == 0).unwrap_or(true) {
        let _ = std::fs::remove_file(&part_path);
        return Err(format!("下载为空文件: {stream_url}"));
    }
    std::fs::rename(&part_path, &final_path).map_err(|e| e.to_string())?;
    Ok(final_str)
}

/// 播放 Subsonic 曲目：下载到本地缓存后交给引擎播放（全量下载方案）
#[tauri::command]
pub async fn subsonic_play(
    stream_url: String,
    song_id: String,
    path_hint: String,
    state: State<'_, AppState>,
    app: AppHandle,
) -> Result<String, String> {
    let local = subsonic_download_to_cache(stream_url, song_id, path_hint, app).await?;
    *crate::commands::lock_or_die(&state.current_track) = Some(local.clone());
    crate::commands::apply_track_settings(&state);
    state.engine.play(local.clone());
    Ok(local)
}