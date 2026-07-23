//! Platform media control integration
//! Windows: SMTC (SystemMediaTransportControls)
//! macOS: MPNowPlayingInfoCenter (via objc2)

#[cfg_attr(not(target_os = "windows"), allow(unused_imports))]
use tracing::{debug, warn};

/// Media bridge handle
pub struct MediaBridge;

impl MediaBridge {
    pub fn new() -> Self {
        #[cfg(target_os = "windows")]
        tracing::info!("Windows SMTC media bridge ready");
        #[cfg(target_os = "macos")]
        tracing::info!("macOS NowPlaying media bridge ready");
        #[cfg(not(any(target_os = "windows", target_os = "macos")))]
        tracing::info!("Media bridge: system media control not supported on this platform");
        Self
    }

    pub fn update_metadata(&self, title: &str, artist: &str, album: &str, duration_ms: u64) {
        #[cfg(target_os = "windows")]
        {
            if let Ok(mgr) = smtc_tokio::WindowsMediaManager::new() {
                mgr.set_metadata(title, &[artist.to_string()], album, duration_ms, None);
                debug!("SMTC metadata updated: {title}");
            } else {
                warn!("SMTC init failed");
            }
        }
        #[cfg(target_os = "macos")]
        {
            unsafe { mac_set_now_playing(title, artist, album, duration_ms as f64 / 1000.0); }
            debug!("NowPlaying metadata updated: {title}");
        }
        #[cfg(not(any(target_os = "windows", target_os = "macos")))]
        { let _ = (title, artist, album, duration_ms); }
    }

    pub fn update_playback_state(&self, is_playing: bool) {
        #[cfg(target_os = "windows")]
        {
            if let Ok(mgr) = smtc_tokio::WindowsMediaManager::new() {
                mgr.set_playback_status(is_playing);
            }
        }
        #[cfg(target_os = "macos")]
        unsafe { mac_set_playback_state(is_playing); }
        #[cfg(not(any(target_os = "windows", target_os = "macos")))]
        { let _ = is_playing; }
    }

    pub fn update_position(&self, #[allow(unused_variables)] position_ms: u64) {
        #[cfg(target_os = "windows")]
        {
            if let Ok(mgr) = smtc_tokio::WindowsMediaManager::new() {
                mgr.set_position(position_ms);
            }
        }
        // macOS: position is set in update_metadata to avoid frequent calls
        #[cfg(not(any(target_os = "windows", target_os = "macos")))]
        { let _ = position_ms; }
    }

    pub fn clear(&self) {
        #[cfg(target_os = "windows")]
        {
            if let Ok(mgr) = smtc_tokio::WindowsMediaManager::new() {
                mgr.set_stopped();
            }
        }
        #[cfg(target_os = "macos")]
        unsafe { mac_clear_now_playing(); }
    }
}

// ── macOS: raw objc2 calls to MediaPlayer.framework ──

#[cfg(target_os = "macos")]
unsafe fn mac_ns_string(s: &str) -> *mut objc2::runtime::AnyObject {
    // [NSString stringWithUTF8String:s]
    let cls = objc2::class!(NSString);
    let c_str = std::ffi::CString::new(s).unwrap_or_default();
    objc2::msg_send![cls, stringWithUTF8String: c_str.as_ptr()]
}

#[cfg(target_os = "macos")]
unsafe fn mac_ns_number_f64(v: f64) -> *mut objc2::runtime::AnyObject {
    let cls = objc2::class!(NSNumber);
    objc2::msg_send![cls, numberWithDouble: v]
}

#[cfg(target_os = "macos")]
unsafe fn mac_now_playing_center() -> *mut objc2::runtime::AnyObject {
    let cls = objc2::class!(MPNowPlayingInfoCenter);
    objc2::msg_send![cls, defaultCenter]
}

#[cfg(target_os = "macos")]
unsafe fn mac_set_now_playing(title: &str, artist: &str, album: &str, duration_secs: f64) {
    let center = mac_now_playing_center();
    if center.is_null() { return; }

    // Build key-value array for nowPlayingInfo
    let keys: [*mut objc2::runtime::AnyObject; 6] = [
        mac_ns_string("MPMediaItemPropertyTitle"),
        mac_ns_string("MPMediaItemPropertyArtist"),
        mac_ns_string("MPMediaItemPropertyAlbumTitle"),
        mac_ns_string("MPMediaItemPropertyPlaybackDuration"),
        mac_ns_string("MPNowPlayingInfoPropertyPlaybackRate"),
        mac_ns_string("MPNowPlayingInfoPropertyElapsedPlaybackTime"),
    ];
    let vals: [*mut objc2::runtime::AnyObject; 6] = [
        mac_ns_string(title),
        mac_ns_string(artist),
        mac_ns_string(album),
        mac_ns_number_f64(duration_secs),
        mac_ns_number_f64(1.0),
        mac_ns_number_f64(0.0),
    ];

    // NSArray *keysArr = [NSArray arrayWithObjects:keys count:6];
    let cls_arr = objc2::class!(NSArray);
    let keys_arr: *mut objc2::runtime::AnyObject = objc2::msg_send![
        cls_arr, arrayWithObjects: keys.as_ptr(), count: keys.len()
    ];
    let vals_arr: *mut objc2::runtime::AnyObject = objc2::msg_send![
        cls_arr, arrayWithObjects: vals.as_ptr(), count: vals.len()
    ];

    // NSDictionary *info = [NSDictionary dictionaryWithObjects:valsArr forKeys:keysArr];
    let cls_dict = objc2::class!(NSDictionary);
    let info: *mut objc2::runtime::AnyObject = objc2::msg_send![
        cls_dict, dictionaryWithObjects: vals_arr, forKeys: keys_arr
    ];

    // [center setNowPlayingInfo:info];
    let _: () = objc2::msg_send![center, setNowPlayingInfo: info];
}

#[cfg(target_os = "macos")]
unsafe fn mac_set_playback_state(is_playing: bool) {
    let center = mac_now_playing_center();
    if center.is_null() { return; }
    // 1=playing, 2=paused, 3=stopped
    let state: i64 = if is_playing { 1 } else { 2 };
    let _: () = objc2::msg_send![center, setPlaybackState: state];
}

#[cfg(target_os = "macos")]
unsafe fn mac_clear_now_playing() {
    let center = mac_now_playing_center();
    if center.is_null() { return; }
    let null_ptr: *mut objc2::runtime::AnyObject = std::ptr::null_mut();
    let _: () = objc2::msg_send![center, setNowPlayingInfo: null_ptr];
    let _: () = objc2::msg_send![center, setPlaybackState: 3i64]; // stopped
}
