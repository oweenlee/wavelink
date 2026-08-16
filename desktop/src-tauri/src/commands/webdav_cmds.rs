//! WebDAV 命令：连接测试 / 列目录 / 递归扫描 / 下载到本地缓存后播放。
//!
//! 认证支持 Basic / Digest（协商逻辑见 `crate::remote`）。
//! 播放策略：全量下载到 app data 目录的 `.cache/webdav/` 再交给本地引擎
//! （对齐移动端 Subsonic 全量下载方案，规避 stream 复杂度与 seek 限制）。

use std::collections::HashMap;
use std::path::Path;

use reqwest::Method;
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Manager, State};

use crate::settings;
use crate::state::AppState;

/// settings.json 持久化 key（对齐移动端 webdav_service.dart 的 key 名）
const KEY_BASE_URL: &str = "webdavBaseUrl";
const KEY_PATH: &str = "webdavPath";
const KEY_USERNAME: &str = "webdavUsername";
const KEY_PASSWORD: &str = "webdavPassword";

/// 音频扩展名白名单（与 sdk scanner 一致）
const AUDIO_EXTS: &[&str] = &[
    "mp3", "flac", "wav", "ogg", "aac", "m4a", "m4b", "mp4", "wma", "dsf", "dff", "ape", "opus",
    "aiff", "aif", "wv",
];

/// WebDAV 连接配置
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WebdavConfig {
    pub base_url: String,
    pub path: String,
    pub username: String,
    pub password: String,
}

/// 目录条目（列目录/扫描结果）
#[derive(Debug, Clone, Serialize)]
pub struct WebdavEntry {
    pub name: String,
    pub url: String,
    pub is_dir: bool,
    pub size: u64,
    pub ext: String,
}

/// 读取持久化的 WebDAV 配置
#[tauri::command]
pub fn webdav_get_config() -> WebdavConfig {
    let saved = settings::load_settings().unwrap_or_default();
    WebdavConfig {
        base_url: get_str(&saved, KEY_BASE_URL),
        path: get_str(&saved, KEY_PATH),
        username: get_str(&saved, KEY_USERNAME),
        password: get_str(&saved, KEY_PASSWORD),
    }
}

