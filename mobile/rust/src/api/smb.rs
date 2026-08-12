//! SMB 客户端（FRB 包装层）
//!
//! 基于纯 Rust `smb2` crate 实现，替代原 smb_connect Dart 包。
//! 空 username/password 即 guest（匿名）认证，macOS 共享可直接访问。
//! 连接与会话保存在全局状态中，Dart 侧只需面向"共享目录路径"操作。

use smb2::client::{DirectoryEntry, SmbClient, Tree};
use smb2::rpc::srvsvc::ShareInfo;
use smb2::ClientConfig;
use tokio::sync::{Mutex, Semaphore};

use crate::frb_generated::StreamSink;

/// 读取连接池大小：多条独立 SMB 连接并行下载，打满 Wi-Fi 带宽
const READ_POOL_SIZE: usize = 8;

/// 池并发信号量上限：池容量 + 2 预留位。封面批量提取（8 并发）
/// 占满池连接时，播放下载/单曲读取仍能拿到临时连接，不被排队堵死
const POOL_SEM_PERMITS: usize = READ_POOL_SIZE + 2;

/// 保活单条探测超时：死连接上的 fs_info 会挂满 crate 硬编码的
/// 30s RESPONSE_TIMEOUT，包一层 5s 超时快速判死，避免保活 tick 被拖死
const KEEPALIVE_PROBE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

/// 读取请求快速失败超时：保活只能探测池中空闲连接，借出在用的
/// 探不到——恰好踩到死连接的请求仍会挂满 crate 硬编码 30s。
/// 包一层 10s 超时把白等压缩到三分之一，超时连接丢弃不回池
/// （避免残留响应污染后续请求），Dart 侧重试链路重建后重试。
const IO_READ_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// 一次 SMB 会话：底层连接 + 已挂载的共享（tree）
struct SmbSession {
    client: SmbClient,
    tree: Option<Tree>,
}

/// 连接参数（用于创建池连接）
#[derive(Clone)]
struct ConnectParams {
    addr: String,
    username: String,
    password: String,
    domain: String,
}

impl ConnectParams {
    fn to_config(&self) -> ClientConfig {
        ClientConfig {
            addr: self.addr.clone(),
            timeout: std::time::Duration::from_secs(10),
            username: self.username.clone(),
            password: self.password.clone(),
            domain: self.domain.clone(),
            auto_reconnect: true,
            compression: true,
            dfs_enabled: true,
            dfs_target_overrides: std::collections::HashMap::new(),
        }
    }
}

/// 全局会话（控制操作：list_shares / list_directory 等），跨 await 用 tokio Mutex
static SESSION: Mutex<Option<SmbSession>> = Mutex::const_new(None);
/// 连接参数（建池用）
static PARAMS: Mutex<Option<ConnectParams>> = Mutex::const_new(None);
/// 读取连接池（smb_read_file 专用，与主会话隔离）
static POOL: Mutex<Vec<SmbSession>> = Mutex::const_new(Vec::new());
/// 池并发信号量（限制同时借出的连接数）
static POOL_SEM: Semaphore = Semaphore::const_new(POOL_SEM_PERMITS);

/// 共享信息（list_shares 用）
#[derive(Debug)]
pub struct SmbShareInfo {
    pub name: String,
    pub comment: String,
}

/// 目录条目（list_directory 用）
#[derive(Debug)]
pub struct SmbDirEntry {
    pub name: String,
    pub size: u64,
    pub is_dir: bool,
}

fn err_str<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

/// 池连接自愈挂载：池连接 tree 缺失时（重建后尚未挂载/初次挂载
/// 失败）就地挂载当前共享，避免直接报 "no share connected" 导致
/// 并发任务雪崩式失败后反复重连。
async fn ensure_pooled_tree(sess: &mut SmbSession) {
    if sess.tree.is_some() {
        return;
    }
    let share = SESSION
        .lock()
        .await
        .as_ref()
        .and_then(|s| s.tree.as_ref().map(|t| t.share_name.clone()));
    if let Some(share) = share {
        if let Ok(t) = sess.client.connect_share(&share).await {
            sess.tree = Some(t);
        }
    }
}

