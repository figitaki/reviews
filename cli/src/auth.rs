//! Signing in and staying signed in.
//!
//! `reviews login` uses the OAuth device authorization grant (RFC 8628): it
//! asks the server for a code, the person enters it at the server's
//! `/device` page on any device, and the CLI polls the token endpoint until
//! they decide. That works over SSH and in containers, where the CLI can't
//! open a browser or take a redirect.
//!
//! The access token lasts about an hour. Before it expires, `token` trades
//! the refresh token for new ones. Refresh tokens rotate, and the server
//! revokes the whole sign-in when a replaced one is presented, so two
//! commands must never refresh at once: the refresh holds a lock on
//! `config.toml.lock` and rereads the config inside it.
//!
//! Device codes and refresh tokens go only to HTTPS endpoints, or to plain
//! HTTP on a loopback host for local development (`secure_endpoint`). That
//! is checked when the endpoints are discovered and again before each
//! request, since the saved config can be edited by hand.

use anyhow::{anyhow, bail, Context, Result};
use reqwest::blocking::Client;
use reqwest::Url;
use serde::Deserialize;
use std::fs::OpenOptions;
use std::net::IpAddr;
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::api::ApiClient;
use crate::config::{config_path, Config, OAuthTokens};

/// The Reviews CLI's OAuth client, registered on the server.
pub const CLIENT_ID: &str = "reviews-cli";
pub const DEVICE_GRANT: &str = "urn:ietf:params:oauth:grant-type:device_code";
/// The scope of the CLI API, which also names it as the resource.
const SCOPE: &str = "cli";
/// Refresh this many seconds before the access token expires.
const REFRESH_MARGIN: i64 = 60;
/// RFC 8628 §3.5: each `slow_down` adds 5 seconds to the interval.
const SLOW_DOWN_SECONDS: u64 = 5;

pub fn http() -> Result<Client> {
    Client::builder()
        .timeout(Duration::from_secs(30))
        .user_agent(concat!("reviews-cli/", env!("CARGO_PKG_VERSION")))
        .build()
        .context("could not build HTTP client")
}

pub fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// An API client for the saved config, signed in.
pub fn client(cfg: &Config) -> Result<ApiClient> {
    ApiClient::new(&cfg.default.server_url, token(cfg)?)
}

/// The bearer token of the saved config, refreshed first if it is about to
/// expire.
pub fn token(cfg: &Config) -> Result<String> {
    token_at(&config_path()?, cfg, now())
}

pub fn token_at(path: &Path, cfg: &Config, now: i64) -> Result<String> {
    match (&cfg.default.oauth, &cfg.default.api_token) {
        (Some(oauth), _) if oauth.expires_at - REFRESH_MARGIN > now => {
            Ok(oauth.access_token.clone())
        }
        (Some(_), _) => refresh_locked(path, now),
        (None, Some(token)) => Ok(token.clone()),
        (None, None) => bail!("you are not signed in. Run `reviews login`."),
    }
}

fn refresh_locked(path: &Path, now: i64) -> Result<String> {
    let lock_path = path.with_extension("toml.lock");
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&lock_path)
        .with_context(|| format!("could not open {}", lock_path.display()))?;
    lock.lock()
        .with_context(|| format!("could not lock {}", lock_path.display()))?;

    // Another command may have refreshed while this one waited.
    let mut cfg = Config::load_from(path)?;
    let oauth = cfg
        .default
        .oauth
        .clone()
        .ok_or_else(|| anyhow!("you are not signed in. Run `reviews login`."))?;
    if oauth.expires_at - REFRESH_MARGIN > now {
        return Ok(oauth.access_token);
    }

    let tokens = refresh(&http()?, &oauth, now)?;
    cfg.default.oauth = Some(tokens.clone());
    cfg.save_to(path)?;
    Ok(tokens.access_token)
}

#[derive(Debug, Deserialize)]
struct TokenResponse {
    access_token: String,
    refresh_token: Option<String>,
    expires_in: i64,
}

#[derive(Debug, Deserialize)]
struct ErrorResponse {
    error: String,
}