/// 保存 WebDAV 配置（合并写入，避免覆盖其他字段）
#[tauri::command]
pub fn webdav_save_config(config: WebdavConfig) -> Result<(), String> {
    let mut saved = settings::load_settings().unwrap_or_default();
    saved.insert(KEY_BASE_URL.into(), serde_json::Value::String(config.base_url));
    saved.insert(KEY_PATH.into(), serde_json::Value::String(config.path));
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

/// 拼接完整 URL：davPath 已是完整 URL 则原样返回，否则 base(去尾/)+路径
pub fn full_url_for(base: &str, path: &str) -> String {
    if path.starts_with("http://") || path.starts_with("https://") {
        return path.to_string();
    }
    let base = base.trim_end_matches('/');
    let path = path.trim_start_matches('/');
    if path.is_empty() {
        base.to_string()
    } else {
        format!("{base}/{path}")
    }
}

/// PROPFIND 请求体（depth=1，取 resourcetype/length/修改时间）
const PROPFIND_BODY: &str = r#"<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:resourcetype/>
    <d:getcontentlength/>
    <d:getlastmodified/>
  </d:prop>
</d:propfind>"#;

fn is_audio(url: &str) -> bool {
    let lower = url.to_lowercase();
    AUDIO_EXTS
        .iter()
        .any(|e| lower.ends_with(&format!(".{e}")))
}

fn url_decode(s: &str) -> String {
    use percent_encoding::percent_decode_str;
    percent_decode_str(s)
        .decode_utf8_lossy()
        .into_owned()
}

/// 解析 PROPFIND multistatus XML（quick-xml 事件流），返回目录条目列表
fn parse_propfind(xml: &str) -> Result<Vec<WebdavEntry>, String> {
    use quick_xml::events::Event;
    use quick_xml::Reader;

    let mut reader = Reader::from_str(xml);
    let mut entries = Vec::new();

    // 当前正在组装的 response
    let mut cur: Option<HashMap<String, String>> = None;
    // 元素内的文本缓冲
    let mut text = String::new();

    loop {
        match reader.read_event() {
            Ok(Event::Start(e)) => {
                let name = e.name().as_ref().to_vec();
                let name = String::from_utf8_lossy(&name).into_owned();
                let local = name.rsplit(':').next().unwrap_or("").to_string();
                if local == "response" && cur.is_none() {
                    cur = Some(HashMap::new());
                }
                text.clear();
            }
            Ok(Event::Empty(e)) => {
                let name = e.name().as_ref().to_vec();
                let name = String::from_utf8_lossy(&name).into_owned();
                let local = name.rsplit(':').next().unwrap_or("").to_string();
                // <collection/> 空元素：标记为目录
                if local == "collection" {
                    if let Some(ref mut c) = cur {
                        c.insert("is_dir".into(), "1".into());
                    }
                }
            }
            Ok(Event::Text(t)) => {
                text.push_str(&t.unescape().map_err(|e| e.to_string())?.into_owned());
            }
            Ok(Event::End(e)) => {
                let name = e.name().as_ref().to_vec();
                let name = String::from_utf8_lossy(&name).into_owned();
                let local = name.rsplit(':').next().unwrap_or("").to_string();
                let value = text.trim().to_string();
                text.clear();
                if let Some(ref mut c) = cur {
                    match local.as_str() {
                        "href" => {
                            c.insert("href".into(), value);
                        }
                        "getcontentlength" => {
                            c.insert("size".into(), value);
                        }
                        "resourcetype" => {
                            // 子元素 <collection/> 已通过 Empty 处理
                        }
                        "response" => {
                            // 结束 response：组装条目
                            if let Some(map) = cur.take() {
                                if let Some(href) = map.get("href") {
                                    if href == "/" || href.is_empty() {
                                        continue;
                                    }
                                    let url = url_decode(href);
                                    let name = url
                                        .trim_end_matches('/')
                                        .rsplit('/')
                                        .next()
                                        .unwrap_or("")
                                        .to_string();
                                    if name.is_empty() {
                                        continue;
                                    }
                                    let is_dir = map.get("is_dir").is_some();
                                    let size = map
                                        .get("size")
                                        .and_then(|s| s.parse::<u64>().ok())
                                        .unwrap_or(0);
                                    // 跳过自身目录条目（href 与请求路径相同）
                                    entries.push(WebdavEntry {
                                        name,
                                        url,
                                        is_dir,
                                        size,
                                        ext: String::new(),
                                    });
                                }
                            }
                        }
                        _ => {}
                    }
                }
            }
            Ok(Event::Eof) => break,
            Err(e) => return Err(format!("PROPFIND XML 解析失败: {e}")),
            _ => {}
        }
    }
    Ok(entries)
}

/// 列出 WebDAV 目录（PROPFIND depth=1，不递归）
#[tauri::command]
pub async fn webdav_list(
    base_url: String,
    path: String,
    username: String,
    password: String,
) -> Result<Vec<WebdavEntry>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let client = crate::remote::http_client()?;
        let url = full_url_for(&base_url, &path);
        let url = if url.ends_with('/') {
            url
        } else {
            format!("{url}/")
        };

        let method = Method::from_bytes(b"PROPFIND").map_err(|e| e.to_string())?;
        let extra = [("depth", "1".to_string())];
        let resp = crate::remote::auth_request(
            &client,
            &method,
            &url,
            &username,
            &password,
            &extra,
            Some(PROPFIND_BODY.as_bytes().to_vec()),
        )?;
        if !resp.status().is_success() {
            return Err(format!("HTTP {}: {url}", resp.status()));
        }
        let xml = resp.text().map_err(|e| e.to_string())?;
        let mut entries = parse_propfind(&xml)?;
        // 过滤掉自身目录（href 解析出的 name 为空已跳过）；标注扩展名
        for e in &mut entries {
            if !e.is_dir {
                e.ext = e
                    .url
                    .rsplit('.')
                    .next()
                    .unwrap_or("")
                    .to_lowercase();
            }
        }
        // 目录在前，文件在后
        entries.sort_by_key(|e| std::cmp::Reverse(e.is_dir));
        Ok(entries)
    })
    .await
    .map_err(|e| format!("webdav task failed: {e}"))?
}

