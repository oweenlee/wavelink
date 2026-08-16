//! 远程媒体源共享 HTTP 工具：blocking reqwest client + Basic/Digest 认证协商。
//!
//! 移植自 mobile/rust/src/api/webdav.rs 的认证逻辑（RFC 2617），
//! 用 `reqwest::blocking` 适配同步 Tauri command。

use std::collections::HashMap;
use std::time::Duration;

use reqwest::Method;

/// 连接/单次请求超时
pub const IO_TIMEOUT: Duration = Duration::from_secs(10);

fn err_str<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

/// 全局复用 blocking client（线程安全，跨请求复用连接池）
pub fn http_client() -> Result<&'static reqwest::blocking::Client, String> {
    static CLIENT: once_cell::sync::OnceCell<reqwest::blocking::Client> =
        once_cell::sync::OnceCell::new();
    CLIENT
        .get_or_try_init(|| {
            reqwest::blocking::Client::builder()
                .connect_timeout(IO_TIMEOUT)
                .timeout(Duration::from_secs(30))
                .build()
                .map_err(err_str)
        })
}

fn md5_hex(s: &str) -> String {
    use md5::{Digest, Md5};
    let mut h = Md5::new();
    h.update(s.as_bytes());
    base16_encode(&h.finalize())
}

fn base16_encode(bytes: &[u8]) -> String {
    use std::fmt::Write;
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        let _ = write!(out, "{b:02x}");
    }
    out
}

/// 简易伪随机 hex 串（cnonce 用）：时间播种的 LCG
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
        out.push_str(&format!("{seed:x}"));
    }
    out[..len].to_string()
}

/// 解析 WWW-Authenticate 头参数，返回 key -> value（key 小写，value 去引号）
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

/// 截取第一个 Digest challenge 段（避免 Digest 与 Basic 共存时参数污染）
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

/// 生成 Digest 响应头（RFC 2617）
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
    let algorithm = params
        .get("algorithm")
        .cloned()
        .unwrap_or_else(|| "MD5".to_string());

    let cnonce = random_hex(16);
    let nc = "00000001";

    let ha1 = match algorithm.to_uppercase().as_str() {
        "MD5-SESS" => {
            let a1 = md5_hex(&format!("{username}:{realm}:{password}"));
            md5_hex(&format!("{a1}:{nonce}:{cnonce}"))
        }
        _ => md5_hex(&format!("{username}:{realm}:{password}")),
    };
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

/// 发送请求（含认证头），整体包超时
fn send_req(
    client: &reqwest::blocking::Client,
    method: &Method,
    url: &str,
    auth: Option<&str>,
    extra: &[(&str, String)],
    body: Option<Vec<u8>>,
) -> Result<reqwest::blocking::Response, String> {
    let mut req = client
        .request(method.clone(), url)
        .header(reqwest::header::ACCEPT_ENCODING, "identity");
    for (k, v) in extra {
        req = req.header(*k, v);
    }
    if let Some(a) = auth {
        req = req.header(reqwest::header::AUTHORIZATION, a);
    }
    if let Some(b) = body {
        req = req.body(b);
    }
    req.send().map_err(err_str)
}

/// 发起请求并处理 401 认证协商（Digest/Basic，stale=true 时用新 nonce 重协商）
pub fn auth_request(
    client: &reqwest::blocking::Client,
    method: &Method,
    url: &str,
    username: &str,
    password: &str,
    extra: &[(&str, String)],
    body: Option<Vec<u8>>,
) -> Result<reqwest::blocking::Response, String> {
    let resp = send_req(client, method, url, None, extra, body.clone())?;

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

        let m = method.as_str();
        let auth_header = if www_lower.contains("digest") {
            let section = digest_challenge_section(&www);
            let params = parse_www_authenticate(section);
            let uri = reqwest::Url::parse(url).map_err(err_str)?.path().to_string();
            build_digest_auth(username, password, &params, m, &uri)?
        } else if www_lower.contains("basic") {
            build_basic_auth(username, password)
        } else {
            return Err(format!("未知认证方式: {www}"));
        };

        let resp2 = send_req(client, method, url, Some(&auth_header), extra, body.clone())?;
        if resp2.status() == reqwest::StatusCode::UNAUTHORIZED {
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
                let auth2 = build_digest_auth(username, password, &params2, m, &uri)?;
                return send_req(client, method, url, Some(&auth2), extra, body);
            }
            return Err(format!("HTTP 401 认证失败: {url}"));
        }
        return Ok(resp2);
    }
    Ok(resp)
}