// Shared helpers for XDG Desktop Portal calls on Linux/Wayland.
//
// Per the XDG portal Request spec, callers must subscribe to
// org.freedesktop.portal.Request::Response on the predicted request path
// *before* issuing the portal method call; otherwise fast replies (such as
// CreateSession) fire before the D-Bus match rule is registered and time out.

#[cfg(target_os = "linux")]
pub mod imp {
    use anyhow::{anyhow, Context, Result};
    use futures_util::future::{select, Either};
    use futures_util::StreamExt;
    use std::collections::HashMap;
    use std::future::Future;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::Duration;
    use zbus::proxy;
    use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};

    pub const APP_ID: &str = "com.talkist.app";

    static TOKEN_COUNTER: AtomicU64 = AtomicU64::new(1);

    pub fn is_flatpak() -> bool {
        std::path::Path::new("/.flatpak-info").exists()
    }

    pub fn session_is_wayland() -> bool {
        match std::env::var("XDG_SESSION_TYPE") {
            Ok(t) => t == "wayland",
            Err(_) => std::env::var_os("WAYLAND_DISPLAY").is_some(),
        }
    }

    /// Generate a unique, valid D-Bus object path token for this process.
    pub fn next_token(prefix: &str) -> String {
        let n = TOKEN_COUNTER.fetch_add(1, Ordering::Relaxed);
        format!("talkist_{prefix}_{}_{n}", std::process::id())
    }

    #[proxy(
        interface = "org.freedesktop.host.portal.Registry",
        default_service = "org.freedesktop.portal.Desktop",
        default_path = "/org/freedesktop/portal/desktop"
    )]
    pub trait HostRegistry {
        fn register(&self, app_id: &str, options: HashMap<&str, Value<'_>>) -> zbus::Result<()>;
    }

    #[proxy(
        interface = "org.freedesktop.portal.Request",
        default_service = "org.freedesktop.portal.Desktop"
    )]
    pub trait PortalRequest {
        #[zbus(signal)]
        fn response(&self, response: u32, results: HashMap<String, OwnedValue>) -> zbus::Result<()>;
        fn close(&self) -> zbus::Result<()>;
    }

    #[proxy(
        interface = "org.freedesktop.portal.Session",
        default_service = "org.freedesktop.portal.Desktop"
    )]
    pub trait PortalSession {
        #[zbus(signal)]
        fn closed(&self, details: HashMap<String, OwnedValue>) -> zbus::Result<()>;
        fn close(&self) -> zbus::Result<()>;
    }

    /// Register `com.talkist.app` on this D-Bus connection before making any
    /// portal calls. Required by xdg-desktop-portal >= 1.21 for unsandboxed
    /// host apps; skipped inside Flatpak (which already supplies its app ID).
    pub async fn register_host_app(conn: &zbus::Connection) {
        if is_flatpak() {
            return;
        }
        match HostRegistryProxy::new(conn).await {
            Ok(registry) => {
                if let Err(e) = registry.register(APP_ID, HashMap::new()).await {
                    eprintln!("portal app id registration skipped: {e}");
                }
            }
            Err(e) => eprintln!("portal host registry unavailable: {e}"),
        }
    }

    #[proxy(
        interface = "org.freedesktop.portal.Background",
        default_service = "org.freedesktop.portal.Desktop",
        default_path = "/org/freedesktop/portal/desktop"
    )]
    trait BackgroundPortal {
        fn request_background(
            &self,
            parent_window: &str,
            options: HashMap<&str, Value<'_>>,
        ) -> zbus::Result<OwnedObjectPath>;
    }

    /// Toggle autostart via the XDG Background portal (used inside Flatpak
    /// where `~/.config/autostart` is outside the sandbox).
    pub fn request_background_autostart(enabled: bool) -> Result<()> {
        async_io::block_on(async {
            let conn = zbus::Connection::session()
                .await
                .context("cannot connect to session bus")?;
            let portal = BackgroundPortalProxy::new(&conn)
                .await
                .context("Background portal unavailable")?;
            let handle_token = next_token("bg_auto");
            let (expected, stream) = prepare_request(&conn, &handle_token).await?;

            let mut opts = HashMap::new();
            opts.insert("handle_token", Value::from(handle_token.as_str()));
            opts.insert("reason", Value::from("Start Talkist automatically at login"));
            opts.insert("autostart", Value::from(enabled));
            opts.insert("background", Value::from(true));

            let actual = portal
                .request_background("", opts)
                .await
                .context("RequestBackground failed")?;
            let mut stream = align_request(&conn, expected, stream, actual).await?;
            let (code, _) = match with_timeout(Duration::from_secs(15), next_response(&mut stream)).await {
                Some(Ok(r)) => r,
                Some(Err(e)) => return Err(anyhow!("RequestBackground response error: {e:#}")),
                None => return Err(anyhow!("RequestBackground timed out")),
            };
            if code != 0 {
                return Err(anyhow!("RequestBackground declined ({code})"));
            }
            Ok(())
        })
    }

    /// Pre-subscribe to a portal Request::Response signal using `handle_token`
    /// before issuing the portal call, then validate the returned handle path
    /// and return the live Response stream.
    pub async fn prepare_request(
        conn: &zbus::Connection,
        handle_token: &str,
    ) -> Result<(OwnedObjectPath, ResponseStream)> {
        let unique = conn
            .unique_name()
            .context("session bus connection has no unique name")?;
        let sender = unique.as_str().trim_start_matches(':').replace('.', "_");
        let expected = OwnedObjectPath::try_from(format!(
            "/org/freedesktop/portal/desktop/request/{sender}/{handle_token}"
        ))
        .context("invalid predicted portal request path")?;
        let proxy = PortalRequestProxy::builder(conn)
            .path(expected.clone())?
            .build()
            .await?;
        let stream = proxy.receive_response().await?;
        Ok((expected, stream))
    }

    /// Finish wiring a pre-subscribed request after the portal call returns
    /// its actual request handle path (re-subscribing only if a legacy portal
    /// returned a different path).
    pub async fn align_request(
        conn: &zbus::Connection,
        expected: OwnedObjectPath,
        stream: ResponseStream,
        actual: OwnedObjectPath,
    ) -> Result<ResponseStream> {
        if actual == expected {
            return Ok(stream);
        }
        let proxy = PortalRequestProxy::builder(conn)
            .path(actual)?
            .build()
            .await?;
        Ok(proxy.receive_response().await?)
    }

    pub async fn next_response(
        stream: &mut ResponseStream,
    ) -> Result<(u32, HashMap<String, OwnedValue>)> {
        let signal = stream
            .next()
            .await
            .ok_or_else(|| anyhow!("portal request closed before responding"))?;
        let args = signal.args()?;
        Ok((args.response, args.results))
    }

    pub async fn with_timeout<F: Future>(dur: Duration, fut: F) -> Option<F::Output> {
        let timer = Box::pin(async_io::Timer::after(dur));
        match select(timer, Box::pin(fut)).await {
            Either::Left(_) => None,
            Either::Right((out, _)) => Some(out),
        }
    }

    /// Extract `session_handle` from a CreateSession Response.
    ///
    /// Per the XDG portal spec, `session_handle` is encoded as a D-Bus string
    /// (`s`) for historical reasons, though we also accept an ObjectPath (`o`).
    pub fn parse_session_handle(
        results: &mut HashMap<String, OwnedValue>,
    ) -> Result<OwnedObjectPath> {
        let val = results
            .remove("session_handle")
            .context("CreateSession returned no session_handle")?;
        if let Ok(s) = String::try_from(val.try_clone()?) {
            return OwnedObjectPath::try_from(s)
                .context("CreateSession session_handle string was not a valid object path");
        }
        OwnedObjectPath::try_from(val)
            .context("CreateSession session_handle was neither a string nor an object path")
    }

    pub async fn close_session(conn: &zbus::Connection, session_path: &OwnedObjectPath) {
        if let Ok(builder) = PortalSessionProxy::builder(conn).path(session_path.clone()) {
            if let Ok(proxy) = builder.build().await {
                let _ = proxy.close().await;
            }
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn session_handle_accepts_string_and_object_path() {
            let mut from_str = HashMap::new();
            from_str.insert(
                "session_handle".to_string(),
                OwnedValue::from(zbus::zvariant::Str::from(
                    "/org/freedesktop/portal/desktop/session/1_42/tok",
                )),
            );
            let parsed = parse_session_handle(&mut from_str).unwrap();
            assert_eq!(
                parsed.as_str(),
                "/org/freedesktop/portal/desktop/session/1_42/tok"
            );

            let mut from_obj = HashMap::new();
            let obj = OwnedObjectPath::try_from("/org/freedesktop/portal/desktop/session/1_42/tok2")
                .unwrap();
            from_obj.insert(
                "session_handle".to_string(),
                OwnedValue::try_from(Value::from(obj)).unwrap(),
            );
            let parsed = parse_session_handle(&mut from_obj).unwrap();
            assert_eq!(
                parsed.as_str(),
                "/org/freedesktop/portal/desktop/session/1_42/tok2"
            );
        }
    }
}

#[cfg(target_os = "linux")]
pub use imp::{is_flatpak, request_background_autostart, session_is_wayland};

#[cfg(not(target_os = "linux"))]
pub fn is_flatpak() -> bool {
    false
}

#[cfg(not(target_os = "linux"))]
pub fn request_background_autostart(_enabled: bool) -> anyhow::Result<()> {
    Ok(())
}

#[cfg(not(target_os = "linux"))]
pub fn session_is_wayland() -> bool {
    false
}
