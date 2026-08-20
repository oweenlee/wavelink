//! SMB 客户端（FRB 包装层）
//!
//! 基于纯 Rust `smb2` crate 实现，替代原 smb_connect Dart 包。
//! 空 username/password 即 guest（匿名）认证，macOS 共享可直接访问。
//! 连接与会话保存在全局状态中，Dart 侧只需面向"共享目录路径"操作。

use smb2::client::{DirectoryEntry, SmbClient, Tree};
use smb2::rpc::srvsvc::ShareInfo;
use smb2::ClientConfig;
use tokio::sync::{Mutex, Semaphore};

use audio_core::stream::StreamHandle;
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

/// 带超时建立 SMB 连接：死 NAS/连接数打满时快速失败（10s），
/// 避免无超时包裹白挂（smb2 crate 内部超时 + auto_reconnect 可叠到 30s+）。
async fn connect_with_timeout(params: &ConnectParams) -> Result<SmbClient, String> {
    tokio::time::timeout(IO_READ_TIMEOUT, SmbClient::connect(params.to_config()))
        .await
        .map_err(|_| "connect timeout (10s)".to_string())?
        .map_err(err_str)
}

/// 带超时挂载共享：同上，connect_share 在死连接/NAS 拒绝时同样会挂。
async fn connect_share_with_timeout(
    client: &mut SmbClient,
    share: &str,
) -> Result<Tree, String> {
    tokio::time::timeout(IO_READ_TIMEOUT, client.connect_share(share))
        .await
        .map_err(|_| "connect_share timeout (10s)".to_string())?
        .map_err(err_str)
}

/// 带超时获取池 permit：池被挂起任务占满时快速失败，由 Dart 重试链路
/// 接管，而不是无限等待（历史事故：下载任务挂在 acquire 上 30s+）。
async fn acquire_pool_permit() -> Result<tokio::sync::SemaphorePermit<'static>, String> {
    tokio::time::timeout(IO_READ_TIMEOUT, POOL_SEM.acquire())
        .await
        .map_err(|_| "acquire pool permit timeout (10s)".to_string())?
        .map_err(err_str)
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
        if let Ok(t) = connect_share_with_timeout(&mut sess.client, &share).await {
            sess.tree = Some(t);
        }
    }
}