/// `url` parsed, if the CLI may send sign-in secrets to it: HTTPS, or HTTP
/// on a loopback host (`localhost`, `127.0.0.0/8`, `::1`) for local
/// development.
pub fn secure_endpoint(url: &str) -> Result<Url> {
    let parsed = Url::parse(url).with_context(|| format!("{url} is not a valid URL"))?;
    match parsed.scheme() {
        "https" => Ok(parsed),
        "http" if is_loopback(&parsed) => Ok(parsed),
        _ => bail!(
            "refusing to send sign-in secrets to {url}: it isn't HTTPS. \
             Use an https:// server, or http://localhost for local development."
        ),
    }
}

fn is_loopback(url: &Url) -> bool {
    match url.host_str() {
        Some(host) if host.eq_ignore_ascii_case("localhost") => true,
        Some(host) => host
            .trim_start_matches('[')
            .trim_end_matches(']')
            .parse::<IpAddr>()
            .is_ok_and(|ip| ip.is_loopback()),
        None => false,
    }
}

pub fn refresh(http: &Client, oauth: &OAuthTokens, now: i64) -> Result<OAuthTokens> {
    let endpoint = secure_endpoint(&oauth.token_endpoint)
        .context("the saved sign-in has an unsafe token endpoint. Run `reviews login` again")?;
    let resp = http
        .post(endpoint)
        .form(&[
            ("grant_type", "refresh_token"),
            ("client_id", CLIENT_ID),
            ("refresh_token", oauth.refresh_token.as_str()),
        ])
        .send()
        .context("could not reach the server to refresh your sign-in")?;

    if resp.status().is_success() {
        let body: TokenResponse = resp
            .json()
            .context("could not parse the token response as JSON")?;
        return Ok(OAuthTokens {
            access_token: body.access_token,
            // Without a new one, the old refresh token stays valid.
            refresh_token: body
                .refresh_token
                .unwrap_or_else(|| oauth.refresh_token.clone()),
            expires_at: now + body.expires_in,
            token_endpoint: oauth.token_endpoint.clone(),
        });
    }

    let status = resp.status();
    match resp.json::<ErrorResponse>().map(|e| e.error) {
        Ok(error) if error == "invalid_grant" => bail!(
            "your CLI sign-in ended: it was signed out in Settings, or it expired. \
             Run `reviews login` again."
        ),
        Ok(error) => bail!("could not refresh your sign-in: {error} (HTTP {status})"),
        Err(_) => bail!("could not refresh your sign-in: HTTP {status}"),
    }
}

/// The issuer's endpoints, from its metadata (RFC 8414).
#[derive(Debug, Clone, Deserialize)]
pub struct Endpoints {
    pub device_authorization_endpoint: Option<String>,
    pub token_endpoint: String,
}

pub fn discover(http: &Client, server_url: &str) -> Result<Endpoints> {
    let url = format!(
        "{}/.well-known/oauth-authorization-server",
        server_url.trim_end_matches('/')
    );
    let resp = http
        .get(&url)
        .send()
        .with_context(|| format!("could not reach {server_url}"))?;
    if !resp.status().is_success() {
        bail!(
            "{server_url} doesn't support signing in from the browser (HTTP {} for {url}). \
             Use `reviews login --token` with a token from {server_url}/settings.",
            resp.status()
        );
    }
    let endpoints: Endpoints = resp
        .json()
        .with_context(|| format!("could not parse {url} as JSON"))?;
    // The metadata decides where codes and tokens go; refuse to send them in
    // the clear.
    secure_endpoint(&endpoints.token_endpoint)?;
    if let Some(endpoint) = &endpoints.device_authorization_endpoint {
        secure_endpoint(endpoint)?;
    }
    Ok(endpoints)
}

#[derive(Debug, Clone, Deserialize)]
pub struct DeviceStart {
    pub device_code: String,
    pub user_code: String,
    pub verification_uri: String,
    pub verification_uri_complete: Option<String>,
    pub expires_in: u64,
    #[serde(default = "default_interval")]
    pub interval: u64,
}

fn default_interval() -> u64 {
    5
}

