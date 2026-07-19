use tauri::State;
use crate::state::AppState;
use crate::nas::NasConnection;

#[tauri::command]
pub fn nas_list(state: State<AppState>) -> Result<Vec<NasConnection>, String> {
    state.nas_manager.list()
}

#[tauri::command]
pub fn nas_add(
    name: String,
    server: String,
    share: String,
    username: String,
    password: String,
    auto_mount: bool,
    state: State<AppState>,
) -> Result<NasConnection, String> {
    let id = uuid::Uuid::new_v4().to_string();
    let mount_path = String::new();
    let conn = NasConnection {
        id: id.clone(),
        name,
        server,
        share,
        username,
        auto_mount,
        mount_path,
    };
    state.nas_manager.set_password(&id, &password)?;
    state.nas_manager.add(&conn)?;
    Ok(conn)
}

#[tauri::command]
pub fn nas_remove(id: String, state: State<AppState>) -> Result<(), String> {
    state.nas_manager.remove(&id)
}

#[tauri::command]
pub fn nas_mount(id: String, state: State<AppState>) -> Result<String, String> {
    state.nas_manager.mount(&id)
}

#[tauri::command]
pub fn nas_unmount(id: String, state: State<AppState>) -> Result<(), String> {
    state.nas_manager.unmount(&id)
}

#[tauri::command]
pub fn nas_is_mounted(id: String, state: State<AppState>) -> bool {
    state.nas_manager.is_mounted(&id)
}
