//! WebDAV 边下边播（FRB 包装层）
//!
//! 仿 smb.rs 的 engine_play_smb_stream：Rust 侧用 reqwest 以流式
//! GET 拉取 WebDAV 远端字节，逐块喂入 core 解码（首帧即出声），
//! 并行写 `.part` 缓存，读完 rename 成正式缓存（下次播放秒起）。
//! 认证支持 Basic / Digest（Digest 协商移植自 webdav_client 的 auth.dart）。

use std::collections::HashMap;
use std::sync::Arc;

use audio_core::stream::StreamHandle;

/// 读取请求快速失败超时：单块 HTTP 读取 10s 无数据即认为连接异常，
/// 避免死连接挂满。与 smb.rs 的 IO_READ_TIMEOUT 保持一致。
const IO_READ_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

fn err_str<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

fn md5_hex(s: &str) -> String {
    use md5::{Digest, Md5};
    let mut h = Md5::new();
    h.update(s.as_bytes());
    hex::encode(h.finalize())
}

/// 简易伪随机 hex 串（cnonce 用）：时间播种的 LCG，无需引入 rand 依赖
fn random_hex(len: usize) -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let mut seed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let mut out = String::new();
    while out.len() < len {
        seed = seed
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        out.push_str(&format!("{:x}", seed));
    }
    out[..len].to_string()
}

/// 解析 WWW-Authenticate 头参数，返回 key -> value（value 已去引号）。
/// 示例：`Digest realm="x", nonce="y", qop="auth", opaque="z", algorithm=MD5`
fn parse_www_authenticate(header: &str) -> HashMap<String, String> {
    let mut map = HashMap::new();
    let body = header
        .find(char::is_whitespace)
        .map(|i| &header[i + 1..])
        .unwrap_or(header);
    for part in body.split(',') {
        let part = part.trim();
        if let Some(eq) = part.find('=') {
            let key = part[..eq].trim().to_string();
            let mut val = part[eq + 1..].trim().to_string();
            if val.len() >= 2 && val.starts_with('"') && val.ends_with('"') {
                val = val[1..val.len() - 1].to_string();
            }
            map.insert(key, val);
        }
    }
    map
}

/// 生成 Digest 响应头（RFC 2617）。[uri] 为请求路径（URL 的 path 部分）。
fn build_digest_auth(
    username: &str,
    password: &str,
    params: &HashMap<String, String>,
    method: &str,
    uri: &str,
) -> Result<String, String> {
    let realm = params.get("realm").ok_or("digest 缺 realm")?;
    let nonce = params.get("nonce").ok_or("digest 缺 nonce")?;
    let qop = params.get("qop").cloned().unwrap_or_default();
    let opaque = params.get("opaque").cloned().unwrap_or_default();
    let algorithm = params.get("algorithm").cloned().unwrap_or_else(|| "MD5".to_string());

    let cnonce = random_hex(16);
    let nc = "00000001";

    let ha1 = match algorithm.to_uppercase().as_str() {
        "MD5-SESS" => {
            let a1 = md5_hex(&format!("{username}:{realm}:{password}"));
            md5_hex(&format!("{a1}:{nonce}:{cnonce}"))
        }
        _ => md5_hex(&format!("{username}:{realm}:{password}")),
    };
    // GET 无请求体；auth-int 时 entityBody 为空串
    let ha2 = if qop.eq_ignore_ascii_case("auth-int") {
        md5_hex(&format!("{method}:{uri}:{}", md5_hex("")))
    } else {
        md5_hex(&format!("{method}:{uri}"))
    };
    let response = if qop.is_empty() {
        md5_hex(&format!("{ha1}:{nonce}:{ha2}"))
    } else {
        md5_hex(&format!("{ha1}:{nonce}:{nc}:{cnonce}:{qop}:{ha2}"))
    };

    let mut out = format!(
        "Digest username=\"{username}\", realm=\"{realm}\", nonce=\"{nonce}\", uri=\"{uri}\", response=\"{response}\""
    );
    if !qop.is_empty() {
        out.push_str(&format!(", qop={qop}, nc={nc}, cnonce=\"{cnonce}\""));
    }
    if !opaque.is_empty() {
        out.push_str(&format!(", opaque=\"{opaque}\""));
    }
    if !algorithm.is_empty() && !algorithm.eq_ignore_ascii_case("MD5") {
        out.push_str(&format!(", algorithm={algorithm}"));
    }
    Ok(out)
}

fn build_basic_auth(username: &str, password: &str) -> String {
    use base64::Engine;
    let cred = format!("{username}:{password}");
    format!(
        "Basic {}",
        base64::engine::general_purpose::STANDARD.encode(cred)
    )
}