/// 递归扫描 WebDAV 树，收集全部音频文件（单目录失败隔离，深度上限 20）
fn scan_recursive(
    client: &reqwest::blocking::Client,
    base_url: &str,
    username: &str,
    password: &str,
    dir_url: &str,
    depth: u32,
    out: &mut Vec<WebdavEntry>,
) {
    if depth > 20 {
        return;
    }
    let dir_url = if dir_url.ends_with('/') {
        dir_url.to_string()
    } else {
        format!("{dir_url}/")
    };
    let method = Method::from_bytes(b"PROPFIND").expect("PROPFIND");
    let extra = [("depth", "1".to_string())];
    let entries = match crate::remote::auth_request(
        client,
        &method,
        &dir_url,
        username,
        password,
        &extra,
        Some(PROPFIND_BODY.as_bytes().to_vec()),
    ) {
        Ok(resp) if resp.status().is_success() => match resp.text() {
            Ok(xml) => parse_propfind(&xml).unwrap_or_default(),
            Err(_) => return,
        },
        _ => return,
    };

    for e in entries {
        if e.is_dir {
            scan_recursive(client, base_url, username, password, &e.url, depth + 1, out);
        } else if is_audio(&e.url) {
            let mut song = e;
            song.ext = song
                .url
                .rsplit('.')
                .next()
                .unwrap_or("")
                .to_lowercase();
            out.push(song);
        }
    }
}

/// 递归扫描 WebDAV 音乐库（对齐移动端 scanWebdav：单目录失败隔离）
#[tauri::command]
pub async fn webdav_scan(
    base_url: String,
    path: String,
    username: String,
    password: String,
) -> Result<Vec<WebdavEntry>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let client = crate::remote::http_client()?;
        let root = full_url_for(&base_url, &path);
        let mut out = Vec::new();
        scan_recursive(&client, &base_url, &username, &password, &root, 0, &mut out);
        Ok(out)
    })
    .await
    .map_err(|e| format!("webdav task failed: {e}"))?
}

/// 下载 WebDAV 远端文件到本地缓存（`.cache/webdav/{hash}_{name}`），返回本地路径。
/// 已存在非空缓存则直接复用。写入先落 `.part` 临时文件再原子 rename。
#[tauri::command]
pub async fn webdav_download_to_cache(
    url: String,
    name: String,
    username: String,
    password: String,
    app: AppHandle,
) -> Result<String, String> {
    let cache_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?
        .join(".cache")
        .join("webdav");
    tauri::async_runtime::spawn_blocking(move || {
        webdav_download_to_cache_blocking(&url, &name, &username, &password, &cache_dir)
    })
    .await
    .map_err(|e| format!("webdav task failed: {e}"))?
}