/// 连接 SMB 服务器（host 为裸 IP/域名，内部拼 :port）
pub async fn smb_connect(
    host: String,
    port: u16,
    username: String,
    password: String,
    domain: String,
) -> Result<(), String> {
    let addr = format!("{host}:{port}");
    let params = ConnectParams {
        addr,
        username,
        password,
        domain,
    };
    let client = SmbClient::connect(params.to_config()).await.map_err(err_str)?;

    let mut guard = SESSION.lock().await;
    *guard = Some(SmbSession { client, tree: None });
    drop(guard);

    // 建立读取连接池（单条失败不影响整体，池为空时 read 回退主会话）
    *PARAMS.lock().await = Some(ConnectParams {
        addr: params.addr.clone(),
        username: params.username.clone(),
        password: params.password.clone(),
        domain: params.domain.clone(),
    });
    let mut pool = Vec::new();
    for _ in 0..READ_POOL_SIZE {
        if let Ok(c) = SmbClient::connect(params.to_config()).await {
            pool.push(SmbSession { client: c, tree: None });
        }
    }
    *POOL.lock().await = pool;
    Ok(())
}

/// 前台保活：对主会话 + 读取池每条连接发一次 fs_info，返回是否全部健康。
///
/// smb2 crate 的 keepalive 只探测「有请求在途但线路静默」的连接，
/// 完全空闲的连接从不被探测；而多数 NAS 会话空闲超时（常见几分钟）
/// 会在前台闲置时悄悄回收连接，下次真实 IO 踩到死连接只能
/// 白等 crate 硬编码的 30s RESPONSE_TIMEOUT 才判死。故由 Dart 侧
/// 每隔一段时间主动调本函数，让每条连接保持活跃、NAS 不回收。
/// fs_info 是只读轻量请求，语义与 reviver 可重放的读操作一致。
///
/// 返回 false：任一连接探活失败（含 5s 超时）——Dart 侧据此 force
/// 重建会话。早期版本用 let _ = 吞错导致探活永远"成功"，死连接
/// 无人清理、真实 IO 反复白等 30s（封面批量提取连环超时的根因）。
pub async fn smb_keepalive() -> bool {
    let mut healthy = true;
    // 主会话
    if let Ok(mut guard) = SESSION.try_lock() {
        if let Some(sess) = guard.as_mut() {
            if let Some(tree) = sess.tree.as_mut() {
                let probe = tokio::time::timeout(
                    KEEPALIVE_PROBE_TIMEOUT,
                    sess.client.fs_info(tree),
                )
                .await;
                if matches!(probe, Err(_) | Ok(Err(_))) {
                    healthy = false;
                }
            }
        }
    }
    // 读取池每条连接（就地逐个探测，不弹池，避免与并发读取抢连接）
    if let Ok(mut pool) = POOL.try_lock() {
        for s in pool.iter_mut() {
            if let Some(tree) = s.tree.as_mut() {
                let probe = tokio::time::timeout(
                    KEEPALIVE_PROBE_TIMEOUT,
                    s.client.fs_info(tree),
                )
                .await;
                if matches!(probe, Err(_) | Ok(Err(_))) {
                    healthy = false;
                }
            }
        }
    }
    healthy
}

/// 断开 SMB 连接（含读取池）
pub async fn smb_disconnect() {
    let mut guard = SESSION.lock().await;
    *guard = None;
    *POOL.lock().await = Vec::new();
    *PARAMS.lock().await = None;
}

/// 列出服务器所有共享
pub async fn smb_list_shares() -> Result<Vec<SmbShareInfo>, String> {
    let mut guard = SESSION.lock().await;
    let sess = guard.as_mut().ok_or("not connected")?;
    let shares: Vec<ShareInfo> = sess
        .client
        .list_shares()
        .await
        .map_err(err_str)?;
    Ok(shares
        .into_iter()
        .map(|s| SmbShareInfo {
            name: s.name,
            comment: s.comment,
        })
        .collect())
}

/// 挂载指定共享（后续 list/read 均相对该共享根目录）
///
/// 同时在读取池的每条连接上挂载，保证并行下载可用。
pub async fn smb_connect_share(share_name: String) -> Result<(), String> {
    let mut guard = SESSION.lock().await;
    let sess = guard.as_mut().ok_or("not connected")?;
    let tree = sess.client.connect_share(&share_name).await.map_err(err_str)?;
    sess.tree = Some(tree);
    drop(guard);

    let mut pool = POOL.lock().await;
    for s in pool.iter_mut() {
        if let Ok(t) = s.client.connect_share(&share_name).await {
            s.tree = Some(t);
        }
    }
    Ok(())
}

