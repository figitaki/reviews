//! Config file at `~/.config/reviews/config.toml`.
//!
//! Format:
//!
//! ```toml
//! [default]
//! server_url = "http://localhost:4000"
//! api_token = "abcdef..."
//! ```

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Profile {
    pub server_url: String,
    pub api_token: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Config {
    pub default: Profile,
}

impl Config {
    pub fn new(server_url: String, api_token: String) -> Self {
        Config {
            default: Profile {
                server_url,
                api_token,
            },
        }
    }

    pub fn load() -> Result<Self> {
        let path = config_path()?;
        Self::load_from(&path)
    }

    pub fn load_from(path: &Path) -> Result<Self> {
        let text = std::fs::read_to_string(path).with_context(|| {
            format!(
                "could not read config at {}. Run `reviews login` first.",
                path.display()
            )
        })?;
        let cfg: Config = toml::from_str(&text)
            .with_context(|| format!("invalid TOML in config at {}", path.display()))?;
        Ok(cfg)
    }

    pub fn save(&self) -> Result<PathBuf> {
        let path = config_path()?;
        self.save_to(&path)?;
        Ok(path)
    }

    pub fn save_to(&self, path: &Path) -> Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).with_context(|| {
                format!("could not create config directory {}", parent.display())
            })?;
        }
        let text = toml::to_string_pretty(self).context("could not serialize config")?;
        std::fs::write(path, text)
            .with_context(|| format!("could not write config to {}", path.display()))?;
        // Best-effort tighten perms to 0600 on Unix; ignore on other platforms.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(path)
                .with_context(|| format!("could not stat {}", path.display()))?
                .permissions();
            perms.set_mode(0o600);
            std::fs::set_permissions(path, perms)
                .with_context(|| format!("could not set permissions on {}", path.display()))?;
        }
        Ok(())
    }
}

pub fn config_path() -> Result<PathBuf> {
    let home =
        dirs::home_dir().ok_or_else(|| anyhow!("could not determine user home directory"))?;
    Ok(home.join(".config").join("reviews").join("config.toml"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_toml() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let cfg = Config::new("http://localhost:4000".into(), "tok_abc123".into());
        cfg.save_to(&path).unwrap();
        let loaded = Config::load_from(&path).unwrap();
        assert_eq!(cfg, loaded);
    }

    #[test]
    fn load_errors_when_missing() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nope.toml");
        let err = Config::load_from(&path).unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("reviews login"), "msg = {msg}");
    }

    #[cfg(unix)]
    #[test]
    fn save_sets_0600_perms() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let cfg = Config::new("http://x".into(), "t".into());
        cfg.save_to(&path).unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }
}