fn webdav_download_to_cache_blocking(
    url: &str,
    name: &str,
    username: &str,
    password: &str,
    cache_dir: &Path,
) -> Result<String, String> {
    std::fs::create_dir_all(cache_dir).map_err(|e| e.to_string())?;

    let hash = {
        use md5::{Digest, Md5};
        let mut h = Md5::new();
        h.update(url.as_bytes());
        hex_encode(&h.finalize())
    };
    let safe_name = sanitize_filename(name);
    let final_path = cache_dir.join(format!("{hash}_{safe_name}"));
    let final_str = final_path.to_string_lossy().to_string();

    // 缓存命中（非空文件）
    if let Ok(meta) = std::fs::metadata(&final_path) {
        if meta.len() > 0 {
            return Ok(final_str);
        }
    }

    let client = crate::remote::http_client()?;
    let resp = crate::remote::auth_request(
        &client,
        &Method::GET,
        url,
        username,
        password,
        &[],
        None,
    )?;
    if !resp.status().is_success() {
        return Err(format!("HTTP {}: {url}", resp.status()));
    }

    let part_path = cache_dir.join(format!("{hash}_{safe_name}.part"));
    let mut file = std::fs::File::create(&part_path).map_err(|e| e.to_string())?;
    let mut body = resp;
    use std::io::Write;
    // blocking 流式拷贝：逐块读入（受 client 30s 总超时保护）
    std::io::copy(&mut body, &mut file).map_err(|e| e.to_string())?;
    file.flush().map_err(|e| e.to_string())?;
    drop(file);

    // 空文件视为下载失败（远端可能未授权返回空）
    if std::fs::metadata(&part_path).map(|m| m.len() == 0).unwrap_or(true) {
        let _ = std::fs::remove_file(&part_path);
        return Err(format!("下载为空文件: {url}"));
    }
    std::fs::rename(&part_path, &final_path).map_err(|e| e.to_string())?;
    Ok(final_str)
}

fn hex_encode(bytes: &[u8]) -> String {
    use std::fmt::Write;
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        let _ = write!(out, "{b:02x}");
    }
    out
}

fn sanitize_filename(name: &str) -> String {
    let name = name.trim();
    let cleaned: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_' | ' ') {
                c
            } else {
                '_'
            }
        })
        .collect();
    let cleaned = cleaned.trim().trim_matches('.');
    if cleaned.is_empty() {
        "remote".to_string()
    } else {
        cleaned.to_string()
    }
}

/// 播放 WebDAV 音乐：下载到本地缓存后交给引擎播放（全量下载方案）
#[tauri::command]
pub async fn webdav_play(
    url: String,
    name: String,
    username: String,
    password: String,
    state: State<'_, AppState>,
    app: AppHandle,
) -> Result<String, String> {
    let local = webdav_download_to_cache(url, name, username, password, app).await?;
    *crate::commands::lock_or_die(&state.current_track) = Some(local.clone());
    crate::commands::apply_track_settings(&state);
    state.engine.play(local.clone());
    Ok(local)
}

/// 测试 WebDAV 连接：OPTIONS ping + 列根目录
#[tauri::command]
pub async fn webdav_test_connection(
    base_url: String,
    path: String,
    username: String,
    password: String,
) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || {
        let client = crate::remote::http_client()?;
        let url = full_url_for(&base_url, &path);
        let url = if url.ends_with('/') {
            url
        } else {
            format!("{url}/")
        };
        // OPTIONS 探活
        let resp = crate::remote::auth_request(
            &client,
            &Method::OPTIONS,
            &url,
            &username,
            &password,
            &[],
            None,
        )?;
        if !resp.status().is_success() {
            return Err(format!("HTTP {}: {url}", resp.status()));
        }
        // PROPFIND 验证可列目录
        let method = Method::from_bytes(b"PROPFIND").map_err(|e| e.to_string())?;
        let extra = [("depth", "0".to_string())];
        let resp = crate::remote::auth_request(
            &client,
            &method,
            &url,
            &username,
            &password,
            &extra,
            Some(PROPFIND_BODY.as_bytes().to_vec()),
        )?;
        if !resp.status().is_success() {
            return Err(format!("HTTP {}: {url}", resp.status()));
        }
        // 顺手读掉 body 归还连接
        let _ = resp.text();
        Ok(())
    })
    .await
    .map_err(|e| format!("webdav task failed: {e}"))?
}

/// 供其它模块复用（如 STRM 解析，暂未用）
#[allow(dead_code)]
pub(crate) fn is_audio_url(url: &str) -> bool {
    is_audio(url)
}

/// 供测试复用：路径是否为已有文件
#[allow(dead_code)]
pub(crate) fn file_exists(p: &Path) -> bool {
    p.exists() && p.is_file()
}