/// 连接 SMB 服务器（host 为裸 IP/域名，内部拼 :port）#[frb]
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
    let client = connect_with_timeout(&params).await?;

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
    // 并发建池：死 NAS 上串行建 8 条连接最坏 8×10s（历史事故：
    // 播放下载挂 30s+ 的元凶之一），并发 + 单条 5s 超时压到 ~5s。
    // 池是优化项而非必需：失败连接跳过即可，池空时读操作回退主会话。
    const POOL_CONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);
    let mut handles = Vec::new();
    for _ in 0..READ_POOL_SIZE {
        let params = params.clone();
        handles.push(tokio::spawn(async move {
            tokio::time::timeout(POOL_CONNECT_TIMEOUT, SmbClient::connect(params.to_config()))
                .await
        }));
    }
    let mut pool = Vec::new();
    for h in handles {
        if let Ok(Ok(Ok(c))) = h.await {
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
/// 无人清理、真实 IO 反复白等 30s（封面批量提取连环超时的根因）。#[frb]
pub async fn smb_keepalive() -> bool {
    let mut healthy = true;

    // 主会话：try_lock 成功则持锁探测（不取出）。
    // 取出会让并发读取在窗口内看到 SESSION=None 而报 "not connected"
    //（扫描/播放恰逢保活时静默失败，列表空白且无提示——实测回归）。
    // 持锁探测最坏阻塞 5s，但只延迟不失败，可接受。
    if let Ok(mut guard) = SESSION.try_lock() {
        if let Some(sess) = guard.as_mut() {
            match sess.tree.as_mut() {
                Some(tree) => {
                    let probe = tokio::time::timeout(
                        KEEPALIVE_PROBE_TIMEOUT,
                        sess.client.fs_info(tree),
                    )
                    .await;
                    if matches!(probe, Err(_) | Ok(Err(_))) {
                        healthy = false;
                    }
                }
                None => {
                    // 会话存在但共享未挂载：Dart 侧乐观缓存 _connected/_mountedShare
                    // 与 Rust 实际状态脱节（重建中断/并发 force 竞争导致 tree 丢失，
                    // 真实 IO 报 "no share connected"）。探活不覆盖此状态，
                    // 判不健康让 Dart force 重建恢复挂载（历史事故：死会话
                    // 因探活空转永远不重建，播放/封面连环超时）。
                    healthy = false;
                }
            }
        }
    }

    // 读取池：整池取出后逐条探测，避免跨 await 持 POOL 锁（8 条死连接最坏 40s）
    // 阻塞所有并发读取取连接（播放喂流/分片下载/封面提取连环超时的同构根因）。
    // 池空对并发读取无害（读取会新建临时连接），且探测完成后 extend 合并
    // 而非覆盖，保留探测期间其他任务归还/新建的连接。
    let mut taken_pool = match POOL.try_lock() {
        Ok(mut pool) => std::mem::take(&mut *pool),
        Err(_) => Vec::new(),
    };
    for s in taken_pool.iter_mut() {
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
    if !taken_pool.is_empty() {
        let mut guard = POOL.lock().await;
        guard.extend(taken_pool);
    }

    healthy
}

/// 断开 SMB 连接（含读取池）#[frb]
pub async fn smb_disconnect() {
    let mut guard = SESSION.lock().await;
    *guard = None;
    *POOL.lock().await = Vec::new();
    *PARAMS.lock().await = None;
}

/// 列出服务器所有共享#[frb]
pub async fn smb_list_shares() -> Result<Vec<SmbShareInfo>, String> {
    let mut guard = SESSION.lock().await;
    let sess = guard.as_mut().ok_or("not connected")?;
    let shares: Vec<ShareInfo> =
        match tokio::time::timeout(IO_READ_TIMEOUT, sess.client.list_shares()).await {
            Ok(r) => r.map_err(err_str)?,
            Err(_) => return Err("response timeout (10s)".to_string()),
        };
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
/// 同时在读取池的每条连接上挂载，保证并行下载可用。#[frb]
pub async fn smb_connect_share(share_name: String) -> Result<(), String> {
    // 主会话挂载：失败则清空旧 tree，避免残留上一个 share 的挂载
    // （切盘后仍读到旧 share / not found）。
    {
        let mut guard = SESSION.lock().await;
        let sess = guard.as_mut().ok_or("not connected")?;
        match connect_share_with_timeout(&mut sess.client, &share_name).await {
            Ok(tree) => sess.tree = Some(tree),
            Err(e) => {
                sess.tree = None;
                return Err(e);
            }
        }
    }

    // 读取池逐条挂载：取走 Vec 在锁外 await，避免持 POOL 锁跨多连接超时
    // （8×10s）阻塞所有池 I/O；单条失败清空其 tree，不残留旧 share。
    let mut pool = std::mem::take(&mut *POOL.lock().await);
    for s in pool.iter_mut() {
        match connect_share_with_timeout(&mut s.client, &share_name).await {
            Ok(t) => s.tree = Some(t),
            Err(_) => s.tree = None,
        }
    }
    *POOL.lock().await = pool;
    Ok(())
}

/// 列出目录内容；path 空串表示共享根目录，子路径如 "Music/Album"
///
/// 过滤 "."/".." 条目：smb2 crate 会返回它们，
/// 递归扫描时若不剔除会无限进入 "." 导致路径爆炸。
/// 优先从读取池借独立连接，使多个目录可并行列出（避免主会话串行排队）；
/// 池空时回退主会话。#[frb]
pub async fn smb_list_directory(path: String) -> Result<Vec<SmbDirEntry>, String> {
    let permit = acquire_pool_permit().await?;
    let pooled = POOL.lock().await.pop();
    let entries: Vec<DirectoryEntry> = match pooled {
        Some(mut sess) => {
            ensure_pooled_tree(&mut sess).await;
            let r = if let Some(tree) = sess.tree.as_mut() {
                tokio::time::timeout(IO_READ_TIMEOUT, sess.client.list_directory(tree, &path))
                    .await
                    .map_err(|_| "list_directory timeout (10s)".to_string())?
                    .map_err(err_str)
            } else {
                Err("no share connected".to_string())
            };
            // 仅成功回池；失败（超时/死连接）丢弃，避免污染后续请求
            if r.is_ok() {
                POOL.lock().await.push(sess);
            }
            r
        }
        None => {
            let mut guard = SESSION.lock().await;
            let sess = guard.as_mut().ok_or("not connected")?;
            let tree = sess.tree.as_mut().ok_or("no share connected")?;
            tokio::time::timeout(IO_READ_TIMEOUT, sess.client.list_directory(tree, &path))
                .await
                .map_err(|_| "list_directory timeout (10s)".to_string())?
                .map_err(err_str)
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
/// 优先从读取池借独立连接（并行下载），池空时回退主会话。#[frb]
pub async fn smb_read_file(path: String) -> Result<Vec<u8>, String> {
    let permit = acquire_pool_permit().await?;
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
/// 追加写入，避免整文件跨 FFI 一次性拷贝。#[frb]
pub async fn smb_read_file_stream(
    path: String,
    sink: StreamSink<Vec<u8>>,
) -> Result<(), String> {
    let permit = acquire_pool_permit().await?;
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
            let mut client = connect_with_timeout(&params).await?;
            let tree = connect_share_with_timeout(&mut client, &share).await?;
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
            // 分块读也包超时：死连接上 READ 同样挂满 crate 30s（open 阶段
            // 的 10s 只挡住了建句柄，读第一块时连接可能刚被回收）。逐块
            // 10s 快速失败，让 Dart 重试链路尽早重建，不白等 30s。
            let data = match tokio::time::timeout(
                IO_READ_TIMEOUT,
                reader.read_at(offset, CHUNK),
            )
            .await
            {
                Ok(d) => d.map_err(err_str)?,
                Err(_) => {
                    let _ = reader.close().await;
                    return Err(format!(
                        "read timeout (10s) at offset {offset}/{total}: {path}"
                    ));
                }
            };
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
pub async fn smb_read_tail(path: String, max_len: u64) -> Result<Vec<u8>, String> {
    let permit = acquire_pool_permit().await?;
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
            let mut client = connect_with_timeout(&params).await?;
            let tree = connect_share_with_timeout(&mut client, &share).await?;
            (SmbSession { client, tree: Some(tree) }, false)
        }
    };
    ensure_pooled_tree(&mut sess).await;

    let result: Result<Vec<u8>, String> = async {
        let tree = sess.tree.as_ref().ok_or("no share connected")?;
        // 全程包超时：与 smb_read_head 一致，死连接 10s 快速失败
        match tokio::time::timeout(IO_READ_TIMEOUT, async {
            let reader = sess.client.open_file_reader(tree, &path).await.map_err(err_str)?;
            let size = reader.size();
            let offset = size.saturating_sub(max_len);
            let data = reader.read_at(offset, max_len).await.map_err(err_str)?;
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

/// 读远端文件头部（最多 [max_len] 字节）：封面提取/格式探测用，避免整文件下载。
/// 会话在读完前独占（不回池）：与 smb_read_file_stream 同理，提前归还
/// 会让后续任务在同一连接上发并发请求，部分 NAS 无法处理。#[frb]
pub async fn smb_read_head(path: String, max_len: u64) -> Result<Vec<u8>, String> {
    let permit = acquire_pool_permit().await?;
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
            let mut client = connect_with_timeout(&params).await?;
            let tree = connect_share_with_timeout(&mut client, &share).await?;
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

/// 读远端文件指定区间 `[offset, offset+max_len)`（相对共享根目录的路径）。
/// 并发分片下载原语：Dart 侧把整曲切成多片并行调用，各片独立连接读取，
/// 打满 NAS 带宽（单连接顺序读受单会话吞吐限制）。
/// 会话在读完前独占（不回池）：与 smb_read_head 同理，避免同连接并发请求。
/// 返回实际读到的字节（可能少于 max_len，取决于文件大小/读池状态）。#[frb]
pub async fn smb_read_file_range(
    path: String,
    offset: u64,
    max_len: u64,
) -> Result<Vec<u8>, String> {
    let permit = acquire_pool_permit().await?;
    let (mut sess, from_pool) = match POOL.lock().await.pop() {
        Some(s) => (s, true),
        None => {
            let params = PARAMS.lock().await.clone().ok_or("not connected")?;
            let share = SESSION
                .lock()
                .await
                .as_ref()
                .and_then(|s| s.tree.as_ref().map(|t| t.share_name.clone()))
                .ok_or("no share connected")?;
            let mut client = connect_with_timeout(&params).await?;
            let tree = connect_share_with_timeout(&mut client, &share).await?;
            (SmbSession { client, tree: Some(tree) }, false)
        }
    };
    ensure_pooled_tree(&mut sess).await;

    let result: Result<Vec<u8>, String> = async {
        let tree = sess.tree.as_ref().ok_or("no share connected")?;
        match tokio::time::timeout(IO_READ_TIMEOUT, async {
            let reader = sess.client.open_file_reader(tree, &path).await.map_err(err_str)?;
            let data = reader.read_at(offset, max_len).await.map_err(err_str)?;
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

    if from_pool && result.is_ok() {
        POOL.lock().await.push(sess);
    }
    drop(permit);
    result
}

/// 远端文件大小（下载完整性校验用）#[frb]
pub async fn smb_file_size(path: String) -> Result<u64, String> {
    let mut guard = SESSION.lock().await;
    let sess = guard.as_mut().ok_or("not connected")?;
    let tree = sess.tree.as_mut().ok_or("no share connected")?;
    let entries: Vec<DirectoryEntry> = match tokio::time::timeout(
        IO_READ_TIMEOUT,
        sess.client.list_directory(tree, &path),
    )
    .await
    {
        Ok(r) => r.map_err(err_str)?,
        Err(_) => return Err("response timeout (10s)".to_string()),
    };
    entries
        .into_iter()
        .find(|e| !e.is_directory)
        .map(|e| e.size)
        .ok_or_else(|| "file not found".to_string())
}

/// 边下边播：SMB 远端文件 → core 流式解码（首帧即出声）＋并行写本地缓存。
///
/// 流程：启动 core `play_stream` 拿到 StreamHandle → spawn 后台喂流 task，
/// 独占一条池连接从远端读 512KB 分块，每块 `handle.write` 喂给 core 解码
/// （同时追加写 `.smb_cache/*.part`），读尽后 `signal_eof` 并 rename 成正式
/// 缓存（下次播放秒起）；若流被关闭（切歌/stop，`write` 返回 0）立即退出
/// 并清理残留 `.part`，避免半截缓存被误命中。
///
/// [format_hint]：远端文件扩展名（"mp3"/"flac"…），core 据此选择解码器，
/// 传 None 则纯靠 symphonia 自动探测。返回 Ok 即表示流已启动且**首块已喂入
/// core**（probe 拿到数据，ready 大概率达成）。失败（连接不可用/流被关）
/// 返回 Err，Dart 回退全量下载；不再 fire-and-forget 导致失败静默。
/// [content_length]：远端文件真实字节数（扫描期已知），作为流总长度传给
/// core，使 symphonia 结合比特率算出**真实时长**（FLAC 用 STREAMINFO 精确，
/// CBR 用 字节数/比特率），进度条因此准确；None 则退化为 Dart 侧粗估。#[frb]
pub async fn engine_play_smb_stream(
    smb_path: String,
    format_hint: Option<String>,
    cache_final_path: Option<String>,
    content_length: Option<u64>,
    seek_secs: Option<f64>,
) -> Result<(), String> {
    let handle =
        crate::api::engine::engine_start_stream(format_hint, content_length, seek_secs)?;
    // 首块喂流成功信号：喂流 task 写入第一块后通知，主函数据此确认流已启动
    let (first_tx, first_rx) = tokio::sync::oneshot::channel::<Result<(), String>>();
    let first_tx = std::sync::Arc::new(std::sync::Mutex::new(Some(first_tx)));
    // spawn 后台喂流 task：从池独占连接读远端 → 喂 core + 写缓存
    tokio::spawn(async move {
        let result = feed_stream_to_core(
            &handle,
            &smb_path,
            cache_final_path.as_deref(),
            Some(std::sync::Arc::clone(&first_tx)),
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
            let msg = format!("SMB 流播放中断: {e}");
            eprintln!("[SMB] 喂流失败(后台): {e}");
            crate::api::engine::notify_stream_error(msg);
        }
    });
    // 同步等首块喂流结果（probe 有数据 → ready 达成），最多等 OPEN_TIMEOUT
    match tokio::time::timeout(
        IO_READ_TIMEOUT,
        first_rx,
    )
    .await
    {
        Ok(Ok(Ok(()))) => Ok(()),
        Ok(Ok(Err(e))) => Err(format!("首块喂流失败: {e}")),
        Ok(Err(_)) => Err("喂流 task 未返回结果".to_string()),
        Err(_) => Err("等待首块喂流超时".to_string()),
    }
}

/// 喂流核心：独占池连接，读远端分块喂给 core 并并行写 `.part` 缓存。
/// [first_notify]：第一块成功喂入 core 时触发（变 None），用于主流程同步确认
/// 流已启动（probe 拿到字节 ready 达成）。
async fn feed_stream_to_core(
    handle: &StreamHandle,
    smb_path: &str,
    cache_final_path: Option<&str>,
    first_notify: Option<
        std::sync::Arc<std::sync::Mutex<Option<tokio::sync::oneshot::Sender<Result<(), String>>>>>,
    >,
) -> Result<(), String> {
    // 获取池 permit：不无限等待。池被占满（如批量封面提取并发）时直接
    // 新建独立临时连接喂流，保证「点歌出声」不被后台任务阻塞。
    let _permit = POOL_SEM.try_acquire().ok();
    let (mut sess, from_pool) = match POOL.lock().await.pop() {
        Some(s) => (s, true),
        None => {
            let params = PARAMS.lock().await.clone().ok_or("not connected")?;
            let share = SESSION
                .lock()
                .await
                .as_ref()
                .and_then(|s| s.tree.as_ref().map(|t| t.share_name.clone()))
                .ok_or("no share connected")?;
            let mut client = connect_with_timeout(&params).await?;
            let tree = connect_share_with_timeout(&mut client, &share).await?;
            (SmbSession { client, tree: Some(tree) }, false)
        }
    };
    ensure_pooled_tree(&mut sess).await;

    // .part.stream.<unique> 路径：与 Dart 侧 downloadToLocal 的 ".part" 隔离，
    // 避免播放边下边播（Rust 喂流）与收藏离线下载（Dart 全量分片）并发时
    // 两个写者交错误写同一临时文件导致缓存损坏。unique 随机后缀避免同曲
    // 重播时旧喂流 task 的失败清理误删新 task 正在写的临时文件。
    // 双方各自独立写完 rename 成正式缓存（后完成者胜，均为完整内容）。
    let part_path = cache_final_path.map(|p| format!("{p}.part.stream.{}", random_hex(8)));
    let part_path = part_path.as_deref();
    // 进程内首次播放时清扫历史残留 .part.stream.*（此前崩溃/强杀留下的），
    // 只执行一次；跳过当前正在写的文件避免误删。
    cleanup_stale_part_stream(cache_final_path, part_path);

    let result: Result<(), String> = async {
        let tree = sess.tree.as_ref().ok_or("no share connected")?;
        // open 包 10s 超时：死连接上 CREATE 快速失败，喂流 task 尽早结束
        let reader = match tokio::time::timeout(
            IO_READ_TIMEOUT,
            sess.client.open_file_reader(tree, smb_path),
        )
        .await
        {
            Ok(r) => r.map_err(err_str)?,
            Err(_) => return Err("open timeout (10s)".to_string()),
        };
        let total = reader.size();
        if total == 0 {
            let _ = reader.close().await;
            return Err(format!("remote file is empty (size 0): {smb_path}"));
        }

        // 并行写 .part 缓存（覆盖式写入，确保干净）
        let mut cache_file = match part_path {
            Some(p) => {
                let f = std::fs::File::create(p).map_err(err_str)?;
                Some(f)
            }
            None => None,
        };

        let mut offset = 0u64;
        const CHUNK: u64 = 512 * 1024;
        while offset < total {
            // 分块读也包 10s 超时：死连接上 READ 快速失败，不白等 crate 30s
            let data = match tokio::time::timeout(
                IO_READ_TIMEOUT,
                reader.read_at(offset, CHUNK),
            )
            .await
            {
                Ok(d) => d.map_err(err_str)?,
                Err(_) => {
                    let _ = reader.close().await;
                    return Err(format!(
                        "read timeout (10s) at offset {offset}/{total}: {smb_path}"
                    ));
                }
            };
            let n = data.len() as u64;
            if n == 0 {
                return Err(format!("unexpected EOF at offset {offset}/{total}: {smb_path}"));
            }
            // 喂给 core：流被关闭（切歌/stop）时 write 返回 0，停止拉取
            let written = handle.write(&data);
            if written == 0 {
                let _ = reader.close().await;
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
                f.write_all(&data).map_err(err_str)?;
            }
            offset += n;
        }
        // 读尽：通知 EOF 并落缓存（完整读到文件末尾）
        let _ = reader.close().await;
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

    // 失败/超时/流被关闭：清理残留 .part 并丢弃连接；成功回池
    if result.is_err() {
        if let Some(part) = part_path {
            let _ = std::fs::remove_file(part);
        }
    }
    if from_pool && result.is_ok() {
        POOL.lock().await.push(sess);
    }
    drop(_permit);
    result
}

/// 清扫历史残留的 `.part.stream.*` 临时文件：进程崩溃/强杀后
/// 失败路径清理没机会执行，会越积越多占用磁盘。进程内只执行一次
/// （首次喂流时），扫描缓存目录删除匹配文件，跳过当前正在写的。
fn cleanup_stale_part_stream(cache_final_path: Option<&str>, current: Option<&str>) {
    use std::sync::OnceLock;
    static DONE: OnceLock<()> = OnceLock::new();
    if DONE.get().is_some() {
        return;
    }
    let Some(final_path) = cache_final_path else { return };
    let Some(dir) = std::path::Path::new(final_path).parent() else { return };
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.contains(".part.stream.")
            && current.map(|c| c != name.as_ref()).unwrap_or(true)
        {
            let _ = std::fs::remove_file(entry.path());
        }
    }
    let _ = DONE.set(());
}

/// 简易伪随机 hex 串（缓存临时文件唯一后缀用）：时间播种的 LCG +
/// 原子计数器搅动——同纳秒内多次调用（并发播放同曲/快速切歌）也能
/// 拿到不同后缀，避免撞名互相覆盖；无需引入 rand 依赖
fn random_hex(len: usize) -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};
    static CTR: AtomicU64 = AtomicU64::new(0);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let ctr = CTR.fetch_add(1, Ordering::Relaxed);
    let mut seed = (nanos as u64) ^ ctr.wrapping_mul(0x9E37_79B9_7F4A_7C15);
    let mut out = String::new();
    while out.len() < len {
        seed = seed
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        out.push_str(&format!("{:x}", seed));
    }
    out[..len].to_string()
}