/// 发送 GET 并等待响应头，整体包 IO_READ_TIMEOUT：防服务端 TCP 建连后
/// 不响应（TTFB 卡死）导致喂流 task 永久挂起泄漏连接。auth 为认证头值。
async fn send_get(
    client: &reqwest::Client,
    url: &str,
    auth: Option<&str>,
) -> Result<reqwest::Response, String> {
    let mut req = client
        .get(url)
        .header(reqwest::header::ACCEPT_ENCODING, "identity");
    if let Some(a) = auth {
        req = req.header(reqwest::header::AUTHORIZATION, a);
    }
    tokio::time::timeout(IO_READ_TIMEOUT, req.send())
        .await
        .map_err(|_| format!("HTTP 连接/响应超时: {url}"))?
        .map_err(err_str)
}

/// 发起 GET 并处理认证协商：首次无认证 → 401 时读 www-authenticate →
/// 按 Digest/Basic 构建认证头重发；digest 且 stale=true 时用新 nonce 再协商一次。
async fn webdav_get(
    client: &reqwest::Client,
    url: &str,
    username: &str,
    password: &str,
) -> Result<reqwest::Response, String> {
    let resp = send_get(client, url, None).await?;

    if resp.status() == reqwest::StatusCode::UNAUTHORIZED {
        if username.is_empty() {
            return Err(format!("HTTP 401 未授权（无凭据）: {url}"));
        }
        let www = resp
            .headers()
            .get("www-authenticate")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_string();
        let www_lower = www.to_lowercase();

        let auth_header = if www_lower.contains("digest") {
            let params = parse_www_authenticate(&www);
            let uri = reqwest::Url::parse(url).map_err(err_str)?.path().to_string();
            build_digest_auth(username, password, &params, "GET", &uri)?
        } else if www_lower.contains("basic") {
            build_basic_auth(username, password)
        } else {
            return Err(format!("未知认证方式: {www}"));
        };

        let resp2 = send_get(client, url, Some(&auth_header)).await?;
        if resp2.status() == reqwest::StatusCode::UNAUTHORIZED {
            // stale=true：nonce 过期，用新 nonce 重新协商一次
            let www2 = resp2
                .headers()
                .get("www-authenticate")
                .and_then(|v| v.to_str().ok())
                .unwrap_or("")
                .to_string();
            let params2 = parse_www_authenticate(&www2);
            let is_stale = params2
                .get("stale")
                .map(|v| v.eq_ignore_ascii_case("true"))
                .unwrap_or(false);
            if is_stale && www2.to_lowercase().contains("digest") {
                let uri = reqwest::Url::parse(url).map_err(err_str)?.path().to_string();
                let auth2 = build_digest_auth(username, password, &params2, "GET", &uri)?;
                let resp3 = send_get(client, url, Some(&auth2)).await?;
                return Ok(resp3);
            }
            return Err(format!("HTTP 401 认证失败: {url}"));
        }
        return Ok(resp2);
    }
    Ok(resp)
}

