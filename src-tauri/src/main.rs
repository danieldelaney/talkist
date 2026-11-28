mod asr;
mod audio;
mod config;
mod download;
mod paste;
mod portal;
mod portal_hotkey;
mod traycheck;
mod updater;

use audio::{Cmd, Status};
use config::Config;
use serde::Serialize;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_global_shortcut::{
    Code, GlobalShortcutExt, Shortcut, ShortcutEvent, ShortcutState,
};

const DEFAULT_HOTKEY: &str = "F9";

#[derive(Clone, Default)]
struct ModelState {
    ready: bool,
    in_flight: bool,
    status_text: Option<String>,
    progress: Option<u8>,
    error_text: Option<String>,
    error_detail: Option<String>,
}

struct TrayItems {
    status: Option<MenuItem<tauri::Wry>>,
    update: Option<MenuItem<tauri::Wry>>,
    hotkey: MenuItem<tauri::Wry>,
    start_at_login: CheckMenuItem<tauri::Wry>,
}

struct AppState {
    config: Mutex<Config>,
    model_dir: PathBuf,
    model: Mutex<ModelState>,
    status_tx: std::sync::mpsc::Sender<Status>,
    cmds: Mutex<Option<std::sync::mpsc::Sender<Cmd>>>,
    update: Mutex<Option<updater::UpdateManifest>>,
    update_status: Mutex<Option<(String, bool)>>,
    updating: AtomicBool,
    quitting: AtomicBool,
    runtime_started: AtomicBool,
    portal: std::sync::OnceLock<portal_hotkey::PortalHandle>,
    wayland_paster: std::sync::OnceLock<paste::WaylandPasteHandle>,
    tray_items: Mutex<Option<TrayItems>>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct UiState {
    is_fully_ready: bool,
    model_ready: bool,
    model_status: Option<String>,
    model_progress: Option<u8>,
    model_error: Option<String>,
    model_error_detail: Option<String>,
    needs_paste_permission: bool,
    paste_ready: bool,
    hotkey: String,
    hotkey_display: String,
    is_wayland: bool,
}

fn main() {
    // WebKitGTK's DMABUF renderer fails on some NVIDIA/GBM setups. The small
    // Talkist windows do not benefit from GPU compositing.
    std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
    std::env::set_var("WEBKIT_DISABLE_COMPOSITING_MODE", "1");

    let config = Config::load();
    let model_dir = config::model_dir().unwrap_or_else(|| {
        eprintln!("cannot determine model directory (no XDG data dir?)");
        std::process::exit(1);
    });
    traycheck::ensure_tray_support();

    let (status_tx, status_rx) = std::sync::mpsc::channel();
    let files_ready = download::model_ready(&model_dir);

    let mut builder = tauri::Builder::default().plugin(tauri_plugin_single_instance::init(
        |app, _args, _cwd| {
            if !is_fully_ready(app) {
                present_settings_window(app);
            } else if let Some(portal) = app.state::<AppState>().portal.get() {
                portal.send(portal_hotkey::PortalMsg::Configure);
            } else {
                present_settings_window(app);
            }
        },
    ));
    if !portal::session_is_wayland() {
        builder = builder.plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(on_shortcut)
                .build(),
        );
    }

