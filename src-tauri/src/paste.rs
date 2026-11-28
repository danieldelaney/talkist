use anyhow::Result;

#[cfg(target_os = "linux")]
pub use wayland::WaylandPaster as WaylandPasteHandle;

#[cfg(not(target_os = "linux"))]
#[derive(Clone)]
pub struct WaylandPasteHandle;

#[cfg(not(target_os = "linux"))]
impl WaylandPasteHandle {
    pub fn spawn(_on_change: impl Fn() + Send + Sync + 'static) -> Self {
        Self
    }
    pub fn authorize(&self) {}
    pub fn needs_permission(&self) -> bool {
        false
    }
    pub fn is_authorized(&self) -> bool {
        true
    }
}

/// Clipboard handle + key synthesizer. Keep one alive for the process
/// lifetime so clipboard ownership keeps serving paste requests.
pub struct Paster {
    backend: Backend,
}

enum Backend {
    X11 {
        clip: arboard::Clipboard,
    },
    #[cfg(target_os = "linux")]
    Wayland(wayland::WaylandPaster),
}

impl Paster {
    pub fn new(wayland: Option<WaylandPasteHandle>) -> Result<Self> {
        #[cfg(target_os = "linux")]
        if crate::portal::session_is_wayland() {
            let wp = wayland.unwrap_or_else(|| wayland::WaylandPaster::spawn(|| {}));
            return Ok(Self {
                backend: Backend::Wayland(wp),
            });
        }
        let _ = wayland;
        Ok(Self {
            backend: Backend::X11 {
                clip: arboard::Clipboard::new()?,
            },
        })
    }

    /// Copy `text` to the clipboard and synthesize Ctrl+V at the cursor.
    pub fn paste(&mut self, text: &str) -> Result<()> {
        match &mut self.backend {
            Backend::X11 { clip } => paste_x11(clip, text),
            #[cfg(target_os = "linux")]
            Backend::Wayland(wp) => wp.paste(text),
        }
    }
}