/// 喂流核心：reqwest GET 分块读远端 → 喂 core + 并行写 `.part` 缓存。
/// [first_notify]：第一块成功喂入 core 时触发（变 None），用于主流程同步确认
/// 流已启动（probe 拿到字节 ready 达成）。
async fn feed_webdav_to_core(
    handle: &StreamHandle,
    url: &str,
    username: &str,
    password: &str,
    cache_final_path: Option<&str>,
    first_notify: Option<
        std::sync::Arc<std::sync::Mutex<Option<tokio::sync::oneshot::Sender<Result<(), String>>>>>,
    >,
) -> Result<(), String> {
    // .part.stream 路径：与 Dart 侧 downloadToLocal 的 ".part" 隔离，
    // 避免 seek 时两个写者（Rust 喂流 / Dart 全量下载）交错误写同一临时
    // 文件导致缓存损坏。双方各自独立写完 rename 成正式缓存（后完成者胜，
    // 均为完整内容）；失败清理也只删自己的后缀。
    let part_path = cache_final_path.map(|p| format!("{p}.part.stream"));
    let part_path = part_path.as_deref();

    let result: Result<(), String> = async {
        let client = reqwest::Client::builder()
            .connect_timeout(IO_READ_TIMEOUT)
            .build()
            .map_err(err_str)?;

        let mut resp = webdav_get(&client, url, username, password).await?;
        if !resp.status().is_success() {
            return Err(format!("HTTP {}: {url}", resp.status()));
        }
        let total = resp.content_length(); // None 表示未知（chunked 编码）
        if total == Some(0) {
            return Err(format!("remote file is empty (size 0): {url}"));
        }

        // 并行写 .part 缓存（覆盖式写入，确保干净）
        let mut cache_file = match part_path {
            Some(p) => Some(std::fs::File::create(p).map_err(err_str)?),
            None => None,
        };

        let mut received: u64 = 0;
        loop {
            let chunk = match tokio::time::timeout(IO_READ_TIMEOUT, resp.chunk()).await {
                Ok(Ok(Some(c))) => c,
                Ok(Ok(None)) => break, // 流读尽
                Ok(Err(e)) => return Err(format!("read error: {e}")),
                Err(_) => {
                    return Err(format!("read timeout (10s) at offset {received}: {url}"));
                }
            };
            if chunk.is_empty() {
                return Err(format!("unexpected EOF at offset {received}: {url}"));
            }
            // 喂给 core：流被关闭（切歌/stop）时 write 返回 0，停止拉取
            let written = handle.write(&chunk);
            if written == 0 {
                return Err("流已被关闭（切歌/停止），喂流中止".to_string());
            }
            // 首块喂入成功：通知主流程流已启动（probe 有数据，ready 大概率达成）
            if let Some(ref notify) = first_notify {
                if let Ok(mut guard) = notify.lock() {
                    if let Some(tx) = guard.take() {
                        let _ = tx.send(Ok(()));
                    }
                }
            }
            // 并行写缓存
            if let Some(f) = cache_file.as_mut() {
                use std::io::Write;
                f.write_all(&chunk).map_err(err_str)?;
            }
            received += chunk.len() as u64;
        }

        if received == 0 {
            return Err(format!("no data received (size 0): {url}"));
        }

        // 读尽：通知 EOF 并落缓存（完整读到文件末尾）
        handle.signal_eof();
        if let Some(f) = cache_file.as_mut() {
            use std::io::Write;
            f.flush().map_err(err_str)?;
        }
        drop(cache_file);
        if let Some(part) = part_path {
            if let Some(final_path) = cache_final_path {
                std::fs::rename(part, final_path).map_err(err_str)?;
            }
        }
        Ok(())
    }
    .await;

    // 失败/超时/流被关闭：清理残留 .part
    if result.is_err() {
        if let Some(part) = part_path {
            let _ = std::fs::remove_file(part);
        }
    }
    result
}

/// 启动 WebDAV 边下边播：后台 task 从远端分块拉字节喂入 core 解码
/// （首帧即出声），并行写 `.part` 缓存读完 rename（下次播放秒起）。
/// 认证支持 Basic/Digest。返回 Ok 表示流已启动且**首块已喂入 core**；
/// 失败（连接不可用/流被关）返回 Err，Dart 回退全量下载。
pub async fn engine_play_webdav_stream(
    url: String,
    username: String,
    password: String,
    format_hint: Option<String>,
    cache_final_path: Option<String>,
) -> Result<(), String> {
    let handle = crate::api::engine::engine_start_stream(format_hint, None)?;
    // 首块喂流成功信号：喂流 task 写入第一块后通知，主函数据此确认流已启动
    let (first_tx, first_rx) = tokio::sync::oneshot::channel::<Result<(), String>>();
    let first_tx = Arc::new(std::sync::Mutex::new(Some(first_tx)));
    // spawn 后台喂流 task：reqwest 拉远端 → 喂 core + 写缓存
    tokio::spawn(async move {
        let result = feed_webdav_to_core(
            &handle,
            &url,
            &username,
            &password,
            cache_final_path.as_deref(),
            Some(Arc::clone(&first_tx)),
        )
        .await;
        if let Ok(mut guard) = first_tx.lock() {
            if let Some(tx) = guard.take() {
                let _ = tx.send(result);
                return;
            }
        }
        // 走到这里说明首块已成功（sender 已被 consume）：
        // 若此时失败 = 播放中途断流，主动注入 error 事件让 Dart 兜底回退；
        // 若 Ok = 正常播完/切歌关流，无需通知。
        if let Err(e) = result {
            let msg = format!("WebDAV 流播放中断: {e}");
            eprintln!("[WebDAV] 喂流失败(后台): {e}");
            crate::api::engine::engine_notify_stream_error(msg);
        }
    });
    // 同步等首块喂流结果（probe 有数据 → ready 达成），最多等 IO_READ_TIMEOUT
    match tokio::time::timeout(IO_READ_TIMEOUT, first_rx).await {
        Ok(Ok(Ok(()))) => Ok(()),
        Ok(Ok(Err(e))) => Err(format!("首块喂流失败: {e}")),
        Ok(Err(_)) => Err("喂流 task 未返回结果".to_string()),
        Err(_) => Err("等待首块喂流超时".to_string()),
    }
}
