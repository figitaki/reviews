pub mod comment;
pub mod diff;
pub mod login;
pub mod push;
pub mod reply;
pub mod section;
pub mod show;
pub mod thread_status;
pub mod threads;
pub mod whoami;

/// Accepts a thread id either bare (`7`) or as printed by `reviews threads`
/// and `reviews show --format md` (`#7`), so ids can be copied straight out of
/// a listing.
pub fn parse_thread_id(raw: &str) -> Result<i64, String> {
    let trimmed = raw.trim();
    let digits = trimmed.strip_prefix('#').unwrap_or(trimmed);

    match digits.parse::<i64>() {
        Ok(id) if id > 0 => Ok(id),
        _ => Err(format!(
            "thread id must be a positive integer like `7` or `#7`, got `{raw}`"
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::parse_thread_id;

    #[test]
    fn accepts_bare_and_hashed_ids() {
        assert_eq!(parse_thread_id("7").unwrap(), 7);
        assert_eq!(parse_thread_id("#7").unwrap(), 7);
        assert_eq!(parse_thread_id("  #12 ").unwrap(), 12);
    }

    #[test]
    fn rejects_non_positive_and_garbage() {
        assert!(parse_thread_id("0").is_err());
        assert!(parse_thread_id("-1").is_err());
        assert!(parse_thread_id("#").is_err());
        assert!(parse_thread_id("abc").is_err());
        assert!(parse_thread_id("7x").is_err());
    }
}