enum SavedClipboard {
    Text(String),
    Image(arboard::ImageData<'static>),
    Empty,
}

fn save_clipboard(clip: &mut arboard::Clipboard) -> SavedClipboard {
    if let Ok(text) = clip.get_text() {
        return SavedClipboard::Text(text);
    }
    if let Ok(img) = clip.get_image() {
        return SavedClipboard::Image(img.to_owned_img());
    }
    SavedClipboard::Empty
}

fn restore_clipboard(clip: &mut arboard::Clipboard, saved: SavedClipboard) {
    match saved {
        SavedClipboard::Text(text) => {
            let _ = clip.set_text(text);
        }
        SavedClipboard::Image(img) => {
            let _ = clip.set_image(img);
        }
        SavedClipboard::Empty => {
            let _ = clip.clear();
        }
    }
}

fn is_terminal_class(name: &str) -> bool {
    matches!(
        name.to_ascii_lowercase().as_str(),
        "gnome-terminal"
            | "gnome-terminal-server"
            | "kgx"
            | "org.gnome.console"
            | "ptyxis"
            | "org.gnome.ptyxis"
            | "alacritty"
            | "kitty"
            | "wezterm"
            | "org.wezfurlong.wezterm"
            | "foot"
            | "konsole"
            | "xfce4-terminal"
            | "mate-terminal"
            | "tilix"
            | "terminator"
            | "urxvt"
            | "rxvt"
            | "xterm"
            | "uxterm"
            | "st"
            | "st-256color"
            | "ghostty"
            | "com.mitchellh.ghostty"
            | "rio"
            | "warp"
            | "dev.warp.warp"
            | "hyper"
            | "tabby"
            | "sakura"
            | "lxterminal"
            | "qterminal"
            | "guake"
            | "tilda"
            | "yakuake"
            | "cool-retro-term"
            | "terminology"
            | "blackbox"
            | "contour"
            | "zutty"
    )
}

#[cfg(target_os = "linux")]
fn focused_x11_is_terminal() -> bool {
    use std::ffi::CStr;
    use x11_dl::xlib::{XClassHint, Xlib};

    let Ok(xlib) = Xlib::open() else {
        return false;
    };
    unsafe {
        let display = (xlib.XOpenDisplay)(std::ptr::null());
        if display.is_null() {
            return false;
        }
        let mut focus: std::os::raw::c_ulong = 0;
        let mut revert: std::os::raw::c_int = 0;
        (xlib.XGetInputFocus)(display, &mut focus, &mut revert);

        let mut win = focus;
        let mut found = false;
        while win > 1 {
            let mut hint = XClassHint {
                res_name: std::ptr::null_mut(),
                res_class: std::ptr::null_mut(),
            };
            if (xlib.XGetClassHint)(display, win, &mut hint) != 0 {
                if !hint.res_name.is_null() {
                    if let Ok(s) = CStr::from_ptr(hint.res_name).to_str() {
                        if is_terminal_class(s) {
                            found = true;
                        }
                    }
                    (xlib.XFree)(hint.res_name as *mut _);
                }
                if !hint.res_class.is_null() {
                    if let Ok(s) = CStr::from_ptr(hint.res_class).to_str() {
                        if is_terminal_class(s) {
                            found = true;
                        }
                    }
                    (xlib.XFree)(hint.res_class as *mut _);
                }
                break;
            }
            let mut root: std::os::raw::c_ulong = 0;
            let mut parent: std::os::raw::c_ulong = 0;
            let mut children: *mut std::os::raw::c_ulong = std::ptr::null_mut();
            let mut nchildren: std::os::raw::c_uint = 0;
            if (xlib.XQueryTree)(
                display,
                win,
                &mut root,
                &mut parent,
                &mut children,
                &mut nchildren,
            ) == 0
            {
                break;
            }
            if !children.is_null() {
                (xlib.XFree)(children as *mut _);
            }
            if parent == 0 || parent == root || parent == win {
                break;
            }
            win = parent;
        }

        (xlib.XCloseDisplay)(display);
        found
    }
}

#[cfg(not(target_os = "linux"))]
fn focused_x11_is_terminal() -> bool {
    false
}

fn paste_x11(clip: &mut arboard::Clipboard, text: &str) -> Result<()> {
    use enigo::{Direction, Enigo, Key, Keyboard, Settings};
    use std::time::Duration;

    let saved = save_clipboard(clip);
    let use_shift = focused_x11_is_terminal();

    clip.set_text(text.to_string())?;
    let mut en = Enigo::new(&Settings::default())?;
    std::thread::sleep(Duration::from_millis(20));
    en.key(Key::Control, Direction::Press)?;
    if use_shift {
        en.key(Key::Shift, Direction::Press)?;
    }
    std::thread::sleep(Duration::from_millis(10));
    en.key(Key::Unicode('v'), Direction::Click)?;
    std::thread::sleep(Duration::from_millis(10));
    if use_shift {
        en.key(Key::Shift, Direction::Release)?;
    }
    en.key(Key::Control, Direction::Release)?;
    // Give the target app time to fetch our selection before restoring the
    // user's previous clipboard contents; skip if something else wrote to it.
    std::thread::sleep(Duration::from_millis(150));
    if clip.get_text().ok().as_deref() == Some(text) {
        restore_clipboard(clip, saved);
    }
    Ok(())
}

#[cfg(target_os = "linux")]
mod wayland {
    use crate::portal::imp::{
        align_request, close_session, next_response, next_token, parse_session_handle,
        prepare_request, register_host_app, with_timeout, PortalSessionProxy,
    };
    use anyhow::{anyhow, Context, Result};
    use futures_util::future::{join, select, Either};
    use futures_util::StreamExt;
    use std::collections::HashMap;
    use std::io::Write;
    use std::path::PathBuf;
    use std::process::{Command, Stdio};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;
    use zbus::proxy;
    use zbus::zvariant::{ObjectPath, OwnedFd, OwnedObjectPath, Value};

    const DEVICE_KEYBOARD: u32 = 1;
    const PERSIST_UNTIL_REVOKED: u32 = 2;
    const KEY_RELEASED: u32 = 0;
    const KEY_PRESSED: u32 = 1;

    enum PasteCmd {
        Paste {
            text: String,
            reply: std::sync::mpsc::SyncSender<Result<()>>,
        },
        Authorize,
    }

    struct WaylandPasteStatus {
        portal_supported: AtomicBool,
        authorized: AtomicBool,
    }

