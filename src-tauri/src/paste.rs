use anyhow::Result;
use enigo::{Direction, Enigo, Key, Keyboard, Settings};
use std::time::Duration;

/// Clipboard handle + key synthesizer. Keep one alive for the process
/// lifetime so the X11 clipboard keeps serving paste requests.
pub struct Paster {
    clip: arboard::Clipboard,
}

impl Paster {
    pub fn new() -> Result<Self> {
        Ok(Self {
            clip: arboard::Clipboard::new()?,
        })
    }

    /// Copy `text` to the clipboard and synthesize Ctrl+V at the cursor.
    pub fn paste(&mut self, text: &str) -> Result<()> {
        self.clip.set_text(text.to_string())?;
        let mut en = Enigo::new(&Settings::default())?;
        std::thread::sleep(Duration::from_millis(20));
        en.key(Key::Control, Direction::Press)?;
        std::thread::sleep(Duration::from_millis(10));
        en.key(Key::Unicode('v'), Direction::Click)?;
        std::thread::sleep(Duration::from_millis(10));
        en.key(Key::Control, Direction::Release)?;
        Ok(())
    }
}