/// 列出目录内容；path 空串表示共享根目录，子路径如 "Music/Album"
///
/// 过滤 "."/".." 条目：smb2 crate 会返回它们，
/// 递归扫描时若不剔除会无限进入 "." 导致路径爆炸。
/// 优先从读取池借独立连接，使多个目录可并行列出（避免主会话串行排队）；
/// 池空时回退主会话。
pub async fn smb_list_directory(path: String) -> Result<Vec<SmbDirEntry>, String> {
    let permit = POOL_SEM.acquire().await.map_err(err_str)?;
    let pooled = POOL.lock().await.pop();
    let entries: Vec<DirectoryEntry> = match pooled {
        Some(mut sess) => {
            ensure_pooled_tree(&mut sess).await;
            let r = if let Some(tree) = sess.tree.as_mut() {
                sess.client.list_directory(tree, &path).await.map_err(err_str)
            } else {
                Err("no share connected".to_string())
            };
            POOL.lock().await.push(sess);
            r
        }
        None => {
            let mut guard = SESSION.lock().await;
            let sess = guard.as_mut().ok_or("not connected")?;
            let tree = sess.tree.as_mut().ok_or("no share connected")?;
            sess.client.list_directory(tree, &path).await.map_err(err_str)
        }
    }?;
    drop(permit);
    Ok(entries
        .into_iter()
        .filter(|e| e.name != "." && e.name != "..")
        .map(|e| SmbDirEntry {
            name: e.name,
            size: e.size,
            is_dir: e.is_directory,
        })
        .collect())
}

/// 读取远端文件完整内容（相对共享根目录的路径）
///
/// 用 read_file_pipelined 而非 read_file：后者单次读取上限 65536 字节，
/// 大于该值的文件（几乎所有音频）会报错。
/// 优先从读取池借独立连接（并行下载），池空时回退主会话。
pub async fn smb_read_file(path: String) -> Result<Vec<u8>, String> {
    let permit = POOL_SEM.acquire().await.map_err(err_str)?;
    let pooled = POOL.lock().await.pop();
    let result = match pooled {
        Some(mut sess) => {
            ensure_pooled_tree(&mut sess).await;
            let r = if let Some(tree) = sess.tree.as_mut() {
                match tokio::time::timeout(
                    IO_READ_TIMEOUT,
                    sess.client.read_file_pipelined(tree, &path),
                )
                .await
                {
                    Ok(r) => r.map_err(err_str),
                    Err(_) => Err("response timeout (10s)".to_string()),
                }
            } else {
                Err("no share connected".to_string())
            };
            // 成功才回池：失败/超时的连接可能已死，丢弃避免污染后续请求
            if r.is_ok() {
                POOL.lock().await.push(sess);
            }
            r
        }
        None => {
            let mut guard = SESSION.lock().await;
            let sess = guard.as_mut().ok_or("not connected")?;
            let tree = sess.tree.as_mut().ok_or("no share connected")?;
            match tokio::time::timeout(
                IO_READ_TIMEOUT,
                sess.client.read_file_pipelined(tree, &path),
            )
            .await
            {
                Ok(r) => r.map_err(err_str),
                Err(_) => Err("response timeout (10s)".to_string()),
            }
        }
    };
    drop(permit);
    result
}

/// 流式读取远端文件（相对共享根目录的路径），分块经 FRB sink 推给 Dart。
///
/// 会话在流存活期间独占（不回池）：FileReader 与池会话共享同一条
/// 连接，若提前归还，后续任务会在同一链路上发并发请求（连接多路
/// 复用），部分 NAS 固件无法处理，READ 返回空数据/Protocol error，
/// 表现为下载得到 0 字节。独占后每路流一条独立链路，互不干扰；
/// 并发上限仍由 POOL_SEM 控制。每块 512KB 推送一次，Dart 端逐块
/// 追加写入，避免整文件跨 FFI 一次性拷贝。
pub async fn smb_read_file_stream(
    path: String,
    sink: StreamSink<Vec<u8>>,
) -> Result<(), String> {
    let permit = POOL_SEM.acquire().await.map_err(err_str)?;
    // from_pool：池连接用完归还；临时新建的用完 drop 关闭，不进池
    let (mut sess, from_pool) = match POOL.lock().await.pop() {
        Some(s) => (s, true),
        None => {
            // 池空：新建独立连接并挂载当前共享
            let params = PARAMS.lock().await.clone().ok_or("not connected")?;
            let share = SESSION
                .lock()
                .await
                .as_ref()
                .and_then(|s| s.tree.as_ref().map(|t| t.share_name.clone()))
                .ok_or("no share connected")?;
            let mut client = SmbClient::connect(params.to_config()).await.map_err(err_str)?;
            let tree = client.connect_share(&share).await.map_err(err_str)?;
            (SmbSession { client, tree: Some(tree) }, false)
        }
    };
    ensure_pooled_tree(&mut sess).await;

    let result: Result<(), String> = async {
        let tree = sess.tree.as_ref().ok_or("no share connected")?;
        // open 阶段包超时：死连接上 CREATE 会挂满 crate 30s，
        // 10s 快速失败让播放下载的 Dart 重试链路尽早重建。
        // （后续分块读暂不逐块包超时，避免大文件误杀）
        let reader = match tokio::time::timeout(
            IO_READ_TIMEOUT,
            sess.client.open_file_reader(tree, &path),
        )
        .await
        {
            Ok(r) => r.map_err(err_str)?,
            Err(_) => return Err("open timeout (10s)".to_string()),
        };
        let total = reader.size();
        if total == 0 {
            // 空流（CREATE 返回 EndOfFile=0）：明确报错而非静默成功，
            // 避免 Dart 侧得到空缓存文件
            let _ = reader.close().await;
            return Err(format!("remote file is empty (size 0): {path}"));
        }
        let mut offset = 0u64;
        const CHUNK: u64 = 512 * 1024;
        while offset < total {
            let data = reader.read_at(offset, CHUNK).await.map_err(err_str)?;
            let n = data.len() as u64;
            if n == 0 {
                return Err(format!("unexpected EOF at offset {offset}/{total}: {path}"));
            }
            sink.add(data).map_err(|e| e.to_string())?;
            offset += n;
        }
        // 显式关闭句柄释放服务端资源（直接 drop 会泄漏句柄）
        let _ = reader.close().await;
        Ok(())
    }
    .await;

    // 流结束才归还会话，保证独占；失败/超时的连接丢弃不回池
    if from_pool && result.is_ok() {
        POOL.lock().await.push(sess);
    }
    drop(permit);
    result
}

