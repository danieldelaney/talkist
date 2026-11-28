// Wayland global hotkeys via the XDG GlobalShortcuts portal.
//
// On X11 the global-shortcut plugin grabs keys with XGrabKey. Under Wayland
// sessions the compositor owns global shortcuts, so we open a single
// org.freedesktop.portal.GlobalShortcuts session, bind our push-to-talk
// action, and listen for Activated / Deactivated / ShortcutsChanged signals on
// org.freedesktop.portal.GlobalShortcuts (/org/freedesktop/portal/desktop).

/// Requests sent to the portal thread.
pub enum PortalMsg {
    /// Open the compositor's shortcut configuration UI (or re-run BindShortcuts
    /// if nothing has been bound yet).
    Configure,
}

pub use imp::{spawn, PortalHandle};

#[cfg(target_os = "linux")]
mod imp {
    use super::PortalMsg;
    use crate::audio::Cmd;
    use crate::portal::imp::{
        align_request, close_session, next_response, next_token, parse_session_handle,
        prepare_request, register_host_app, with_timeout, PortalSessionProxy,
    };
    use anyhow::{anyhow, Context, Result};
    use futures_util::future::{select, Either};
    use futures_util::StreamExt;
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex};
    use std::time::Duration;
    use tauri::{AppHandle, Manager};
    use zbus::proxy;
    use zbus::zvariant::{ObjectPath, OwnedObjectPath, OwnedValue, Value};

    const SHORTCUT_ID: &str = "talkist-hotkey";
    const NOT_SET_LABEL: &str = "Not set";

    pub struct PortalHandle {
        tx: async_channel::Sender<PortalMsg>,
        display: Arc<Mutex<String>>,
    }

    impl PortalHandle {
        pub fn send(&self, msg: PortalMsg) {
            if let Err(e) = self.tx.try_send(msg) {
                eprintln!("portal request dropped: {e}");
            }
        }

        /// The trigger description currently active in the compositor.
        pub fn display(&self) -> String {
            self.display.lock().unwrap().clone()
        }
    }

    pub fn spawn(app: AppHandle, hotkey: String) -> PortalHandle {
        let (tx, rx) = async_channel::unbounded();
        let display = Arc::new(Mutex::new(hotkey.clone()));
        let handle = PortalHandle {
            tx,
            display: display.clone(),
        };
        std::thread::Builder::new()
            .name("portal-hotkey".into())
            .spawn(move || {
                if let Err(e) = run(app, rx, display, hotkey) {
                    eprintln!("global shortcut portal stopped: {e:#}");
                }
            })
            .expect("failed to spawn the portal hotkey thread");
        handle
    }

    #[proxy(
        interface = "org.freedesktop.portal.GlobalShortcuts",
        default_service = "org.freedesktop.portal.Desktop",
        default_path = "/org/freedesktop/portal/desktop"
    )]
    trait GlobalShortcuts {
        fn create_session(
            &self,
            options: HashMap<&str, Value<'_>>,
        ) -> zbus::Result<OwnedObjectPath>;

        fn bind_shortcuts(
            &self,
            session_handle: ObjectPath<'_>,
            shortcuts: Vec<(String, HashMap<String, Value<'_>>)>,
            parent_window: &str,
            options: HashMap<&str, Value<'_>>,
        ) -> zbus::Result<OwnedObjectPath>;

        fn configure_shortcuts(
            &self,
            session_handle: ObjectPath<'_>,
            parent_window: &str,
            options: HashMap<&str, Value<'_>>,
        ) -> zbus::Result<()>;

        #[zbus(property, name = "version")]
        fn version(&self) -> zbus::Result<u32>;

        #[zbus(signal)]
        fn activated(
            &self,
            session_handle: OwnedObjectPath,
            shortcut_id: String,
            timestamp: u64,
            options: HashMap<String, OwnedValue>,
        ) -> zbus::Result<()>;

        #[zbus(signal)]
        fn deactivated(
            &self,
            session_handle: OwnedObjectPath,
            shortcut_id: String,
            timestamp: u64,
            options: HashMap<String, OwnedValue>,
        ) -> zbus::Result<()>;

        #[zbus(signal)]
        fn shortcuts_changed(
            &self,
            session_handle: OwnedObjectPath,
            shortcuts: Vec<(String, HashMap<String, OwnedValue>)>,
        ) -> zbus::Result<()>;
    }

    fn send_cmd(app: &AppHandle, cmd: Cmd) {
        let state = app.state::<crate::AppState>();
        let Some(tx) = state.cmds.lock().unwrap().clone() else {
            return;
        };
        let _ = tx.send(cmd);
    }

    fn update_display(app: &AppHandle, display: &Arc<Mutex<String>>, trigger: Option<String>) {
        let label = match trigger
            .as_deref()
            .map(str::trim)
            .map(|s| s.strip_prefix("Press ").unwrap_or(s).trim())
            .filter(|s| !s.is_empty())
        {
            Some(s) => s.to_string(),
            None => NOT_SET_LABEL.to_string(),
        };
        *display.lock().unwrap() = label.clone();
        crate::update_tray_hotkey(app, &label);
    }

    /// Convert Talkist's X11/Tauri hotkey notation to the XDG shortcuts spec
    /// format (CTRL / ALT / SHIFT / LOGO + XKB keysym name).
    fn to_xdg_trigger(hotkey: &str) -> String {
        let mut out = Vec::new();
        for part in hotkey.split('+').map(str::trim).filter(|s| !s.is_empty()) {
            let mapped = match part.to_ascii_lowercase().as_str() {
                "ctrl" | "control" => "CTRL".to_string(),
                "alt" => "ALT".to_string(),
                "shift" => "SHIFT".to_string(),
                "super" | "meta" | "logo" | "cmd" | "command" => "LOGO".to_string(),
                "space" | " " => "space".to_string(),
                "capslock" | "caps_lock" => "Caps_Lock".to_string(),
                "enter" | "return" => "Return".to_string(),
                "backspace" => "BackSpace".to_string(),
                "escape" | "esc" => "Escape".to_string(),
                "tab" => "Tab".to_string(),
                "\\" | "backslash" => "backslash".to_string(),
                "/" | "slash" => "slash".to_string(),
                "`" | "backquote" => "grave".to_string(),
                "-" | "minus" => "minus".to_string(),
                "=" | "equal" => "equal".to_string(),
                "[" | "bracketleft" => "bracketleft".to_string(),
                "]" | "bracketright" => "bracketright".to_string(),
                ";" | "semicolon" => "semicolon".to_string(),
                "'" | "quote" => "apostrophe".to_string(),
                "," | "comma" => "comma".to_string(),
                "." | "period" => "period".to_string(),
                _ if part.len() == 1 && part.as_bytes()[0].is_ascii_alphabetic() => {
                    part.to_ascii_lowercase()
                }
                _ => part.to_string(),
            };
            out.push(mapped);
        }
        out.join("+")
    }

    fn extract_trigger_from_list(
        shortcuts: &[(String, HashMap<String, OwnedValue>)],
    ) -> Option<String> {
        for (id, props) in shortcuts {
            if id == SHORTCUT_ID {
                if let Some(val) = props.get("trigger_description") {
                    if let Ok(desc) = String::try_from(val.try_clone().ok()?) {
                        return Some(desc);
                    }
                }
            }
        }
        None
    }

    fn extract_trigger_from_results(results: &HashMap<String, OwnedValue>) -> Option<String> {
        let val = results.get("shortcuts")?.try_clone().ok()?;
        let list = Vec::<(String, HashMap<String, OwnedValue>)>::try_from(val).ok()?;
        extract_trigger_from_list(&list)
    }

    async fn create_session(
        conn: &zbus::Connection,
        portal: &GlobalShortcutsProxy<'_>,
    ) -> Result<OwnedObjectPath> {
        let handle_token = next_token("gs_create");
        let session_token = next_token("gs_sess");
        let (expected, stream) = prepare_request(conn, &handle_token).await?;

        let mut opts = HashMap::new();
        opts.insert("handle_token", Value::from(handle_token.as_str()));
        opts.insert("session_handle_token", Value::from(session_token.as_str()));
        let actual = portal
            .create_session(opts)
            .await
            .context("CreateSession failed")?;
        let mut stream = align_request(conn, expected, stream, actual).await?;

        let (code, mut results) =
            match with_timeout(Duration::from_secs(10), next_response(&mut stream)).await {
                Some(Ok(r)) => r,
                Some(Err(e)) => return Err(anyhow!("CreateSession response error: {e:#}")),
                None => return Err(anyhow!("CreateSession timed out")),
            };
        if code != 0 {
            return Err(anyhow!("CreateSession rejected ({code})"));
        }
        parse_session_handle(&mut results)
    }

    /// Call BindShortcuts on a newly created session. Returns `Ok(Some(trigger))`
    /// when bound, or `Ok(None)` when cancelled/declined.
    async fn bind_session(
        conn: &zbus::Connection,
        portal: &GlobalShortcutsProxy<'_>,
        session_path: &OwnedObjectPath,
        preferred_hotkey: &str,
    ) -> Result<Option<Option<String>>> {
        let handle_token = next_token("gs_bind");
        let (expected, stream) = prepare_request(conn, &handle_token).await?;

        let mut props = HashMap::new();
        props.insert("description".to_string(), Value::from("Push to talk"));
        let xdg_trigger = to_xdg_trigger(preferred_hotkey);
        if !xdg_trigger.is_empty() {
            props.insert("preferred_trigger".to_string(), Value::from(xdg_trigger));
        }

        let mut opts = HashMap::new();
        opts.insert("handle_token", Value::from(handle_token.as_str()));

        let actual = portal
            .bind_shortcuts(
                session_path.as_ref(),
                vec![(SHORTCUT_ID.to_string(), props)],
                "",
                opts,
            )
            .await
            .context("BindShortcuts failed")?;
        let mut stream = align_request(conn, expected, stream, actual).await?;

        let (code, results) = next_response(&mut stream).await?;
        if code == 0 {
            Ok(Some(extract_trigger_from_results(&results)))
        } else {
            eprintln!("BindShortcuts declined/failed with response {code}");
            Ok(None)
        }
    }

    fn run(
        app: AppHandle,
        rx: async_channel::Receiver<PortalMsg>,
        display: Arc<Mutex<String>>,
        preferred_hotkey: String,
    ) -> Result<()> {
        async_io::block_on(async {
            let conn = zbus::Connection::session()
                .await
                .context("cannot connect to the session bus")?;
            register_host_app(&conn).await;

            let portal = GlobalShortcutsProxy::new(&conn)
                .await
                .context("GlobalShortcuts portal unavailable")?;
            let portal_version = match portal.version().await {
                Ok(v) => v,
                Err(e) => {
                    eprintln!("GlobalShortcuts version query failed: {e}");
                    1
                }
            };
            eprintln!("GlobalShortcuts portal ready (v{portal_version})");

            // Subscribe on org.freedesktop.portal.GlobalShortcuts BEFORE
            // binding so no Activated/Deactivated/ShortcutsChanged signal can
            // ever be missed.
            let mut activated = portal.receive_activated().await?;
            let mut deactivated = portal.receive_deactivated().await?;
            let mut changed = portal.receive_shortcuts_changed().await?;

            let mut session: Option<(OwnedObjectPath, crate::portal::imp::ClosedStream)> = None;

            // Initial bind on startup.
            match open_and_bind(&conn, &portal, &preferred_hotkey).await {
                Ok(Some((path, closed, trigger))) => {
                    update_display(&app, &display, trigger);
                    session = Some((path, closed));
                }
                Ok(None) => {
                    update_display(&app, &display, None);
                }
                Err(e) => {
                    eprintln!("initial global shortcut bind failed: {e:#}");
                    update_display(&app, &display, None);
                }
            }

            loop {
                // Race: Activated, Deactivated, ShortcutsChanged, UI requests,
                // and Session::Closed (if a session is active).
                let active_path = session.as_ref().map(|(p, _)| p.clone());

                let signal_fut = async {
                    let act = Box::pin(activated.next());
                    let deact = Box::pin(deactivated.next());
                    let chg = Box::pin(changed.next());
                    match select(act, select(deact, chg)).await {
                        Either::Left((sig, _)) => Ev::Activated(sig),
                        Either::Right((Either::Left((sig, _)), _)) => Ev::Deactivated(sig),
                        Either::Right((Either::Right((sig, _)), _)) => Ev::Changed(sig),
                    }
                };

                let ctrl_fut = async {
                    let msg_fut = Box::pin(rx.recv());
                    if let Some((_, ref mut closed_stream)) = session {
                        match select(msg_fut, Box::pin(closed_stream.next())).await {
                            Either::Left((res, _)) => Ev::Msg(res),
                            Either::Right(_) => Ev::SessionClosed,
                        }
                    } else {
                        Ev::Msg(msg_fut.await)
                    }
                };

                let ev = match select(Box::pin(signal_fut), Box::pin(ctrl_fut)).await {
                    Either::Left((e, _)) | Either::Right((e, _)) => e,
                };

                match ev {
                    Ev::Activated(Some(sig)) => {
                        if let Ok(args) = sig.args() {
                            if active_path.as_ref() == Some(&args.session_handle)
                                && args.shortcut_id == SHORTCUT_ID
                            {
                                send_cmd(&app, Cmd::Start);
                            }
                        }
                    }
                    Ev::Deactivated(Some(sig)) => {
                        if let Ok(args) = sig.args() {
                            if active_path.as_ref() == Some(&args.session_handle)
                                && args.shortcut_id == SHORTCUT_ID
                            {
                                send_cmd(&app, Cmd::StopSend);
                            }
                        }
                    }
                    Ev::Changed(Some(sig)) => {
                        if let Ok(args) = sig.args() {
                            if active_path.as_ref() == Some(&args.session_handle) {
                                let trigger = extract_trigger_from_list(&args.shortcuts);
                                update_display(&app, &display, trigger);
                            }
                        }
                    }
                    Ev::Activated(None) | Ev::Deactivated(None) | Ev::Changed(None) => {
                        return Err(anyhow!("GlobalShortcuts signal stream closed"));
                    }
                    Ev::SessionClosed => {
                        eprintln!("GlobalShortcuts session closed by compositor");
                        session = None;
                        update_display(&app, &display, None);
                    }
                    Ev::Msg(Ok(PortalMsg::Configure)) => {
                        if let Some((ref path, _)) = session {
                            if portal_version >= 2 {
                                if let Err(e) = portal
                                    .configure_shortcuts(path.as_ref(), "", HashMap::new())
                                    .await
                                {
                                    eprintln!("ConfigureShortcuts failed: {e:#}");
                                }
                                continue;
                            }
                            // Older portal without ConfigureShortcuts: close
                            // old session before re-binding.
                            let old = path.clone();
                            session = None;
                            close_session(&conn, &old).await;
                        }
                        match open_and_bind(&conn, &portal, &preferred_hotkey).await {
                            Ok(Some((path, closed, trigger))) => {
                                update_display(&app, &display, trigger);
                                session = Some((path, closed));
                            }
                            Ok(None) => {}
                            Err(e) => {
                                eprintln!("global shortcut rebind failed: {e:#}");
                            }
                        }
                    }
                    Ev::Msg(Err(_)) => return Ok(()),
                }
            }
        })
    }

    enum Ev {
        Activated(Option<Activated>),
        Deactivated(Option<Deactivated>),
        Changed(Option<ShortcutsChanged>),
        SessionClosed,
        Msg(std::result::Result<PortalMsg, async_channel::RecvError>),
    }

    async fn open_and_bind(
        conn: &zbus::Connection,
        portal: &GlobalShortcutsProxy<'_>,
        preferred_hotkey: &str,
    ) -> Result<Option<(OwnedObjectPath, crate::portal::imp::ClosedStream, Option<String>)>> {
        let path = create_session(conn, portal).await?;
        let sess_proxy = PortalSessionProxy::builder(conn)
            .path(path.clone())?
            .build()
            .await?;
        let closed = sess_proxy.receive_closed().await?;
        match bind_session(conn, portal, &path, preferred_hotkey).await? {
            Some(trigger) => Ok(Some((path, closed, trigger))),
            None => {
                close_session(conn, &path).await;
                Ok(None)
            }
        }
    }

    #[cfg(test)]
    mod tests {
        use super::to_xdg_trigger;

        #[test]
        fn xdg_trigger_mapping() {
            assert_eq!(to_xdg_trigger("F9"), "F9");
            assert_eq!(to_xdg_trigger("Ctrl+Shift+Space"), "CTRL+SHIFT+space");
            assert_eq!(to_xdg_trigger("Super+A"), "LOGO+a");
            assert_eq!(to_xdg_trigger("CapsLock"), "Caps_Lock");
            assert_eq!(to_xdg_trigger("\\"), "backslash");
        }
    }
}

#[cfg(not(target_os = "linux"))]
mod imp {
    use tauri::AppHandle;

    pub struct PortalHandle;

    impl PortalHandle {
        pub fn send(&self, _msg: super::PortalMsg) {}
        pub fn display(&self) -> String {
            String::new()
        }
    }

    pub fn spawn(_app: AppHandle, _hotkey: String) -> PortalHandle {
        PortalHandle
    }
}