    builder
        .manage(AppState {
            config: Mutex::new(config),
            model_dir,
            model: Mutex::new(ModelState::default()),
            status_tx,
            cmds: Mutex::new(None),
            update: Mutex::new(None),
            update_status: Mutex::new(None),
            updating: AtomicBool::new(false),
            quitting: AtomicBool::new(false),
            runtime_started: AtomicBool::new(false),
            portal: std::sync::OnceLock::new(),
            wayland_paster: std::sync::OnceLock::new(),
            tray_items: Mutex::new(None),
        })
        .invoke_handler(tauri::generate_handler![
            get_state,
            retry_model_setup,
            request_paste_permission,
            set_hotkey,
            begin_hotkey_capture,
            cancel_hotkey_capture,
            configure_wayland_hotkey
        ])
        .setup(move |app| {
            if portal::session_is_wayland() {
                let handle = app.handle().clone();
                let wp = paste::WaylandPasteHandle::spawn(move || {
                    sync_tray_menu(&handle);
                    emit_app_state(&handle);
                });
                let _ = app.state::<AppState>().wayland_paster.set(wp);
            }

            let initial_status = if files_ready {
                Some("Loading speech model…")
            } else {
                Some("Downloading speech model…")
            };
            let start_at_login = app.state::<AppState>().config.lock().unwrap().start_at_login;
            let (menu, items) = build_tray_menu(
                app.handle(),
                "Finish Setup…",
                start_at_login,
                initial_status,
                None,
            )?;
            *app.state::<AppState>().tray_items.lock().unwrap() = Some(items);

            let initial_icon = if files_ready {
                tauri::include_image!("icons/tray-idle.png")
            } else {
                tauri::include_image!("icons/tray-downloading.png")
            };

            let mut tray_builder = TrayIconBuilder::with_id("main")
                .icon(initial_icon)
                .tooltip(if files_ready {
                    "Talkist"
                } else {
                    "Downloading speech model..."
                })
                .menu(&menu)
                .show_menu_on_left_click(true)
                .on_menu_event(|app, event| match event.id().as_ref() {
                    "update" => updater::start_install(app.clone()),
                    "hotkey" => {
                        if !is_fully_ready(app) {
                            let _ = present_settings_window_from_menu(app);
                        } else if let Some(portal) = app.state::<AppState>().portal.get() {
                            portal.send(portal_hotkey::PortalMsg::Configure);
                        } else {
                            let _ = present_settings_window_from_menu(app);
                        }
                    }
                    "start_at_login" => toggle_start_at_login(app),
                    "quit" => {
                        app.state::<AppState>()
                            .quitting
                            .store(true, Ordering::Relaxed);
                        app.exit(0);
                    }
                    _ => {}
                });
            // Inside Flatpak, /tmp and $XDG_RUNTIME_DIR/tray-icon are isolated
            // from the host shell; write tray icons into $XDG_CACHE_HOME where
            // both the sandbox and host GNOME/KDE see the exact same path.
            if let Some(cache_dir) = dirs::cache_dir() {
                let tray_dir = cache_dir.join("talkist/tray-icon");
                if std::fs::create_dir_all(&tray_dir).is_ok() {
                    tray_builder = tray_builder.temp_dir_path(tray_dir);
                }
            }
            tray_builder.build(app)?;

            let handle = app.handle().clone();
            std::thread::spawn(move || run_tray_status_loop(handle, status_rx));

            let needs_paste = needs_paste_permission(app.handle()) && !paste_ready(app.handle());
            if files_ready {
                load_model_and_finish_setup(app.handle().clone());
            } else {
                start_model_download(app.handle().clone());
            }
            if !files_ready || needs_paste {
                let _ = show_settings_window_now(app.handle());
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("Talkist failed to start")
        .run(|app, event| {
            if let tauri::RunEvent::ExitRequested { api, .. } = event {
                if !app.state::<AppState>().quitting.load(Ordering::Relaxed) {
                    api.prevent_exit();
                }
            }
        });
}

fn start_model_download(app: AppHandle) {
    let model_dir = {
        let state = app.state::<AppState>();
        let mut model = state.model.lock().unwrap();
        if model.in_flight || model.ready {
            return;
        }
        model.in_flight = true;
        model.ready = false;
        model.status_text = Some("Downloading speech model…".into());
        model.progress = None;
        model.error_text = None;
        model.error_detail = None;
        let _ = state.status_tx.send(Status::Downloading);
        state.model_dir.clone()
    };
    sync_tray_menu(&app);
    emit_app_state(&app);

    std::thread::spawn(move || {
        let app_for_progress = app.clone();
        let app_for_stage = app.clone();
        let outcome = download::download_and_extract(
            &model_dir,
            move |pct| {
                {
                    let state = app_for_progress.state::<AppState>();
                    let mut model = state.model.lock().unwrap();
                    model.progress = Some(pct);
                    model.status_text = Some(format!("Downloading speech model… {pct}%"));
                }
                sync_tray_menu(&app_for_progress);
                emit_app_state(&app_for_progress);
            },
            move |stage| {
                {
                    let state = app_for_stage.state::<AppState>();
                    let mut model = state.model.lock().unwrap();
                    model.progress = None;
                    model.status_text = Some(stage.to_string());
                }
                sync_tray_menu(&app_for_stage);
                emit_app_state(&app_for_stage);
            },
        );

        match outcome {
            Ok(()) => {
                {
                    let state = app.state::<AppState>();
                    state.model.lock().unwrap().in_flight = false;
                }
                load_model_and_finish_setup(app);
            }
            Err(e) => {
                eprintln!("model download failed: {e:#}");
                let short = download::short_error(&e);
                let detail = format!("{e:#}");
                {
                    let state = app.state::<AppState>();
                    let mut model = state.model.lock().unwrap();
                    model.in_flight = false;
                    model.status_text = None;
                    model.progress = None;
                    model.error_text = Some(short);
                    model.error_detail = Some(detail);
                    let _ = state.status_tx.send(Status::Idle);
                }
                sync_tray_menu(&app);
                emit_app_state(&app);
            }
        }
    });
}

fn load_model_and_finish_setup(app: AppHandle) {
    let (model_dir, num_threads, status_tx, wayland_paster) = {
        let state = app.state::<AppState>();
        let mut model = state.model.lock().unwrap();
        if model.in_flight || model.ready {
            return;
        }
        model.in_flight = true;
        model.status_text = Some("Loading speech model…".into());
        model.progress = None;
        model.error_text = None;
        model.error_detail = None;
        let num_threads = state.config.lock().unwrap().num_threads;
        (
            state.model_dir.clone(),
            num_threads,
            state.status_tx.clone(),
            state.wayland_paster.get().cloned(),
        )
    };
    sync_tray_menu(&app);
    emit_app_state(&app);

    std::thread::spawn(move || {
        match asr::spawn(model_dir, num_threads, status_tx.clone(), wayland_paster) {
            Ok(asr_tx) => {
                let cmds = audio::spawn_actor(asr_tx, status_tx.clone());
                {
                    let state = app.state::<AppState>();
                    *state.cmds.lock().unwrap() = Some(cmds);
                    let mut model = state.model.lock().unwrap();
                    model.in_flight = false;
                    model.ready = true;
                    model.status_text = None;
                    model.progress = None;
                    model.error_text = None;
                    model.error_detail = None;
                }
                let _ = status_tx.send(Status::Idle);
                finish_runtime_setup(&app);
                sync_tray_menu(&app);
                emit_app_state(&app);
            }
            Err(e) => {
                eprintln!("model load failed: {e:#}");
                {
                    let state = app.state::<AppState>();
                    let mut model = state.model.lock().unwrap();
                    model.in_flight = false;
                    model.ready = false;
                    model.status_text = None;
                    model.progress = None;
                    model.error_text = Some("Model failed to load".into());
                    model.error_detail = Some(format!("{e:#}"));
                }
                let _ = status_tx.send(Status::Idle);
                sync_tray_menu(&app);
                emit_app_state(&app);
                present_settings_window(&app);
            }
        }
    });
}

fn finish_runtime_setup(app: &AppHandle) {
    let state = app.state::<AppState>();
    if state.runtime_started.swap(true, Ordering::SeqCst) {
        return;
    }
    let hotkey = state.config.lock().unwrap().hotkey.clone();
    if portal::session_is_wayland() {
        let portal = portal_hotkey::spawn(app.clone(), hotkey);
        let _ = state.portal.set(portal);
    } else {
        let handle = app.clone();
        let _ = app.run_on_main_thread(move || {
            register_startup_hotkey(&handle, &hotkey);
            sync_tray_menu(&handle);
            emit_app_state(&handle);
        });
    }
    updater::spawn_checks(app.clone());
}

fn register_startup_hotkey(app: &AppHandle, configured: &str) {
    let shortcuts = app.global_shortcut();
    let parsed = configured.parse::<Shortcut>().ok();
    let active = match parsed {
        Some(sc) => match shortcuts.register(sc) {
            Ok(()) => Some((configured.to_string(), sc)),
            Err(e) => {
                eprintln!("failed to register hotkey {configured:?} ({e}); falling back to {DEFAULT_HOTKEY}");
                None
            }
        },
        None => {
            eprintln!("invalid hotkey {configured:?} in config; falling back to {DEFAULT_HOTKEY}");
            None
        }
    };

    if let Some((_, sc)) = active {
        if sc.key == Code::CapsLock {
            suppress_caps_lock();
        }
        return;
    }

    let fallback: Shortcut = DEFAULT_HOTKEY
        .parse()
        .expect("default hotkey must be valid");
    if let Err(e) = shortcuts.register(fallback) {
        eprintln!("failed to register fallback hotkey {DEFAULT_HOTKEY}: {e}");
    } else {
        let state = app.state::<AppState>();
        let mut cfg = state.config.lock().unwrap();
        cfg.hotkey = DEFAULT_HOTKEY.to_string();
        let _ = cfg.save();
    }
}

fn build_tray_menu(
    app: &AppHandle,
    primary_label: &str,
    start_at_login: bool,
    status_text: Option<&str>,
    update_line: Option<(&str, bool)>,
) -> tauri::Result<(Menu<tauri::Wry>, TrayItems)> {
    let version_item = MenuItem::with_id(
        app,
        "version",
        format!("Talkist {}", env!("CARGO_PKG_VERSION")),
        false,
        None::<&str>,
    )?;
    let status_item = match status_text {
        Some(text) => Some(MenuItem::with_id(app, "status", text, false, None::<&str>)?),
        None => None,
    };
    let update_item = match update_line {
        Some((text, enabled)) => Some(MenuItem::with_id(
            app,
            "update",
            text,
            enabled,
            None::<&str>,
        )?),
        None => None,
    };
    let separator = PredefinedMenuItem::separator(app)?;
    let hotkey_item = MenuItem::with_id(app, "hotkey", primary_label, true, None::<&str>)?;
    let login_item = CheckMenuItem::with_id(
        app,
        "start_at_login",
        "Start at login",
        true,
        start_at_login,
        None::<&str>,
    )?;
    let quit_item = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;

    let mut entries: Vec<&dyn tauri::menu::IsMenuItem<tauri::Wry>> = vec![&version_item];
    if let Some(ref item) = status_item {
        entries.push(item);
    }
    if let Some(ref item) = update_item {
        entries.push(item);
    }
    entries.push(&separator);
    entries.push(&hotkey_item);
    entries.push(&login_item);
    entries.push(&quit_item);

    let menu = Menu::with_items(app, &entries)?;
    Ok((
        menu,
        TrayItems {
            status: status_item,
            update: update_item,
            hotkey: hotkey_item,
            start_at_login: login_item,
        },
    ))
}

fn sync_tray_menu(app: &AppHandle) {
    let state = app.state::<AppState>();
    let model = state.model.lock().unwrap().clone();
    let start_at_login = state.config.lock().unwrap().start_at_login;
    let update_line = state.update_status.lock().unwrap().clone();

    let status_line = if let Some(status) = model.status_text {
        Some(status)
    } else {
        model.error_text.map(|err| format!("Setup error: {err}"))
    };
    let primary_label = if !is_fully_ready(app) {
        "Finish Setup…".to_string()
    } else {
        format!("Hotkey: {}", current_hotkey_display(app))
    };

    let want_status = status_line.is_some();
    let want_update = update_line.is_some();

    let updated_in_place = {
        let guard = state.tray_items.lock().unwrap();
        if let Some(items) = guard.as_ref() {
            if items.status.is_some() == want_status && items.update.is_some() == want_update {
                if let (Some(ref item), Some(ref text)) = (&items.status, &status_line) {
                    let _ = item.set_text(text);
                }
                if let (Some(ref item), Some((ref text, enabled))) = (&items.update, &update_line) {
                    let _ = item.set_text(text);
                    let _ = item.set_enabled(*enabled);
                }
                let _ = items.hotkey.set_text(&primary_label);
                let _ = items.start_at_login.set_checked(start_at_login);
                true
            } else {
                false
            }
        } else {
            return;
        }
    };

    if updated_in_place {
        return;
    }

    let Ok((menu, items)) = build_tray_menu(
        app,
        &primary_label,
        start_at_login,
        status_line.as_deref(),
        update_line.as_ref().map(|(t, e)| (t.as_str(), *e)),
    ) else {
        return;
    };
    if let Some(tray) = app.tray_by_id("main") {
        if tray.set_menu(Some(menu)).is_ok() {
            *state.tray_items.lock().unwrap() = Some(items);
        }
    }
}

pub fn format_hotkey_display(raw: &str) -> String {
    if raw.eq_ignore_ascii_case("not set") {
        return "Not set".to_string();
    }
    raw.split('+')
        .map(|part| match part.trim() {
            "CapsLock" | "Caps_Lock" => "Caps Lock".to_string(),
            "BackSpace" | "Backspace" => "Backspace".to_string(),
            "PageUp" => "Page Up".to_string(),
            "PageDown" => "Page Down".to_string(),
            "ArrowUp" => "Up".to_string(),
            "ArrowDown" => "Down".to_string(),
            "ArrowLeft" => "Left".to_string(),
            "ArrowRight" => "Right".to_string(),
            "Backquote" => "`".to_string(),
            "Minus" => "-".to_string(),
            "Equal" => "=".to_string(),
            "BracketLeft" => "[".to_string(),
            "BracketRight" => "]".to_string(),
            "Backslash" => "\\".to_string(),
            "Semicolon" => ";".to_string(),
            "Quote" => "'".to_string(),
            "Comma" => ",".to_string(),
            "Period" => ".".to_string(),
            "Slash" => "/".to_string(),
            other => other.to_string(),
        })
        .collect::<Vec<_>>()
        .join("+")
}

fn current_hotkey_raw(app: &AppHandle) -> String {
    let state = app.state::<AppState>();
    if let Some(portal) = state.portal.get() {
        portal.display()
    } else {
        state.config.lock().unwrap().hotkey.clone()
    }
}

fn current_hotkey_display(app: &AppHandle) -> String {
    format_hotkey_display(&current_hotkey_raw(app))
}

fn needs_paste_permission(app: &AppHandle) -> bool {
    app.state::<AppState>()
        .wayland_paster
        .get()
        .map(|wp| wp.needs_permission())
        .unwrap_or(false)
}

fn paste_ready(app: &AppHandle) -> bool {
    app.state::<AppState>()
        .wayland_paster
        .get()
        .map(|wp| wp.is_authorized())
        .unwrap_or(true)
}

fn is_fully_ready(app: &AppHandle) -> bool {
    let model_ready = app.state::<AppState>().model.lock().unwrap().ready;
    model_ready && (!needs_paste_permission(app) || paste_ready(app))
}

fn build_ui_state(app: &AppHandle) -> UiState {
    let state = app.state::<AppState>();
    let model = state.model.lock().unwrap().clone();
    let hotkey = current_hotkey_raw(app);
    let hotkey_display = format_hotkey_display(&hotkey);
    let needs_paste = needs_paste_permission(app);
    let paste_ok = paste_ready(app);
    let fully_ready = model.ready && (!needs_paste || paste_ok);
    UiState {
        is_fully_ready: fully_ready,
        model_ready: model.ready,
        model_status: model.status_text,
        model_progress: model.progress,
        model_error: model.error_text,
        model_error_detail: model.error_detail,
        needs_paste_permission: needs_paste,
        paste_ready: paste_ok,
        hotkey,
        hotkey_display,
        is_wayland: portal::session_is_wayland(),
    }
}

pub fn emit_app_state(app: &AppHandle) {
    let snapshot = build_ui_state(app);
    // On Wayland, the compositor owns shortcut configuration; once first-run
    // setup completes, close the setup window instead of showing the custom
    // X11 keycap picker.
    if snapshot.is_wayland && snapshot.is_fully_ready {
        if let Some(window) = app.get_webview_window("settings") {
            let _ = window.close();
        }
    }
    let _ = app.emit("app-state", snapshot);
}

pub fn update_tray_hotkey(app: &AppHandle, _label: &str) {
    sync_tray_menu(app);
    emit_app_state(app);
}

pub fn show_tray_update(app: &AppHandle, version: &str) {
    let state = app.state::<AppState>();
    if state.updating.load(Ordering::Relaxed) {
        return;
    }
    *state.update_status.lock().unwrap() = Some((format!("Update to {version}"), true));
    sync_tray_menu(app);
}

pub fn set_tray_update_status(app: &AppHandle, text: &str, enabled: bool) {
    let state = app.state::<AppState>();
    *state.update_status.lock().unwrap() = Some((text.to_string(), enabled));
    sync_tray_menu(app);
}

fn toggle_start_at_login(app: &AppHandle) {
    let state = app.state::<AppState>();
    let target = !state.config.lock().unwrap().start_at_login;
    let final_state = match apply_start_at_login(&state, target) {
        Ok(()) => target,
        Err(e) => {
            eprintln!("failed to update start at login: {e}");
            !target
        }
    };
    let guard = state.tray_items.lock().unwrap();
    if let Some(items) = guard.as_ref() {
        let _ = items.start_at_login.set_checked(final_state);
    }
}

fn apply_start_at_login(state: &AppState, enabled: bool) -> Result<(), String> {
    if portal::is_flatpak() {
        portal::request_background_autostart(enabled).map_err(|e| format!("{e:#}"))?;
    } else {
        let dir = dirs::config_dir()
            .ok_or("cannot find config directory")?
            .join("autostart");
        let path = dir.join("talkist.desktop");
        if enabled {
            if path.exists() {
                std::fs::remove_file(&path).map_err(|e| e.to_string())?;
            }
        } else {
            std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
            std::fs::write(&path, "[Desktop Entry]\nHidden=true\n").map_err(|e| e.to_string())?;
        }
    }
    let mut config = state.config.lock().unwrap();
    config.start_at_login = enabled;
    config.save().map_err(|e| e.to_string())
}

fn present_settings_window(app: &AppHandle) {
    let handle = app.clone();
    std::thread::spawn(move || {
        // Let any tray menu close before asking GNOME to raise the window.
        std::thread::sleep(std::time::Duration::from_millis(100));
        let h = handle.clone();
        let _ = handle.run_on_main_thread(move || {
            let _ = show_settings_window_now(&h);
        });
    });
}

fn show_settings_window_now(app: &AppHandle) -> tauri::Result<()> {
    let window = settings_window(app)?;
    let _ = window.show();
    let _ = window.unminimize();
    let _ = window.set_focus();
    Ok(())
}

fn settings_window(app: &AppHandle) -> tauri::Result<tauri::WebviewWindow> {
    if let Some(window) = app.get_webview_window("settings") {
        return Ok(window);
    }
    let window = WebviewWindowBuilder::new(app, "settings", WebviewUrl::App("settings.html".into()))
        .title("Talkist")
        .inner_size(340.0, 172.0)
        .resizable(false)
        .center()
        .build()?;
    Ok(window)
}

#[cfg(target_os = "linux")]
fn present_settings_window_from_menu(app: &AppHandle) -> tauri::Result<()> {
    use gtk::prelude::GtkWindowExt;

    let timestamp = gtk::current_event_time();
    let window = settings_window(app)?;
    window.show()?;
    window.unminimize()?;
    window.gtk_window()?.present_with_time(timestamp);
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn present_settings_window_from_menu(app: &AppHandle) -> tauri::Result<()> {
    show_settings_window_now(app)
}

fn set_tray_status(app: &AppHandle, status: Status) {
    let Some(tray) = app.tray_by_id("main") else {
        return;
    };
    let (icon, tooltip) = match status {
        Status::Idle => (tauri::include_image!("icons/tray-idle.png"), "Talkist"),
        Status::Recording => (
            tauri::include_image!("icons/tray-recording.png"),
            "Recording...",
        ),
        Status::Transcribing => (
            tauri::include_image!("icons/tray-transcribing.png"),
            "Transcribing...",
        ),
        Status::Downloading => (
            tauri::include_image!("icons/tray-downloading.png"),
            "Downloading speech model...",
        ),
    };
    let _ = tray.set_icon(Some(icon));
    let _ = tray.set_tooltip(Some(tooltip));
}

fn run_tray_status_loop(app: AppHandle, rx: std::sync::mpsc::Receiver<Status>) {
    use std::sync::mpsc::RecvTimeoutError;
    use std::time::{Duration, Instant};

    const TRANSCRIBING_DELAY: Duration = Duration::from_millis(150);
    const MIN_TRANSCRIBING_TIME: Duration = Duration::from_millis(400);

    let mut displayed = Status::Idle;
    let mut pending: Option<(Status, Instant)> = None;
    let mut transcribing_since = None;

    loop {
        let event = if let Some((_, deadline)) = pending {
            match rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
                Ok(status) => Some(Some(status)),
                Err(RecvTimeoutError::Timeout) => Some(None),
                Err(RecvTimeoutError::Disconnected) => None,
            }
        } else {
            rx.recv().ok().map(Some)
        };

        let Some(event) = event else { break };
        if let Some(status) = event {
            let now = Instant::now();
            match status {
                Status::Recording | Status::Downloading => {
                    pending = None;
                    transcribing_since = None;
                    if displayed != status {
                        set_tray_status(&app, status);
                        displayed = status;
                    }
                }
                Status::Transcribing => {
                    if displayed != Status::Transcribing {
                        pending = Some((status, now + TRANSCRIBING_DELAY));
                    }
                }
                Status::Idle => {
                    if matches!(pending, Some((Status::Transcribing, _))) {
                        pending = None;
                        transcribing_since = None;
                    } else if displayed == Status::Transcribing {
                        let deadline = transcribing_since.unwrap_or(now) + MIN_TRANSCRIBING_TIME;
                        if deadline > now {
                            pending = Some((status, deadline));
                            continue;
                        }
                    } else {
                        pending = None;
                    }

                    if displayed != status {
                        set_tray_status(&app, status);
                        displayed = status;
                    }
                }
            }
            continue;
        }

        let Some((status, _)) = pending.take() else {
            continue;
        };
        set_tray_status(&app, status);
        displayed = status;
        transcribing_since = (status == Status::Transcribing).then(Instant::now);
    }
}

fn on_shortcut(app: &AppHandle, sc: &Shortcut, event: ShortcutEvent) {
    if sc.key == Code::CapsLock {
        suppress_caps_lock();
    }
    let state = app.state::<AppState>();
    let Some(tx) = state.cmds.lock().unwrap().clone() else {
        return;
    };
    let cmd = match event.state() {
        ShortcutState::Pressed => Cmd::Start,
        ShortcutState::Released => Cmd::StopSend,
    };
    let _ = tx.send(cmd);
}

// The X server toggles the Lock modifier for CapsLock even when the key is
// grabbed as a global shortcut, so every press would flip caps on. Reset the
// lock state on each event to keep CapsLock a pure push-to-talk key while it
// is assigned; normal caps behavior returns once the hotkey changes or the
// app exits.
#[cfg(target_os = "linux")]
fn suppress_caps_lock() {
    use x11_dl::xlib::Xlib;

    const XKB_USE_CORE_KBD: std::os::raw::c_uint = 0x0100;
    const LOCK_MASK: std::os::raw::c_uint = 0x02;

    thread_local! {
        static XLIB: Option<Xlib> = Xlib::open().ok();
    }

    XLIB.with(|xlib| {
        let Some(xlib) = xlib else { return };
        unsafe {
            let display = (xlib.XOpenDisplay)(std::ptr::null());
            if display.is_null() {
                return;
            }
            (xlib.XkbLockModifiers)(display, XKB_USE_CORE_KBD, LOCK_MASK, 0);
            (xlib.XCloseDisplay)(display);
        }
    });
}

#[cfg(not(target_os = "linux"))]
fn suppress_caps_lock() {}

#[tauri::command]
fn get_state(app: AppHandle) -> UiState {
    build_ui_state(&app)
}

#[tauri::command]
fn retry_model_setup(app: AppHandle, state: tauri::State<'_, AppState>) {
    if download::model_ready(&state.model_dir) {
        load_model_and_finish_setup(app);
    } else {
        start_model_download(app);
    }
}

#[tauri::command]
fn request_paste_permission(state: tauri::State<'_, AppState>) {
    if let Some(wp) = state.wayland_paster.get() {
        wp.authorize();
    }
}

#[tauri::command]
fn configure_wayland_hotkey(state: tauri::State<'_, AppState>) {
    if let Some(portal) = state.portal.get() {
        portal.send(portal_hotkey::PortalMsg::Configure);
    }
}

#[tauri::command]
async fn set_hotkey(
    app: AppHandle,
    state: tauri::State<'_, AppState>,
    hotkey: String,
) -> Result<(), String> {
    if !state.model.lock().unwrap().ready {
        return Err("Speech model is not ready yet".into());
    }
    if let Some(portal) = state.portal.get() {
        portal.send(portal_hotkey::PortalMsg::Configure);
        return Ok(());
    }

    let shortcuts = app.global_shortcut();
    let old_text = state.config.lock().unwrap().hotkey.clone();
    let old = old_text
        .parse::<Shortcut>()
        .or_else(|_| DEFAULT_HOTKEY.parse::<Shortcut>())
        .map_err(|e| e.to_string())?;
    let new: Shortcut = hotkey.parse::<Shortcut>().map_err(|_| {
        // begin_hotkey_capture may have unregistered the old shortcut;
        // restore it so the failed change leaves the app usable.
        let _ = shortcuts.register(old);
        "Key not supported".to_string()
    })?;

    // begin_hotkey_capture unregisters the old shortcut so the hotkey window
    // can see that key, so the old one may legitimately be gone.
    if !shortcuts.is_registered(new) {
        if let Err(e) = shortcuts.register(new) {
            let _ = shortcuts.register(old);
            return Err(format!("Could not bind key ({e})"));
        }
    }
    if new.id() != old.id() {
        let _ = shortcuts.unregister(old);
    }

    let save = {
        let mut config = state.config.lock().unwrap();
        config.hotkey = hotkey.clone();
        let result = config.save();
        if result.is_err() {
            config.hotkey = old_text;
        }
        result
    };
    if let Err(e) = save {
        let _ = shortcuts.unregister(new);
        let _ = shortcuts.register(old);
        return Err(e.to_string());
    }

    sync_tray_menu(&app);
    emit_app_state(&app);
    if new.key == Code::CapsLock {
        suppress_caps_lock();
    }
    Ok(())
}

#[tauri::command]
fn begin_hotkey_capture(app: AppHandle, state: tauri::State<'_, AppState>) -> Result<(), String> {
    if !state.model.lock().unwrap().ready {
        return Err("Speech model is not ready yet".into());
    }
    if let Some(portal) = state.portal.get() {
        portal.send(portal_hotkey::PortalMsg::Configure);
        return Ok(());
    }
    let hotkey = state.config.lock().unwrap().hotkey.clone();
    if let Ok(shortcut) = hotkey.parse::<Shortcut>() {
        let _ = app.global_shortcut().unregister(shortcut);
    }
    Ok(())
}

#[tauri::command]
fn cancel_hotkey_capture(app: AppHandle, state: tauri::State<'_, AppState>) -> Result<(), String> {
    if !state.model.lock().unwrap().ready || state.portal.get().is_some() {
        return Ok(());
    }
    let hotkey = state.config.lock().unwrap().hotkey.clone();
    if let Ok(shortcut) = hotkey.parse::<Shortcut>() {
        if !app.global_shortcut().is_registered(shortcut) {
            app.global_shortcut()
                .register(shortcut)
                .map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{format_hotkey_display, Shortcut};

    #[test]
    fn formats_hotkey_names() {
        assert_eq!(format_hotkey_display("F9"), "F9");
        assert_eq!(format_hotkey_display("CapsLock"), "Caps Lock");
        assert_eq!(format_hotkey_display("Ctrl+Caps_Lock"), "Ctrl+Caps Lock");
        assert_eq!(format_hotkey_display("Ctrl+Shift+Space"), "Ctrl+Shift+Space");
        assert_eq!(format_hotkey_display("Ctrl+Backquote"), "Ctrl+`");
        assert_eq!(format_hotkey_display("Not set"), "Not set");
    }

    #[test]
    fn frontend_code_map_keys_parse_as_shortcuts() {
        let keys = [
            "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
            "CapsLock", "Space", "Tab", "Backspace", "Insert", "Delete", "Home", "End",
            "PageUp", "PageDown", "Up", "Down", "Left", "Right",
            "Backquote", "Minus", "Equal", "BracketLeft", "BracketRight",
            "Backslash", "Semicolon", "Quote", "Comma", "Period", "Slash",
            "A", "Z", "0", "9",
            "Ctrl+Shift+Space", "Alt+F9", "Super+Backquote",
        ];
        for key in keys {
            assert!(
                key.parse::<Shortcut>().is_ok(),
                "expected {key:?} to parse as Shortcut"
            );
        }
    }
}
