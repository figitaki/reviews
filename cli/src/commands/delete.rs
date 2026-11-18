use std::io::{self, BufRead, Write};

use anyhow::{anyhow, Context, Result};
use clap::Args;

use crate::api::DeletionPreview;
use crate::auth;
use crate::config::Config;

#[derive(Args, Debug)]
pub struct DeleteArgs {
    /// Review slug (the `:slug` in `/r/:slug`).
    pub slug: String,

    /// Delete without asking you to type the slug, for scripts.
    #[arg(long)]
    pub yes: bool,
}

pub fn run(args: DeleteArgs) -> Result<()> {
    let cfg = Config::load()?;
    let client = auth::client(&cfg)?;

    if !args.yes {
        let preview = client.deletion_preview(&args.slug)?;
        let stdin = io::stdin();
        confirm(&preview, &mut stdin.lock(), &mut io::stderr())?;
    }

    client.delete_review(&args.slug)?;
    println!("Deleted review {}.", args.slug);
    Ok(())
}

/// Shows what the deletion removes and asks for the slug. Anything other
/// than the exact slug, including no answer, cancels.
fn confirm(
    preview: &DeletionPreview,
    input: &mut impl BufRead,
    out: &mut impl Write,
) -> Result<()> {
    writeln!(out, "{}", warning(preview))?;
    write!(out, "Type {} to delete it: ", preview.slug)?;
    out.flush()?;

    let mut answer = String::new();
    input
        .read_line(&mut answer)
        .context("could not read the confirmation")?;

    if answer.trim() == preview.slug {
        Ok(())
    } else {
        Err(anyhow!(
            "not deleted: you did not type {}. Nothing changed.",
            preview.slug
        ))
    }
}

fn warning(preview: &DeletionPreview) -> String {
    let mut text = format!(
        "This permanently deletes \"{}\" ({}) for everyone: {}, {} and {}, with every section decision and viewed mark. It can't be undone.",
        preview.title,
        preview.slug,
        count(preview.patchsets, "revision"),
        count(preview.threads, "thread"),
        count(preview.comments, "comment"),
    );

    if preview.other_comments > 0 {
        text.push_str(&format!(
            "\nWarning: {} by other people or agents will be deleted too ({}).",
            count(preview.other_comments, "comment"),
            preview.other_authors.join(", ")
        ));
    }

    text
}

fn count(n: i64, noun: &str) -> String {
    if n == 1 {
        format!("1 {noun}")
    } else {
        format!("{n} {noun}s")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn preview(other_comments: i64, other_authors: &[&str]) -> DeletionPreview {
        DeletionPreview {
            slug: "k7m2qz".to_string(),
            title: "Pushed by mistake".to_string(),
            patchsets: 2,
            threads: 1,
            comments: 3,
            other_comments,
            other_authors: other_authors.iter().map(|a| a.to_string()).collect(),
        }
    }

    fn run_confirm(preview: &DeletionPreview, typed: &str) -> (Result<()>, String) {
        let mut out = Vec::new();
        let result = confirm(preview, &mut typed.as_bytes(), &mut out);
        (result, String::from_utf8(out).unwrap())
    }

    #[test]
    fn typing_the_slug_confirms_and_names_others_comments() {
        let (result, out) = run_confirm(&preview(2, &["erin", "helper"]), "k7m2qz\n");

        assert!(result.is_ok());
        assert!(
            out.contains("2 revisions, 1 thread and 3 comments"),
            "{out}"
        );
        assert!(
            out.contains("2 comments by other people or agents will be deleted too (erin, helper)"),
            "{out}"
        );
        assert!(out.contains("Type k7m2qz to delete it: "), "{out}");
    }

    #[test]
    fn no_other_comments_means_no_warning() {
        let (_result, out) = run_confirm(&preview(0, &[]), "k7m2qz\n");
        assert!(!out.contains("Warning"), "{out}");
    }

    #[test]
    fn anything_but_the_slug_cancels() {
        for typed in ["", "\n", "y\n", "K7M2QZ\n", "k7m2q\n"] {
            let (result, _out) = run_confirm(&preview(0, &[]), typed);
            let err = result.expect_err(typed);
            assert!(format!("{err}").contains("not deleted"), "{typed:?}: {err}");
        }
    }
}