/// 读远端文件头部（最多 [max_len] 字节）：封面提取/格式探测用，避免整文件下载。
/// 会话在读完前独占（不回池）：与 smb_read_file_stream 同理，提前归还
/// 会让后续任务在同一连接上发并发请求，部分 NAS 无法处理。
pub async fn smb_read_head(path: String, max_len: u64) -> Result<Vec<u8>, String> {
    let permit = POOL_SEM.acquire().await.map_err(err_str)?;
    // from_pool：池连接读完归还；临时新建的用完 drop 关闭，不进池
    let (mut sess, from_pool) = match POOL.lock().await.pop() {
        Some(s) => (s, true),
        None => {
            // 池空：新建独立连接并挂载当前共享（避免与主会话并发冲突）
            let params = PARAMS.lock().await.clone().ok_or("not connected")?;
            let share = SESSION
                .lock()
                .await
                .as_ref()
                .and_then(|s| s.tree.as_ref().map(|t| t.share_name.clone()))
                .ok_or("no share connected")?;
            let mut client = SmbClient::connect(params.to_config()).await.map_err(err_str)?;
            let tree = client.connect_share(&share).await.map_err(err_str)?;
            (SmbSession { client, tree: Some(tree) }, false)
        }
    };
    ensure_pooled_tree(&mut sess).await;

    let result: Result<Vec<u8>, String> = async {
        let tree = sess.tree.as_ref().ok_or("no share connected")?;
        // 全程包超时：封面批量提取踩到死连接时 10s 快速失败，
        // 不再白等 crate 硬编码的 30s（此前 6 个任务各等满 30s）
        match tokio::time::timeout(IO_READ_TIMEOUT, async {
            let reader = sess.client.open_file_reader(tree, &path).await.map_err(err_str)?;
            let data = reader.read_at(0, max_len).await.map_err(err_str)?;
            // 显式关闭句柄释放服务端资源（直接 drop 会泄漏句柄）
            let _ = reader.close().await;
            Ok::<Vec<u8>, String>(data)
        })
        .await
        {
            Ok(r) => r,
            Err(_) => Err("response timeout (10s)".to_string()),
        }
    }
    .await;

    // 读完才归还，保证独占；失败/超时的连接丢弃不回池
    if from_pool && result.is_ok() {
        POOL.lock().await.push(sess);
    }
    drop(permit);
    result
}

/// 远端文件大小（扫描时判断是否有变化，避免重复下载）
pub async fn smb_file_size(path: String) -> Result<u64, String> {
    let mut guard = SESSION.lock().await;
    let sess = guard.as_mut().ok_or("not connected")?;
    let tree = sess.tree.as_mut().ok_or("no share connected")?;
    let entries: Vec<DirectoryEntry> = sess
        .client
        .list_directory(tree, &path)
        .await
        .map_err(err_str)?;
    entries
        .into_iter()
        .find(|e| !e.is_directory)
        .map(|e| e.size)
        .ok_or_else(|| "file not found".to_string())
}
