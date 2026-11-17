use anyhow::Result;

use crate::api::{ApiClient, Me};
use crate::config::Config;

pub fn run() -> Result<()> {
    let cfg = Config::load()?;
    let client = ApiClient::new(&cfg.default.server_url, &cfg.default.api_token)?;
    println!("{}", describe(&client.me()?));
    Ok(())
}

fn describe(me: &Me) -> String {
    let owner = match &me.email {
        Some(email) => format!("{} <{}>", me.username, email),
        None => me.username.clone(),
    };
    match &me.identity {
        Some(identity) => format!(
            "{owner} acting as {} (@{})",
            identity.display_name, identity.handle
        ),
        None => owner,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn describes_an_account_without_a_public_email() {
        let me: Me = serde_json::from_str(
            r#"{"username":"carey","email":null,"identity":{"id":1,"kind":"agent","handle":"codex","display_name":"Codex","avatar_url":null}}"#,
        )
        .unwrap();
        assert_eq!(describe(&me), "carey acting as Codex (@codex)");

        let me: Me =
            serde_json::from_str(r#"{"username":"carey","email":null,"identity":null}"#).unwrap();
        assert_eq!(describe(&me), "carey");
    }

    #[test]
    fn describes_an_account_with_an_email() {
        let me: Me = serde_json::from_str(
            r#"{"username":"carey","email":"carey@example.com","identity":null}"#,
        )
        .unwrap();
        assert_eq!(describe(&me), "carey <carey@example.com>");
    }
}
