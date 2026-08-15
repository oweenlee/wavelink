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

/// 封面/歌词提取单次读取的上限（防服务器忽略 Range 返回全文时拉满整曲）。
const RANGE_READ_CAP: u64 = 4 * 1024 * 1024;

/// 全局复用的 HTTP client：reqwest::Client 线程安全，跨请求复用连接池
/// （keep-alive），避免封面批处理每首歌重复 TLS/TCP 握手。
fn http_client() -> Result<&'static reqwest::Client, String> {
    static CLIENT: once_cell::sync::OnceCell<reqwest::Client> = once_cell::sync::OnceCell::new();
    CLIENT
        .get_or_try_init(|| {
            reqwest::Client::builder()
                .connect_timeout(IO_READ_TIMEOUT)
                .build()
                .map_err(err_str)
        })
}

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

/// 解析 WWW-Authenticate 头参数，返回 key -> value（key 统一小写，value 已去引号）。
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
            let key = part[..eq].trim().to_lowercase();
            let mut val = part[eq + 1..].trim().to_string();
            if val.len() >= 2 && val.starts_with('"') && val.ends_with('"') {
                val = val[1..val.len() - 1].to_string();
            }
            map.insert(key, val);
        }
    }
    map
}

/// 从 WWW-Authenticate 头中截取第一个 `Digest` challenge 段。
/// 服务器可能同时声明多个认证方案（如 `Digest ..., Basic ...`），
/// 若整头直接解析，后方案的 realm/nonce 等参数会覆盖 Digest 的。
/// 按「引号外逗号 + 无 `=` 的 token + 空白」判定 challenge 边界。
fn digest_challenge_section(header: &str) -> &str {
    let lower = header.to_lowercase();
    let start = lower.find("digest").unwrap_or(0);
    let rest = &header[start + "digest".len()..];
    let mut in_quotes = false;
    let mut chars = rest.char_indices().peekable();
    while let Some((i, c)) = chars.next() {
        match c {
            '"' => in_quotes = !in_quotes,
            ',' if !in_quotes => {
                let mut token = String::new();
                while let Some(&(_, cc)) = chars.peek() {
                    if cc.is_whitespace() {
                        // token 后跟空白且不含 `=` → 疑似新 challenge（如 Basic）
                        if !token.is_empty() && !token.contains('=') {
                            return &rest[..i];
                        }
                        break;
                    }
                    token.push(cc);
                    chars.next();
                }
            }
            _ => {}
        }
    }
    rest
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
/// 不响应（TTFB 卡死）导致喂流 task 永久挂起泄漏连接。auth 为认证头值，
/// extra 为附加请求头（如 Range，认证协商重发时一并携带）。
async fn send_get(
    client: &reqwest::Client,
    url: &str,
    auth: Option<&str>,
    extra: &[(&str, String)],
) -> Result<reqwest::Response, String> {
    let mut req = client
        .get(url)
        .header(reqwest::header::ACCEPT_ENCODING, "identity");
    for (k, v) in extra {
        req = req.header(*k, v);
    }
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
/// [extra] 附加请求头在首次/重发/重协商时均携带。
async fn webdav_get(
    client: &reqwest::Client,
    url: &str,
    username: &str,
    password: &str,
    extra: &[(&str, String)],
) -> Result<reqwest::Response, String> {
    let resp = send_get(client, url, None, extra).await?;

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
            let section = digest_challenge_section(&www);
            let params = parse_www_authenticate(section);
            let uri = reqwest::Url::parse(url).map_err(err_str)?.path().to_string();
            build_digest_auth(username, password, &params, "GET", &uri)?
        } else if www_lower.contains("basic") {
            build_basic_auth(username, password)
        } else {
            return Err(format!("未知认证方式: {www}"));
        };

        let resp2 = send_get(client, url, Some(&auth_header), extra).await?;
        if resp2.status() == reqwest::StatusCode::UNAUTHORIZED {
            // stale=true：nonce 过期，用新 nonce 重新协商一次
            let www2 = resp2
                .headers()
                .get("www-authenticate")
                .and_then(|v| v.to_str().ok())
                .unwrap_or("")
                .to_string();
            let section2 = digest_challenge_section(&www2);
            let params2 = parse_www_authenticate(section2);
            let is_stale = params2
                .get("stale")
                .map(|v| v.eq_ignore_ascii_case("true"))
                .unwrap_or(false);
            if is_stale && www2.to_lowercase().contains("digest") {
                let uri = reqwest::Url::parse(url).map_err(err_str)?.path().to_string();
                let auth2 = build_digest_auth(username, password, &params2, "GET", &uri)?;
                let resp3 = send_get(client, url, Some(&auth2), extra).await?;
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
    // .part.stream.<unique> 路径：与 Dart 侧 downloadToLocal 的 ".part" 隔离，
    // 避免 seek 时两个写者（Rust 喂流 / Dart 全量下载）交错误写同一临时
    // 文件导致缓存损坏。unique 随机后缀进一步避免同曲重播时旧喂流 task
    // 的失败清理误删新 task 正在写的临时文件（各 task 只清理自己的）。
    // 双方各自独立写完 rename 成正式缓存（后完成者胜，均为完整内容）。
    let part_path = cache_final_path.map(|p| format!("{p}.part.stream.{}", random_hex(8)));
    let part_path = part_path.as_deref();

    let result: Result<(), String> = async {
        let client = http_client()?;

        let mut resp = webdav_get(&client, url, username, password, &[]).await?;
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

/// 获取远端文件大小（字节）：并发分片下载前置探大小，避免先整文件拉一遍。
/// 用 `Range: bytes=0-0` 探：支持 Range 的服务器返回 206 + Content-Range
/// `bytes 0-0/total`，从头部解析 total；忽略 Range 返回 200 的服务器
/// 则退而取 Content-Length（可能无，此时 Err 由 Dart 回退单连接下载）。
/// 认证协商与流式播放共用。
pub async fn engine_webdav_file_size(
    url: String,
    username: String,
    password: String,
) -> Result<u64, String> {
    let client = http_client()?;
    let extra = vec![(reqwest::header::RANGE.as_str(), "bytes=0-0".to_string())];
    let resp = webdav_get(client, &url, &username, &password, &extra).await?;
    if !resp.status().is_success() {
        return Err(format!("HTTP {}: {url}", resp.status()));
    }
    // 206 Partial Content：解析 Content-Range 的 total
    if resp.status() == reqwest::StatusCode::PARTIAL_CONTENT {
        if let Some(cr) = resp.headers().get(reqwest::header::CONTENT_RANGE) {
            if let Ok(s) = cr.to_str() {
                // 形如 "bytes 0-0/123456" 或 "bytes 0-0/123456/123456"
                if let Some(total) = s.rsplit('/').next() {
                    if let Ok(n) = total.trim().parse::<u64>() {
                        return Ok(n);
                    }
                }
            }
        }
    }
    // 忽略 Range 返回 200：直接取 Content-Length
    resp.content_length().ok_or_else(|| {
        format!("WebDAV 服务器未提供文件大小且不支持 Range: {url}")
    })
}

/// 读取远端文件指定区间 `[offset, offset+max_len)`（并发分片下载原语）。
/// 与流式播放共用认证协商；返回实际读到的字节（可能少于 max_len，
/// 取决于文件大小）。服务器不支持 Range → 报错，Dart 侧回退单连接下载。
pub async fn engine_webdav_download_range(
    url: String,
    username: String,
    password: String,
    offset: u64,
    max_len: u64,
) -> Result<Vec<u8>, String> {
    if max_len == 0 {
        return Ok(Vec::new());
    }
    let client = http_client()?;
    let end = offset + max_len - 1;
    let extra = vec![(reqwest::header::RANGE.as_str(), format!("bytes={offset}-{end}"))];
    let mut resp = webdav_get(client, &url, &username, &password, &extra).await?;
    if !resp.status().is_success() {
        return Err(format!("HTTP {}: {url}", resp.status()));
    }
    if resp.status() != reqwest::StatusCode::PARTIAL_CONTENT {
        return Err(format!(
            "HTTP {}: 服务器不支持 Range，无法并发分片下载: {url}",
            resp.status()
        ));
    }
    let mut buf: Vec<u8> = Vec::with_capacity((max_len.min(512 * 1024)) as usize);
    while (buf.len() as u64) < max_len {
        let chunk = match tokio::time::timeout(IO_READ_TIMEOUT, resp.chunk()).await {
            Ok(Ok(Some(c))) => c,
            Ok(Ok(None)) => break, // 已读尽
            Ok(Err(e)) => return Err(format!("read error: {e}")),
            Err(_) => return Err(format!("read timeout: {url}")),
        };
        buf.extend_from_slice(&chunk);
    }
    Ok(buf)
}

/// 读取远端文件前缀/后缀字节（封面/歌词提取用）。
/// [suffix]=false → GET + `Range: bytes=0-(max_len-1)` 读文件头；
/// [suffix]=true → `Range: bytes=-max_len` 读文件尾（非 faststart 的
/// M4A/ALAC moov 在尾部，头部提取不到元数据时兜底）。
/// 服务器忽略 Range → 200 返回全文：头模式只收取前 max_len 字节即断开
/// （头内容正确，可接受）；尾模式直接 Err（200 拿到的是文件头而非尾，
/// 拼出的"头+尾"是错的，不如明说尾部不可用）。
/// 认证协商与流式播放共用。max_len 上限 RANGE_READ_CAP（防拉满整曲）。
/// 返回读取到的字节（可能少于 max_len，取决于文件大小/服务器 Range 支持）。
pub async fn engine_read_webdav_range(
    url: String,
    username: String,
    password: String,
    max_len: u64,
    suffix: bool,
) -> Result<Vec<u8>, String> {
    let max_len = max_len.min(RANGE_READ_CAP);
    if max_len == 0 {
        return Err("max_len 必须大于 0".to_string());
    }
    let client = http_client()?;
    let range = if suffix {
        format!("bytes=-{max_len}")
    } else {
        format!("bytes=0-{}", max_len - 1)
    };
    let extra = vec![(reqwest::header::RANGE.as_str(), range)];
    let mut resp = webdav_get(client, &url, &username, &password, &extra).await?;
    if !resp.status().is_success() {
        return Err(format!("HTTP {}: {url}", resp.status()));
    }
    // suffix 模式（读文件尾，非 faststart M4A 的 moov 兜底）必须拿到
    // 206 Partial Content：服务器若忽略 Range 返回 200 全文，收的是文件
    // 头而非尾，Dart 侧 [...head, ...tail] 会拼成"头+头"导致兜底静默
    // 失效。明确报错让 Dart 侧知道尾部读取不可用（走整文件兜底/放弃）。
    if suffix && resp.status() != reqwest::StatusCode::PARTIAL_CONTENT {
        return Err(format!(
            "HTTP {}: 服务器不支持 Range，无法读取文件尾 (suffix=true): {url}",
            resp.status()
        ));
    }
    let mut buf: Vec<u8> = Vec::with_capacity((max_len.min(128 * 1024)) as usize);
    while (buf.len() as u64) < max_len {
        let chunk = match tokio::time::timeout(IO_READ_TIMEOUT, resp.chunk()).await {
            Ok(Ok(Some(c))) => c,
            Ok(Ok(None)) => break, // 文件不足 max_len，读完即止
            Ok(Err(e)) => return Err(format!("read error: {e}")),
            Err(_) => return Err(format!("read timeout: {url}")),
        };
        let need = max_len - buf.len() as u64;
        let take = (chunk.len() as u64).min(need) as usize;
        buf.extend_from_slice(&chunk[..take]);
        if take < chunk.len() {
            // 服务器忽略 Range 返回全文：已收够 max_len，主动断开
            break;
        }
    }
    if buf.is_empty() {
        return Err(format!("no data received: {url}"));
    }
    Ok(buf)
}