    #[derive(Clone)]
    pub struct WaylandPaster {
        tx: async_channel::Sender<PasteCmd>,
        status: Arc<WaylandPasteStatus>,
    }

    impl WaylandPaster {
        pub fn spawn(on_change: impl Fn() + Send + Sync + 'static) -> Self {
            let (tx, rx) = async_channel::unbounded();
            let has_token = load_restore_token().is_some();
            let status = Arc::new(WaylandPasteStatus {
                portal_supported: AtomicBool::new(true),
                authorized: AtomicBool::new(has_token),
            });
            let status_for_thread = status.clone();
            let notify: Arc<dyn Fn() + Send + Sync> = Arc::new(on_change);
            std::thread::Builder::new()
                .name("wayland-paste".into())
                .spawn(move || {
                    if let Err(e) = run(rx, status_for_thread, notify) {
                        eprintln!("wayland paster stopped: {e:#}");
                    }
                })
                .expect("failed to spawn wayland-paste thread");
            Self { tx, status }
        }

        pub fn authorize(&self) {
            let _ = self.tx.try_send(PasteCmd::Authorize);
        }

        pub fn needs_permission(&self) -> bool {
            self.status.portal_supported.load(Ordering::Relaxed)
        }

        pub fn is_authorized(&self) -> bool {
            self.status.authorized.load(Ordering::Relaxed)
        }

        pub fn paste(&self, text: &str) -> Result<()> {
            if !self.status.portal_supported.load(Ordering::Relaxed) {
                return paste_wlroots_fallback(text);
            }
            let (reply_tx, reply_rx) = std::sync::mpsc::sync_channel(1);
            self.tx
                .try_send(PasteCmd::Paste {
                    text: text.to_string(),
                    reply: reply_tx,
                })
                .map_err(|e| anyhow!("wayland paster unavailable: {e}"))?;
            reply_rx
                .recv()
                .map_err(|_| anyhow!("wayland paster exited before replying"))?
        }
    }

    /// Fallback for wlroots compositors (Sway, Hyprland, Niri) that do not
    /// implement `org.freedesktop.portal.RemoteDesktop`. Uses `wtype` for direct
    /// typing if installed, otherwise copies to the Wayland clipboard via `wl-copy`.
    fn paste_wlroots_fallback(text: &str) -> Result<()> {
        if let Ok(status) = Command::new("wtype").args(["--", text]).status() {
            if status.success() {
                return Ok(());
            }
        }
        if let Ok(mut child) = Command::new("wl-copy").stdin(Stdio::piped()).spawn() {
            if let Some(mut stdin) = child.stdin.take() {
                let _ = stdin.write_all(text.as_bytes());
            }
            if child.wait().map(|s| s.success()).unwrap_or(false) {
                eprintln!(
                    "RemoteDesktop portal unavailable; copied transcript to clipboard (install wtype for direct typing)"
                );
                return Ok(());
            }
        }
        Err(anyhow!(
            "RemoteDesktop portal unavailable and neither wtype nor wl-copy is installed"
        ))
    }