pub fn start(http: &Client, server_url: &str, endpoints: &Endpoints) -> Result<DeviceStart> {
    let Some(endpoint) = endpoints.device_authorization_endpoint.as_deref() else {
        bail!(
            "{server_url} doesn't support signing in from the browser. \
             Use `reviews login --token` with a token from {server_url}/settings."
        );
    };
    let url = secure_endpoint(endpoint)?;
    let resp = http
        .post(url)
        .form(&[("client_id", CLIENT_ID), ("scope", SCOPE)])
        .send()
        .with_context(|| format!("could not reach {endpoint}"))?;
    if !resp.status().is_success() {
        let status = resp.status();
        let error = resp.json::<ErrorResponse>().map(|e| e.error);
        bail!(
            "the server refused to start a sign-in: {} (HTTP {status})",
            error.unwrap_or_else(|_| "no details".into())
        );
    }
    resp.json()
        .context("could not parse the device authorization response as JSON")
}

/// Polls the token endpoint until the person decides or the code expires.
/// `sleep` waits between polls; tests pass one that only records.
pub fn poll(
    http: &Client,
    endpoints: &Endpoints,
    device: &DeviceStart,
    sleep: &mut dyn FnMut(Duration),
    now: &dyn Fn() -> i64,
) -> Result<OAuthTokens> {
    let token_endpoint = secure_endpoint(&endpoints.token_endpoint)?;
    let mut interval = device.interval.max(1);
    let mut waited = 0;

    loop {
        // The server answers expired_token once the code expires; this bound
        // only stops a client whose polls keep failing to arrive.
        if waited > device.expires_in + interval {
            bail!("the sign-in code expired. Run `reviews login` again.");
        }
        sleep(Duration::from_secs(interval));
        waited += interval;

        let resp = match http
            .post(token_endpoint.clone())
            .form(&[
                ("grant_type", DEVICE_GRANT),
                ("client_id", CLIENT_ID),
                ("device_code", device.device_code.as_str()),
            ])
            .send()
        {
            Ok(resp) => resp,
            // A dropped connection on a laptop or over SSH: try again.
            Err(_) => continue,
        };

        let status = resp.status();
        if status.is_success() {
            let body: TokenResponse = resp
                .json()
                .context("could not parse the token response as JSON")?;
            let refresh_token = body
                .refresh_token
                .ok_or_else(|| anyhow!("the server sent no refresh token"))?;
            return Ok(OAuthTokens {
                access_token: body.access_token,
                refresh_token,
                expires_at: now() + body.expires_in,
                token_endpoint: endpoints.token_endpoint.clone(),
            });
        }

        let error = resp.json::<ErrorResponse>().map(|e| e.error);
        match error.as_deref() {
            Ok("authorization_pending") => {}
            Ok("slow_down") => interval += SLOW_DOWN_SECONDS,
            Ok("expired_token") => bail!("the sign-in code expired. Run `reviews login` again."),
            Ok("access_denied") => bail!("the sign-in was denied in the browser."),
            Ok(other) => bail!("sign-in failed: {other} (HTTP {status})"),
            Err(_) if status.is_server_error() => {}
            Err(_) => bail!("sign-in failed: HTTP {status}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mockito::{Matcher, Server};

    fn device(interval: u64) -> DeviceStart {
        DeviceStart {
            device_code: "gkd_dev".into(),
            user_code: "WDJB-MJHT".into(),
            verification_uri: "https://x/device".into(),
            verification_uri_complete: None,
            expires_in: 600,
            interval,
        }
    }

    fn endpoints(server: &Server) -> Endpoints {
        Endpoints {
            device_authorization_endpoint: Some(format!(
                "{}/oauth/device_authorization",
                server.url()
            )),
            token_endpoint: format!("{}/oauth/token", server.url()),
        }
    }

    fn poll_mock(server: &mut Server, status: usize, body: &str) -> mockito::Mock {
        server
            .mock("POST", "/oauth/token")
            .match_body(Matcher::AllOf(vec![
                Matcher::UrlEncoded("grant_type".into(), DEVICE_GRANT.into()),
                Matcher::UrlEncoded("client_id".into(), CLIENT_ID.into()),
                Matcher::UrlEncoded("device_code".into(), "gkd_dev".into()),
            ]))
            .with_status(status)
            .with_header("content-type", "application/json")
            .with_body(body)
            .expect(1)
            .create()
    }

    #[test]
    fn poll_waits_while_pending_and_backs_off_on_slow_down() {
        let mut server = Server::new();
        let pending = poll_mock(&mut server, 400, r#"{"error":"authorization_pending"}"#);
        let slow = poll_mock(&mut server, 400, r#"{"error":"slow_down"}"#);
        let pending2 = poll_mock(&mut server, 400, r#"{"error":"authorization_pending"}"#);
        let ok = poll_mock(
            &mut server,
            200,
            r#"{"access_token":"gka_1","refresh_token":"gkr_1","expires_in":3600,"token_type":"Bearer"}"#,
        );

        let mut sleeps = vec![];
        let tokens = poll(
            &http().unwrap(),
            &endpoints(&server),
            &device(5),
            &mut |d| sleeps.push(d.as_secs()),
            &|| 1_000,
        )
        .unwrap();

        // mockito answers mocks with the same matcher in order, once each.
        for m in [pending, slow, pending2, ok] {
            m.assert();
        }
        assert_eq!(sleeps, vec![5, 5, 10, 10]);
        assert_eq!(tokens.access_token, "gka_1");
        assert_eq!(tokens.refresh_token, "gkr_1");
        assert_eq!(tokens.expires_at, 4_600);
        assert_eq!(
            tokens.token_endpoint,
            format!("{}/oauth/token", server.url())
        );
    }

    #[test]
    fn poll_stops_on_expired_and_denied() {
        for (error, says) in [
            ("expired_token", "expired. Run `reviews login` again"),
            ("access_denied", "denied"),
        ] {
            let mut server = Server::new();
            poll_mock(&mut server, 400, &format!(r#"{{"error":"{error}"}}"#));
            let err = poll(
                &http().unwrap(),
                &endpoints(&server),
                &device(1),
                &mut |_| {},
                &|| 0,
            )
            .unwrap_err();
            assert!(format!("{err:#}").contains(says), "{error}: {err:#}");
        }
    }

    fn saved(dir: &Path, server: &Server, expires_at: i64) -> (std::path::PathBuf, Config) {
        let path = dir.join("config.toml");
        let cfg = Config::with_oauth(
            server.url(),
            OAuthTokens {
                access_token: "gka_old".into(),
                refresh_token: "gkr_old".into(),
                expires_at,
                token_endpoint: format!("{}/oauth/token", server.url()),
            },
        );
        cfg.save_to(&path).unwrap();
        (path, cfg)
    }

    #[test]
    fn a_fresh_token_is_used_as_is() {
        let mut server = Server::new();
        let none = server.mock("POST", Matcher::Any).expect(0).create();
        let dir = tempfile::tempdir().unwrap();
        let (path, cfg) = saved(dir.path(), &server, 10_000);

        assert_eq!(token_at(&path, &cfg, 10_000 - 61).unwrap(), "gka_old");
        none.assert();
    }

    #[test]
    fn an_expiring_token_is_refreshed_and_the_rotated_tokens_saved() {
        let mut server = Server::new();
        let refresh = server
            .mock("POST", "/oauth/token")
            .match_body(Matcher::AllOf(vec![
                Matcher::UrlEncoded("grant_type".into(), "refresh_token".into()),
                Matcher::UrlEncoded("client_id".into(), CLIENT_ID.into()),
                Matcher::UrlEncoded("refresh_token".into(), "gkr_old".into()),
            ]))
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(r#"{"access_token":"gka_new","refresh_token":"gkr_new","expires_in":3600}"#)
            .expect(1)
            .create();
        let dir = tempfile::tempdir().unwrap();
        let (path, cfg) = saved(dir.path(), &server, 10_000);

        // 59 seconds before expiry is inside the margin.
        assert_eq!(token_at(&path, &cfg, 10_000 - 59).unwrap(), "gka_new");
        refresh.assert();

        let oauth = Config::load_from(&path).unwrap().default.oauth.unwrap();
        assert_eq!(oauth.refresh_token, "gkr_new");
        assert_eq!(oauth.expires_at, 10_000 - 59 + 3600);

        // The stale copy in memory doesn't refresh again: the saved config,
        // reread under the lock, is fresh.
        assert_eq!(token_at(&path, &cfg, 10_000).unwrap(), "gka_new");
        refresh.assert();
    }

    #[test]
    fn a_revoked_sign_in_says_to_log_in_again() {
        let mut server = Server::new();
        server
            .mock("POST", "/oauth/token")
            .with_status(400)
            .with_header("content-type", "application/json")
            .with_body(r#"{"error":"invalid_grant"}"#)
            .create();
        let dir = tempfile::tempdir().unwrap();
        let (path, cfg) = saved(dir.path(), &server, 0);

        let err = token_at(&path, &cfg, 1_000).unwrap_err();
        assert!(
            format!("{err:#}").contains("signed out in Settings"),
            "{err:#}"
        );
    }

    #[test]
    fn secrets_go_only_to_https_or_loopback() {
        for ok in [
            "https://reviews.example/oauth/token",
            "http://localhost:4000/oauth/token",
            "http://LOCALHOST/oauth/token",
            "http://127.0.0.1:4000/oauth/token",
            "http://127.1.2.3/oauth/token",
            "http://[::1]:4000/oauth/token",
        ] {
            assert!(secure_endpoint(ok).is_ok(), "{ok}");
        }
        for bad in [
            "http://reviews.example/oauth/token",
            "http://localhost.evil.example/oauth/token",
            "http://127.0.0.1.evil.example/oauth/token",
            "http://10.0.0.1/oauth/token",
            "ftp://reviews.example/oauth/token",
            "not a url",
        ] {
            assert!(secure_endpoint(bad).is_err(), "{bad}");
        }
    }

    fn metadata(server: &mut Server, body: &str) {
        server
            .mock("GET", "/.well-known/oauth-authorization-server")
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(body)
            .create();
    }

    #[test]
    fn discovery_refuses_plain_http_endpoints_on_other_hosts() {
        for body in [
            r#"{"token_endpoint":"http://reviews.example/oauth/token"}"#,
            r#"{"token_endpoint":"https://reviews.example/oauth/token","device_authorization_endpoint":"http://reviews.example/oauth/device_authorization"}"#,
        ] {
            let mut server = Server::new();
            metadata(&mut server, body);
            let err = discover(&http().unwrap(), &server.url()).unwrap_err();
            assert!(
                format!("{err:#}").contains("isn't HTTPS"),
                "{body}: {err:#}"
            );
        }

        let mut server = Server::new();
        metadata(
            &mut server,
            r#"{"token_endpoint":"https://reviews.example/oauth/token","device_authorization_endpoint":"https://reviews.example/oauth/device_authorization"}"#,
        );
        assert!(discover(&http().unwrap(), &server.url()).is_ok());
    }

    #[test]
    fn a_saved_plain_http_token_endpoint_is_never_sent_the_refresh_token() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let cfg = Config::with_oauth(
            "http://reviews.example".into(),
            OAuthTokens {
                access_token: "gka_old".into(),
                refresh_token: "gkr_old".into(),
                expires_at: 0,
                token_endpoint: "http://reviews.example/oauth/token".into(),
            },
        );
        cfg.save_to(&path).unwrap();

        let err = token_at(&path, &cfg, 1_000).unwrap_err();
        assert!(format!("{err:#}").contains("isn't HTTPS"), "{err:#}");
        assert!(format!("{err:#}").contains("reviews login"), "{err:#}");
    }

    #[test]
    fn a_server_without_the_device_grant_points_to_token_login() {
        let mut server = Server::new();
        server
            .mock("GET", "/.well-known/oauth-authorization-server")
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(format!(
                r#"{{"token_endpoint":"{}/oauth/token"}}"#,
                server.url()
            ))
            .create();
        let http = http().unwrap();
        let endpoints = discover(&http, &server.url()).unwrap();
        let err = start(&http, &server.url(), &endpoints).unwrap_err();
        assert!(format!("{err:#}").contains("--token"), "{err:#}");
    }
}
