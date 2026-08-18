//! 桌面端 FRB 绑定模块树（与 mobile `api` 同构）。
//! flutter_rust_bridge 的 `rust_input` 指向 `crate::api`，
//! 递归导出本模块下所有 pub 函数（engine / webdav / smb）。

pub mod engine;
pub mod smb;
pub mod webdav;
