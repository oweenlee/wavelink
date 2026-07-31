//! 流式音频数据源
//!
//! 允许平台层（iOS/Android/Windows）通过网络 I/O 获取音频数据，
//! 并通过宿主回调写入 core 进行解码。网络 I/O 完全由平台层负责，
//! core 只接收字节流并完成解码 + DSP + 输出。
//!
//! 用法（平台侧伪代码）：
//! ```c
//! AcStreamHandle *sh = ac_engine_play_stream(engine, "http://example.com/song.flac");
//! // 在网络回调中：
//! ac_stream_write(sh, data, len);
//! // 数据读完时：
//! ac_stream_eof(sh);
//! // 不再需要时：
//! ac_stream_destroy(sh);
//! ```

use std::io::{self, Read, Seek, SeekFrom};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use crossbeam_channel::{bounded, Receiver, Sender};
use symphonia::core::io::MediaSource;

/// 流式音频数据源（实现 Symphonia `MediaSource`）
///
/// 内部通过 crossbeam channel 接收平台层写入的字节数据，
/// 解码线程以阻塞方式读取。不支持 Seek（网络流不可回溯）。
pub struct StreamMediaSource {
    rx: Receiver<Vec<u8>>,
    /// 内部未消费完的缓冲
    buf: Vec<u8>,
    /// buf 中已消费的偏移
    pos: usize,
    eof: Arc<AtomicBool>,
    content_length: Option<u64>,
    /// 已读取的总字节数（用于 byte_len 估算和调试）
    total_read: u64,
}

/// 流写入端句柄（平台层持有，通过宿主层写入数据）
///
/// 线程安全：可从任意线程调用 write / signal_eof。
/// 可克隆：克隆后的句柄共享同一个底层 channel。
#[derive(Clone)]
pub struct StreamHandle {
    tx: Sender<Vec<u8>>,
    eof: Arc<AtomicBool>,
    content_length: Option<u64>,
}

/// 创建一对 (数据源, 写入句柄)。
///
/// - `content_length`: 可选的 Content-Length（字节），用于进度估算
pub fn stream_pair(content_length: Option<u64>) -> (StreamMediaSource, StreamHandle) {
    // 64 个 chunk 的背压缓冲（每个 chunk 通常 4~64KB）
    let (tx, rx) = bounded(64);
    let eof = Arc::new(AtomicBool::new(false));
    (
        StreamMediaSource {
            rx,
            buf: Vec::new(),
            pos: 0,
            eof: eof.clone(),
            content_length,
            total_read: 0,
        },
        StreamHandle {
            tx,
            eof,
            content_length,
        },
    )
}

// ─── StreamHandle（写入端） ─────────────────────────────────────

impl StreamHandle {
    /// 写入一段音频数据。返回实际写入的字节数。
    ///
    /// 如果内部缓冲已满（背压），会阻塞直到解码线程消费。
    /// 如果流已关闭（EOF 或解码器停止），返回 0。
    pub fn write(&self, data: &[u8]) -> usize {
        if data.is_empty() || self.eof.load(Ordering::Acquire) {
            return 0;
        }
        match self.tx.send_timeout(data.to_vec(), Duration::from_secs(5)) {
            Ok(()) => data.len(),
            Err(_) => 0, // 解码器已停止或 channel 断开
        }
    }

    /// 通知流结束（EOF）。调用后 write() 将不再生效。
    pub fn signal_eof(&self) {
        self.eof.store(true, Ordering::Release);
    }

    /// 是否已标记 EOF
    pub fn is_eof(&self) -> bool {
        self.eof.load(Ordering::Acquire)
    }

    /// Content-Length（如果平台层提供了）
    pub fn content_length(&self) -> Option<u64> {
        self.content_length
    }
}

// ─── StreamMediaSource（读取端，Symphonia MediaSource） ─────────

impl Read for StreamMediaSource {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        // 1. 先消费内部缓冲
        if self.pos < self.buf.len() {
            let avail = &self.buf[self.pos..];
            let n = avail.len().min(out.len());
            out[..n].copy_from_slice(&avail[..n]);
            self.pos += n;
            self.total_read += n as u64;
            // 缓冲消费完毕，释放内存
            if self.pos >= self.buf.len() {
                self.buf.clear();
                self.pos = 0;
            }
            return Ok(n);
        }

        // 2. 检查 EOF
        if self.eof.load(Ordering::Acquire) && self.rx.is_empty() {
            return Ok(0);
        }

        // 3. 阻塞等待下一个 chunk（100ms 超时，避免永久阻塞）
        loop {
            match self.rx.recv_timeout(Duration::from_millis(100)) {
                Ok(chunk) => {
                    let n = chunk.len().min(out.len());
                    out[..n].copy_from_slice(&chunk[..n]);
                    self.total_read += n as u64;
                    // 未消费完的部分存入内部缓冲
                    if n < chunk.len() {
                        self.buf = chunk;
                        self.pos = n;
                    }
                    return Ok(n);
                }
                Err(crossbeam_channel::RecvTimeoutError::Timeout) => {
                    if self.eof.load(Ordering::Acquire) {
                        return Ok(0);
                    }
                    // 继续等待
                }
                Err(crossbeam_channel::RecvTimeoutError::Disconnected) => {
                    return Ok(0);
                }
            }
        }
    }
}

impl Seek for StreamMediaSource {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        // 网络流不支持 seek，但 Symphonia 某些格式探测会尝试 seek(0)
        // 对于 SeekFrom::Start(0) 且我们还在起始位置时，返回成功
        match pos {
            SeekFrom::Start(0) if self.total_read == 0 && self.buf.is_empty() => Ok(0),
            _ => Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "network stream is not seekable",
            )),
        }
    }
}

impl MediaSource for StreamMediaSource {
    fn is_seekable(&self) -> bool {
        false
    }

    fn byte_len(&self) -> Option<u64> {
        self.content_length
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_stream_basic_read() {
        let (mut source, handle) = stream_pair(None);

        // 写入数据
        handle.write(b"hello ");
        handle.write(b"world");
        handle.signal_eof();

        // 读取
        let mut buf = Vec::new();
        source.read_to_end(&mut buf).unwrap();
        assert_eq!(&buf, b"hello world");
    }

    #[test]
    fn test_stream_eof_empty() {
        let (mut source, handle) = stream_pair(None);
        handle.signal_eof();

        let mut buf = [0u8; 16];
        let n = source.read(&mut buf).unwrap();
        assert_eq!(n, 0);
    }

    #[test]
    fn test_stream_not_seekable() {
        let (source, _handle) = stream_pair(None);
        assert!(!source.is_seekable());
        assert_eq!(source.byte_len(), None);
    }

    #[test]
    fn test_stream_content_length() {
        let (source, _handle) = stream_pair(Some(1024));
        assert_eq!(source.byte_len(), Some(1024));
    }

    #[test]
    fn test_stream_cross_thread() {
        let (mut source, handle) = stream_pair(None);

        let writer = std::thread::spawn(move || {
            for i in 0..100u8 {
                handle.write(&[i; 256]);
            }
            handle.signal_eof();
        });

        let mut total = 0usize;
        let mut buf = [0u8; 512];
        loop {
            let n = source.read(&mut buf).unwrap();
            if n == 0 {
                break;
            }
            total += n;
        }
        writer.join().unwrap();
        assert_eq!(total, 100 * 256);
    }

    #[test]
    fn test_stream_write_after_eof() {
        let (_source, handle) = stream_pair(None);
        handle.signal_eof();
        assert_eq!(handle.write(b"data"), 0);
    }
}
