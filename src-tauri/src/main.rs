mod asr;
mod audio;
mod config;
mod download;
mod paste;
mod traycheck;
mod updater;

use audio::{Cmd, Status};
use config::Config;
use serde::Serialize;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Shortcut, ShortcutEvent, ShortcutState};

struct AppState {
    config: Mutex<Config>,
    cmds: Mutex<Option<std::sync::mpsc::Sender<Cmd>>>,
    update: Mutex<Option<updater::UpdateManifest>>,
    quitting: AtomicBool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SettingsSnapshot {
    hotkey: String,
    start_at_login: bool,
    version: &'static str,
    update_version: Option<String>,
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
    let ready = download::model_ready(&model_dir);
    let (status_tx, status_rx) = std::sync::mpsc::channel();
    let cmds = if ready {
        traycheck::ensure_tray_support();
        let asr_tx = asr::spawn(model_dir.clone(), config.num_threads, status_tx.clone())
            .expect("failed to initialize speech model");
        Some(audio::spawn_actor(asr_tx, status_tx))
    } else {
        None
    };

    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            if let Some(window) = app.get_webview_window("setup") {
                let _ = window.set_focus();
            } else {
                present_settings(app);
            }
        }))
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(on_shortcut)
                .build(),
        )
        .manage(AppState {
            config: Mutex::new(config),
            cmds: Mutex::new(cmds),
            update: Mutex::new(None),
            quitting: AtomicBool::new(false),
        })
        .invoke_handler(tauri::generate_handler![
            get_settings,
            set_hotkey,
            begin_hotkey_capture,
            cancel_hotkey_capture,
            set_start_at_login,
            updater::install_update
        ])
        .setup(move |app| {
            if !ready {
                download::install_model(app.handle(), model_dir.clone());
                return Ok(());
            }

            let hotkey = app.state::<AppState>().config.lock().unwrap().hotkey.clone();
            let hot: Shortcut = hotkey
                .parse()
                .unwrap_or_else(|e| panic!("invalid hotkey {hotkey:?}: {e}"));
            app.global_shortcut().register(hot)?;

            let settings = MenuItem::with_id(app, "settings", "Talkist settings...", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&settings, &quit])?;
            TrayIconBuilder::with_id("main")
                .icon(tauri::include_image!("icons/tray-idle.png"))
                .menu(&menu)
                .show_menu_on_left_click(true)
                .on_menu_event(|app, event| match event.id().as_ref() {
                    "settings" => { let _ = present_settings_from_menu(app); }
                    "quit" => {
                        app.state::<AppState>().quitting.store(true, Ordering::Relaxed);
                        app.exit(0);
                    }
                    _ => {}
                })
                .build(app)?;

            let handle = app.handle().clone();
            std::thread::spawn(move || run_tray_status_loop(handle, status_rx));
            updater::spawn_checks(app.handle().clone());
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

fn present_settings(app: &AppHandle) {
    let handle = app.clone();
    std::thread::spawn(move || {
        // Let the tray menu close before asking GNOME to raise the window.
        std::thread::sleep(std::time::Duration::from_millis(100));
        if let Ok(window) = settings_window(&handle) {
            let _ = window.show();
            let _ = window.unminimize();
            let _ = window.set_focus();
        }
    });
}

fn settings_window(app: &AppHandle) -> tauri::Result<tauri::WebviewWindow> {
    if let Some(window) = app.get_webview_window("settings") {
        return Ok(window);
    }
    let window = WebviewWindowBuilder::new(app, "settings", WebviewUrl::App("settings.html".into()))
        .title("Talkist")
        .inner_size(430.0, 300.0)
        .resizable(false)
        .center()
        .build()?;
    Ok(window)
}

#[cfg(target_os = "linux")]
fn present_settings_from_menu(app: &AppHandle) -> tauri::Result<()> {
    use gtk::prelude::GtkWindowExt;

    let timestamp = gtk::current_event_time();
    let window = settings_window(app)?;
    window.show()?;
    window.unminimize()?;
    window.gtk_window()?.present_with_time(timestamp);
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn present_settings_from_menu(app: &AppHandle) -> tauri::Result<()> {
    let window = settings_window(app)?;
    window.show()?;
    window.unminimize()?;
    window.set_focus()
}

fn set_tray_status(app: &AppHandle, status: Status) {
    let Some(tray) = app.tray_by_id("main") else { return };
    let (icon, tooltip) = match status {
        Status::Idle => (tauri::include_image!("icons/tray-idle.png"), "Talkist"),
        Status::Recording => (tauri::include_image!("icons/tray-recording.png"), "Recording..."),
        Status::Transcribing => (tauri::include_image!("icons/tray-transcribing.png"), "Transcribing..."),
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
                Status::Recording => {
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

        let Some((status, _)) = pending.take() else { continue };
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
    let Some(tx) = state.cmds.lock().unwrap().clone() else { return };
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
fn get_settings(state: tauri::State<'_, AppState>) -> SettingsSnapshot {
    let config = state.config.lock().unwrap();
    SettingsSnapshot {
        hotkey: config.hotkey.clone(),
        start_at_login: config.start_at_login,
        version: env!("CARGO_PKG_VERSION"),
        update_version: state.update.lock().unwrap().as_ref().map(|u| u.version.clone()),
    }
}

#[tauri::command]
async fn set_hotkey(app: AppHandle, state: tauri::State<'_, AppState>, hotkey: String) -> Result<(), String> {
    let shortcuts = app.global_shortcut();
    let old_text = state.config.lock().unwrap().hotkey.clone();
    let old: Shortcut = old_text.parse::<Shortcut>().map_err(|e| e.to_string())?;
    let new: Shortcut = hotkey.parse::<Shortcut>().map_err(|e| {
        let _ = shortcuts.register(old);
        e.to_string()
    })?;

    // begin_hotkey_capture unregisters the old shortcut so the settings
    // window can see that key, so the old one may legitimately be gone.
    if !shortcuts.is_registered(new) {
        if let Err(e) = shortcuts.register(new) {
            let _ = shortcuts.register(old);
            return Err(e.to_string());
        }
    }
    if new.id() != old.id() {
        let _ = shortcuts.unregister(old);
    }

    let save = {
        let mut config = state.config.lock().unwrap();
        config.hotkey = hotkey;
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

    if new.key == Code::CapsLock {
        suppress_caps_lock();
    }
    Ok(())
}

#[tauri::command]
fn begin_hotkey_capture(app: AppHandle, state: tauri::State<'_, AppState>) -> Result<(), String> {
    let hotkey = state.config.lock().unwrap().hotkey.clone();
    let shortcut = hotkey.parse::<Shortcut>().map_err(|e| e.to_string())?;
    let _ = app.global_shortcut().unregister(shortcut);
    Ok(())
}

#[tauri::command]
fn cancel_hotkey_capture(app: AppHandle, state: tauri::State<'_, AppState>) -> Result<(), String> {
    let hotkey = state.config.lock().unwrap().hotkey.clone();
    let shortcut = hotkey.parse::<Shortcut>().map_err(|e| e.to_string())?;
    if !app.global_shortcut().is_registered(shortcut) {
        app.global_shortcut().register(shortcut).map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
fn set_start_at_login(state: tauri::State<'_, AppState>, enabled: bool) -> Result<(), String> {
    let dir = dirs::config_dir().ok_or("cannot find config directory")?.join("autostart");
    let path = dir.join("talkist.desktop");
    if enabled {
        if path.exists() { std::fs::remove_file(&path).map_err(|e| e.to_string())?; }
    } else {
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        std::fs::write(&path, "[Desktop Entry]\nHidden=true\n").map_err(|e| e.to_string())?;
    }
    let mut config = state.config.lock().unwrap();
    config.start_at_login = enabled;
    config.save().map_err(|e| e.to_string())
}
