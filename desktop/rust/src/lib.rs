//! WaveLink 桌面端 Rust FFI 桥接层（Flutter Rust Bridge）
//!
//! 通过 flutter_rust_bridge 暴露 audio_core 引擎，与 mobile 统一绑定层。
//! 具体绑定函数按 mobile 同构收在 `api` 模块树下（engine / webdav / smb），
//! `rust_input` 指向 `crate::api` 递归导出。

// 以下两条 lint 仅在 flutter_rust_bridge 生成的 api/*.rs 中触发，
// 属生成代码的固有复杂度/写法，手工改会被下次 codegen 覆盖，故在 crate 根统一放行。
#![allow(clippy::type_complexity)]
#![allow(clippy::needless_borrow)]

pub mod api;

mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
