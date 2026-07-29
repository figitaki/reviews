use anyhow::Result;

use crate::api::ApiClient;
use crate::config::Config;

pub fn run() -> Result<()> {
    let cfg = Config::load()?;
    let client = ApiClient::new(&cfg.default.server_url, &cfg.default.api_token)?;
    let me = client.me()?;
    if let Some(identity) = me.identity {
        println!(
            "{} <{}> acting as {} (@{})",
            me.username, me.email, identity.display_name, identity.handle
        );
    } else {
        println!("{} <{}>", me.username, me.email);
    }
    Ok(())
}
