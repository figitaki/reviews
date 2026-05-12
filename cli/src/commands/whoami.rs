use anyhow::Result;

use crate::api::ApiClient;
use crate::config::Config;

pub fn run() -> Result<()> {
    let cfg = Config::load()?;
    let client = ApiClient::new(&cfg.default.server_url, &cfg.default.api_token)?;
    let me = client.me()?;
    println!("{} <{}>", me.username, me.email);
    Ok(())
}