    #[proxy(
        interface = "org.freedesktop.portal.RemoteDesktop",
        default_service = "org.freedesktop.portal.Desktop",
        default_path = "/org/freedesktop/portal/desktop"
    )]
    trait RemoteDesktop {
        #[zbus(property, name = "AvailableDeviceTypes")]
        fn available_device_types(&self) -> zbus::Result<u32>;

        fn create_session(
            &self,
            options: HashMap<&str, Value<'_>>,
        ) -> zbus::Result<OwnedObjectPath>;

        fn select_devices(
            &self,
            session_handle: ObjectPath<'_>,
            options: HashMap<&str, Value<'_>>,
        ) -> zbus::Result<OwnedObjectPath>;

        fn start(
            &self,
            session_handle: ObjectPath<'_>,
            parent_window: &str,
            options: HashMap<&str, Value<'_>>,
        ) -> zbus::Result<OwnedObjectPath>;

        fn notify_keyboard_keysym(
            &self,
            session_handle: ObjectPath<'_>,
            options: HashMap<&str, Value<'_>>,
            keysym: i32,
            state: u32,
        ) -> zbus::Result<()>;
    }

    #[proxy(
        interface = "org.freedesktop.portal.Clipboard",
        default_service = "org.freedesktop.portal.Desktop",
        default_path = "/org/freedesktop/portal/desktop"
    )]
    trait ClipboardPortal {
        fn request_clipboard(
            &self,
            session_handle: ObjectPath<'_>,
            options: HashMap<&str, Value<'_>>,
        ) -> zbus::Result<()>;

        fn set_selection(
            &self,
            session_handle: ObjectPath<'_>,
            options: HashMap<&str, Value<'_>>,
        ) -> zbus::Result<()>;

        fn selection_write(
            &self,
            session_handle: ObjectPath<'_>,
            serial: u32,
        ) -> zbus::Result<OwnedFd>;

        fn selection_write_done(
            &self,
            session_handle: ObjectPath<'_>,
            serial: u32,
            success: bool,
        ) -> zbus::Result<()>;

        #[zbus(signal)]
        fn selection_transfer(
            &self,
            session_handle: OwnedObjectPath,
            mime_type: String,
            serial: u32,
        ) -> zbus::Result<()>;
    }

    struct ActiveSession {
        path: OwnedObjectPath,
        clipboard_enabled: bool,
    }

    fn token_path() -> Option<PathBuf> {
        dirs::data_dir()
            .or_else(dirs::config_dir)
            .map(|d| d.join("talkist/remote-desktop-token"))
    }

    fn load_restore_token() -> Option<String> {
        let p = token_path()?;
        let s = std::fs::read_to_string(p).ok()?;
        let trimmed = s.trim();
        (!trimmed.is_empty()).then(|| trimmed.to_string())
    }

    fn save_restore_token(token: Option<&str>) {
        let Some(p) = token_path() else { return };
        match token {
            Some(t) if !t.is_empty() => {
                if let Some(parent) = p.parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                if let Err(e) = std::fs::write(&p, t) {
                    eprintln!("saving RemoteDesktop restore token failed: {e}");
                }
            }
            _ => {
                let _ = std::fs::remove_file(&p);
            }
        }
    }

    async fn open_session(
        conn: &zbus::Connection,
        rd: &RemoteDesktopProxy<'_>,
        cb: &ClipboardPortalProxy<'_>,
        restore_token: &mut Option<String>,
    ) -> Result<(ActiveSession, crate::portal::imp::ClosedStream, bool)> {
        // 1. CreateSession
        let handle_token = next_token("rd_create");
        let session_token = next_token("rd_sess");
        let (expected, stream) = prepare_request(conn, &handle_token).await?;
        let mut opts = HashMap::new();
        opts.insert("handle_token", Value::from(handle_token.as_str()));
        opts.insert("session_handle_token", Value::from(session_token.as_str()));
        let actual = rd
            .create_session(opts)
            .await
            .context("RemoteDesktop.CreateSession failed")?;
        let mut stream = align_request(conn, expected, stream, actual).await?;
        let (code, mut results) =
            match with_timeout(Duration::from_secs(10), next_response(&mut stream)).await {
                Some(Ok(r)) => r,
                Some(Err(e)) => return Err(anyhow!("RemoteDesktop.CreateSession error: {e:#}")),
                None => return Err(anyhow!("RemoteDesktop.CreateSession timed out")),
            };
        if code != 0 {
            return Err(anyhow!("RemoteDesktop.CreateSession rejected ({code})"));
        }
        let session_path = parse_session_handle(&mut results)?;

        let sess_proxy = PortalSessionProxy::builder(conn)
            .path(session_path.clone())?
            .build()
            .await?;
        let closed_stream = sess_proxy.receive_closed().await?;

        // 2. SelectDevices (KEYBOARD + persist until revoked + restore_token)
        let had_token = restore_token.is_some();
        let handle_token = next_token("rd_select");
        let (expected, stream) = prepare_request(conn, &handle_token).await?;
        let mut opts = HashMap::new();
        opts.insert("handle_token", Value::from(handle_token.as_str()));
        opts.insert("types", Value::from(DEVICE_KEYBOARD));
        opts.insert("persist_mode", Value::from(PERSIST_UNTIL_REVOKED));
        if let Some(ref tok) = restore_token {
            opts.insert("restore_token", Value::from(tok.as_str()));
        }
        let actual = rd
            .select_devices(session_path.as_ref(), opts)
            .await
            .context("RemoteDesktop.SelectDevices failed")?;
        let mut stream = align_request(conn, expected, stream, actual).await?;
        let (code, _) =
            match with_timeout(Duration::from_secs(10), next_response(&mut stream)).await {
                Some(Ok(r)) => r,
                Some(Err(e)) => {
                    close_session(conn, &session_path).await;
                    return Err(anyhow!("RemoteDesktop.SelectDevices error: {e:#}"));
                }
                None => {
                    close_session(conn, &session_path).await;
                    return Err(anyhow!("RemoteDesktop.SelectDevices timed out"));
                }
            };
        if code != 0 {
            close_session(conn, &session_path).await;
            return Err(anyhow!("RemoteDesktop.SelectDevices rejected ({code})"));
        }

        // 3. RequestClipboard on the same session (best-effort; falls back to
        // direct keystroke typing if unsupported or declined).
        if let Err(e) = cb.request_clipboard(session_path.as_ref(), HashMap::new()).await {
            eprintln!("Clipboard portal unavailable for RemoteDesktop session: {e}");
        }

        // 4. Start (silent if restore_token is valid; otherwise shows GNOME's
        // one-time Remote Desktop permission dialog).
        let handle_token = next_token("rd_start");
        let (expected, stream) = prepare_request(conn, &handle_token).await?;
        let mut opts = HashMap::new();
        opts.insert("handle_token", Value::from(handle_token.as_str()));
        let actual = rd
            .start(session_path.as_ref(), "", opts)
            .await
            .context("RemoteDesktop.Start failed")?;
        let mut stream = align_request(conn, expected, stream, actual).await?;
        let (code, results) = next_response(&mut stream).await?;
        if code != 0 {
            close_session(conn, &session_path).await;
            if had_token {
                *restore_token = None;
                save_restore_token(None);
            }
            return Err(anyhow!("RemoteDesktop permission declined ({code})"));
        }

        // Restore tokens are single-use; persist the newly issued one right away.
        let new_token = results
            .get("restore_token")
            .and_then(|v| v.try_clone().ok())
            .and_then(|v| String::try_from(v).ok());
        if let Some(tok) = new_token {
            save_restore_token(Some(&tok));
            *restore_token = Some(tok);
        } else if had_token {
            *restore_token = None;
            save_restore_token(None);
        }

        let devices = results
            .get("devices")
            .and_then(|v| v.try_clone().ok())
            .and_then(|v| u32::try_from(v).ok())
            .unwrap_or(0);
        if devices & DEVICE_KEYBOARD == 0 {
            close_session(conn, &session_path).await;
            return Err(anyhow!("RemoteDesktop session granted no keyboard access"));
        }

        let clipboard_enabled = results
            .get("clipboard_enabled")
            .and_then(|v| v.try_clone().ok())
            .and_then(|v| bool::try_from(v).ok())
            .unwrap_or(false);

        eprintln!(
            "wayland RemoteDesktop session ready (clipboard_enabled={clipboard_enabled})"
        );
        let prompted = !had_token;
        Ok((
            ActiveSession {
                path: session_path,
                clipboard_enabled,
            },
            closed_stream,
            prompted,
        ))
    }

    fn is_text_mime(mime: &str) -> bool {
        matches!(
            mime,
            "text/plain;charset=utf-8" | "text/plain" | "UTF8_STRING" | "STRING" | "TEXT"
        )
    }

    fn char_to_keysym(c: char) -> Option<i32> {
        match c {
            '\n' | '\r' => Some(0xff0d), // XK_Return
            '\t' => Some(0xff09),        // XK_Tab
            // XKB keysyms match Unicode code points directly for ASCII
            // printable and Latin-1 Supplement (0x00a0..=0x00ff).
            '\u{0020}'..='\u{007e}' | '\u{00a0}'..='\u{00ff}' => Some(c as i32),
            c if (c as u32) >= 0x100 => Some((0x0100_0000 | (c as u32)) as i32),
            _ => None,
        }
    }

    async fn type_keysyms(
        rd: &RemoteDesktopProxy<'_>,
        session: &OwnedObjectPath,
        text: &str,
    ) -> Result<()> {
        let empty: HashMap<&str, Value<'_>> = HashMap::new();
        for ch in text.chars() {
            if let Some(sym) = char_to_keysym(ch) {
                rd.notify_keyboard_keysym(session.as_ref(), empty.clone(), sym, KEY_PRESSED)
                    .await?;
                rd.notify_keyboard_keysym(session.as_ref(), empty.clone(), sym, KEY_RELEASED)
                    .await?;
                async_io::Timer::after(Duration::from_millis(1)).await;
            }
        }
        Ok(())
    }

    fn run(
        rx: async_channel::Receiver<PasteCmd>,
        status: Arc<WaylandPasteStatus>,
        notify: Arc<dyn Fn() + Send + Sync>,
    ) -> Result<()> {
        async_io::block_on(async {
            let conn = zbus::Connection::session()
                .await
                .context("cannot connect to session bus for Wayland pasting")?;
            register_host_app(&conn).await;

            let rd = RemoteDesktopProxy::new(&conn)
                .await
                .context("RemoteDesktop portal unavailable")?;
            let cb = ClipboardPortalProxy::new(&conn)
                .await
                .context("Clipboard portal unavailable")?;

            // Probe whether this compositor implements RemoteDesktop keyboard
            // input (GNOME, KDE) vs. wlroots (Sway, Hyprland) where we should
            // fall back to wtype/wl-copy without showing a broken permission row.
            let supported = rd
                .available_device_types()
                .await
                .map(|mask| (mask & DEVICE_KEYBOARD) != 0)
                .unwrap_or(false);
            status.portal_supported.store(supported, Ordering::Relaxed);
            if !supported {
                eprintln!("RemoteDesktop portal keyboard input unavailable; will use wtype/wl-copy fallback");
                status.authorized.store(true, Ordering::Relaxed);
                notify();
                return Ok(());
            }

            let mut transfers = cb.receive_selection_transfer().await?;

            let clipboard_text = Arc::new(Mutex::new(String::new()));
            let active_path: Arc<Mutex<Option<OwnedObjectPath>>> = Arc::new(Mutex::new(None));

            // Task 1: continuously serve Clipboard SelectionTransfer signals so
            // apps pasting our clipboard offer never stall or time out.
            let cb_for_transfers = cb.clone();
            let text_for_transfers = clipboard_text.clone();
            let path_for_transfers = active_path.clone();
            let transfer_loop = async move {
                while let Some(sig) = transfers.next().await {
                    let Ok(args) = sig.args() else { continue };
                    let current = path_for_transfers.lock().unwrap().clone();
                    if current.as_ref() != Some(&args.session_handle) {
                        continue;
                    }
                    if !is_text_mime(&args.mime_type) {
                        let _ = cb_for_transfers
                            .selection_write_done(args.session_handle.as_ref(), args.serial, false)
                            .await;
                        continue;
                    }
                    let payload = text_for_transfers.lock().unwrap().clone();
                    match cb_for_transfers
                        .selection_write(args.session_handle.as_ref(), args.serial)
                        .await
                    {
                        Ok(fd) => {
                            let std_fd: std::os::fd::OwnedFd = fd.into();
                            let mut file = std::fs::File::from(std_fd);
                            let ok = file.write_all(payload.as_bytes()).is_ok();
                            drop(file);
                            let _ = cb_for_transfers
                                .selection_write_done(args.session_handle.as_ref(), args.serial, ok)
                                .await;
                        }
                        Err(e) => {
                            eprintln!("Clipboard SelectionWrite failed: {e}");
                            let _ = cb_for_transfers
                                .selection_write_done(
                                    args.session_handle.as_ref(),
                                    args.serial,
                                    false,
                                )
                                .await;
                        }
                    }
                }
            };

            // Task 2: manage RemoteDesktop session lifetime and execute paste jobs.
            let paste_loop = async move {
                let mut restore_token = load_restore_token();
                let mut session: Option<(ActiveSession, crate::portal::imp::ClosedStream)> = None;

                // If we already have a saved restore token, silently restore
                // the session at startup so the first paste has zero delay.
                if restore_token.is_some() {
                    match open_session(&conn, &rd, &cb, &mut restore_token).await {
                        Ok((sess, closed, _)) => {
                            *active_path.lock().unwrap() = Some(sess.path.clone());
                            session = Some((sess, closed));
                            status.authorized.store(true, Ordering::Relaxed);
                            notify();
                        }
                        Err(e) => {
                            eprintln!("silent RemoteDesktop restore failed: {e:#}");
                            status.authorized.store(false, Ordering::Relaxed);
                            notify();
                        }
                    }
                }

                loop {
                    // Wait for either the next command or Session::Closed.
                    let cmd = if let Some((_, ref mut closed_stream)) = session {
                        match select(Box::pin(rx.recv()), Box::pin(closed_stream.next())).await {
                            Either::Left((Ok(cmd), _)) => cmd,
                            Either::Left((Err(_), _)) => break,
                            Either::Right(_) => {
                                eprintln!("RemoteDesktop session closed");
                                *active_path.lock().unwrap() = None;
                                session = None;
                                continue;
                            }
                        }
                    } else {
                        match rx.recv().await {
                            Ok(cmd) => cmd,
                            Err(_) => break,
                        }
                    };

                    match cmd {
                        PasteCmd::Authorize => {
                            if session.is_some() {
                                status.authorized.store(true, Ordering::Relaxed);
                                notify();
                                continue;
                            }
                            match open_session(&conn, &rd, &cb, &mut restore_token).await {
                                Ok((sess, closed, _)) => {
                                    *active_path.lock().unwrap() = Some(sess.path.clone());
                                    session = Some((sess, closed));
                                    status.authorized.store(true, Ordering::Relaxed);
                                    notify();
                                }
                                Err(e) => {
                                    eprintln!("RemoteDesktop authorization failed: {e:#}");
                                    status.authorized.store(false, Ordering::Relaxed);
                                    notify();
                                }
                            }
                        }
                        PasteCmd::Paste { text, reply } => {
                            let result = async {
                                if session.is_none() {
                                    let (sess, closed, prompted) =
                                        open_session(&conn, &rd, &cb, &mut restore_token).await?;
                                    *active_path.lock().unwrap() = Some(sess.path.clone());
                                    session = Some((sess, closed));
                                    status.authorized.store(true, Ordering::Relaxed);
                                    notify();
                                    if prompted {
                                        // Give GNOME a moment to return focus to the
                                        // target window after the permission dialog closes.
                                        async_io::Timer::after(Duration::from_millis(200)).await;
                                    }
                                }

                                let (ref sess, _) = session.as_ref().unwrap();
                                // Type directly via RemoteDesktop keysyms rather than
                                // Ctrl+V so dictation works in terminals (which bind
                                // Ctrl+Shift+V) as well as browsers and editors,
                                // without clobbering the user's clipboard.
                                let _ = sess.clipboard_enabled;
                                type_keysyms(&rd, &sess.path, &text).await?;
                                Ok::<(), anyhow::Error>(())
                            }
                            .await;

                            if result.is_err() {
                                // Drop a broken session so the next utterance retries cleanly.
                                if let Some((old, _)) = session.take() {
                                    *active_path.lock().unwrap() = None;
                                    close_session(&conn, &old.path).await;
                                }
                            }
                            let _ = reply.send(result);
                        }
                    }
                }
            };

            join(transfer_loop, paste_loop).await;
            Ok(())
        })
    }

    #[cfg(test)]
    mod tests {
        use super::char_to_keysym;
        use crate::paste::is_terminal_class;

        #[test]
        fn keysym_mapping() {
            assert_eq!(char_to_keysym('a'), Some(0x61));
            assert_eq!(char_to_keysym('A'), Some(0x41));
            assert_eq!(char_to_keysym('?'), Some(0x3f));
            assert_eq!(char_to_keysym('é'), Some(0xe9));
            assert_eq!(char_to_keysym('\n'), Some(0xff0d));
            assert_eq!(char_to_keysym('—'), Some(0x0100_2014));
        }

        #[test]
        fn terminal_class_detection() {
            assert!(is_terminal_class("Gnome-terminal"));
            assert!(is_terminal_class("kitty"));
            assert!(is_terminal_class("Alacritty"));
            assert!(is_terminal_class("com.mitchellh.ghostty"));
            assert!(!is_terminal_class("firefox"));
            assert!(!is_terminal_class("Code"));
        }
    }
}
