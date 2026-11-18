//! Config file at `~/.config/reviews/config.toml`.
//!
//! `reviews login` writes tokens that refresh themselves:
//!
//! ```toml
//! [default]
//! server_url = "https://reviews.figitaki.dev"
//!
//! [default.oauth]
//! access_token = "gka_..."
//! refresh_token = "gkr_..."
//! expires_at = 1763400000
//! token_endpoint = "https://reviews.figitaki.dev/oauth/token"
//! ```
//!
//! `reviews login --token` writes an API token minted in Settings instead:
//!
//! ```toml
//! [default]
//! server_url = "http://localhost:4000"
//! api_token = "rev_..."
//! ```

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Profile {
    pub server_url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub api_token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub oauth: Option<OAuthTokens>,
}

/// Tokens from `reviews login`. The access token lasts about an hour; the
/// CLI trades the refresh token for new ones (`crate::auth`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct OAuthTokens {
    pub access_token: String,
    pub refresh_token: String,
    /// Unix seconds when the access token expires.
    pub expires_at: i64,
    pub token_endpoint: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Config {
    pub default: Profile,
}

impl Config {
    /// A config with an API token minted in Settings.
    pub fn new(server_url: String, api_token: String) -> Self {
        Config {
            default: Profile {
                server_url,
                api_token: Some(api_token),
                oauth: None,
            },
        }
    }

    /// A config with tokens from the device sign-in.
    pub fn with_oauth(server_url: String, oauth: OAuthTokens) -> Self {
        Config {
            default: Profile {
                server_url,
                api_token: None,
                oauth: Some(oauth),
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

    /// Writes the config with mode 0600, through a temporary file renamed
    /// into place, so a concurrent reader never sees half a file.
    pub fn save_to(&self, path: &Path) -> Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).with_context(|| {
                format!("could not create config directory {}", parent.display())
            })?;
        }
        let text = toml::to_string_pretty(self).context("could not serialize config")?;
        let tmp = path.with_extension("toml.tmp");
        std::fs::write(&tmp, text)
            .with_context(|| format!("could not write config to {}", tmp.display()))?;
        // Best-effort tighten perms to 0600 on Unix; ignore on other platforms.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))
                .with_context(|| format!("could not set permissions on {}", tmp.display()))?;
        }
        std::fs::rename(&tmp, path)
            .with_context(|| format!("could not write config to {}", path.display()))?;
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

        let cfg = Config::with_oauth(
            "http://localhost:4000".into(),
            OAuthTokens {
                access_token: "gka_a".into(),
                refresh_token: "gkr_r".into(),
                expires_at: 1_763_400_000,
                token_endpoint: "http://localhost:4000/oauth/token".into(),
            },
        );
        cfg.save_to(&path).unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(!text.contains("api_token"), "text = {text}");
        assert_eq!(Config::load_from(&path).unwrap(), cfg);
    }

    #[test]
    fn loads_a_config_written_before_device_sign_in() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        std::fs::write(
            &path,
            "[default]\nserver_url = \"http://x\"\napi_token = \"rev_old\"\n",
        )
        .unwrap();
        let cfg = Config::load_from(&path).unwrap();
        assert_eq!(cfg.default.api_token.as_deref(), Some("rev_old"));
        assert_eq!(cfg.default.oauth, None);
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
