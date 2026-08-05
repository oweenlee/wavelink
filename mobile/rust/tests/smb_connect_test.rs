//! 手动 SMB 连接诊断：真实账户认证 → list_shares → connect_share → list_directory → read
//! 用法: cargo test --test smb_connect_test -- --ignored --nocapture
use rust_lib_wavelink_mobile::smb;

#[tokio::test]
#[ignore = "手动诊断工具：依赖局域网 NAS，默认跳过"]
async fn connect_and_list() {
    // 1. 连接本机独立 impacket SMB 服务器（guest 认证，绕开系统 smbd）
    let r = smb::smb_connect(
        "127.0.0.1".to_string(),
        4450,
        "".to_string(),
        "".to_string(),
        "".to_string(),
    )
    .await;
    eprintln!("connect: {:?}", r.as_ref().map(|_| "OK").map_err(|e| e.clone()));
    assert!(r.is_ok(), "connect failed: {:?}", r);

    // 2. 列共享
    let shares = smb::smb_list_shares().await;
    eprintln!("shares: {:?}", shares);
    assert!(shares.is_ok(), "list_shares failed: {:?}", shares);
    let names: Vec<String> = shares.unwrap().into_iter().map(|s| s.name).collect();
    assert!(
        names.iter().any(|n| n == "SHARE"),
        "SHARE not found, got: {names:?}"
    );

    // 3. 挂载 SHARE
    assert!(smb::smb_connect_share("SHARE".to_string()).await.is_ok());

    // 4. 列根目录
    let root = smb::smb_list_directory("".to_string()).await;
    eprintln!("root entries: {:?}", root);
    assert!(root.is_ok(), "list root failed: {:?}", root);

    // 5. 读第一个非目录文件验证 read_file
    for e in root.unwrap() {
        if !e.is_dir && e.size > 0 {
            let data = smb::smb_read_file(e.name.clone()).await;
            eprintln!("read {} ({} bytes): {:?}", e.name, e.size,
                data.as_ref().map(|b| b.len()).map_err(|s| s.clone()));
            if let Ok(bytes) = data {
                assert_eq!(bytes.len() as u64, e.size, "size mismatch {}", e.name);
            }
            break;
        }
    }

    smb::smb_disconnect().await;
    eprintln!("done");
}