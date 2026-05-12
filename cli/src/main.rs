use anyhow::Result;
use clap::{Parser, Subcommand};

mod api;
mod commands;
mod config;
mod git;

#[derive(Parser, Debug)]
#[command(
    name = "reviews",
    version,
    about = "Upload diffs to the Reviews code-review server"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Save server URL + API token to ~/.config/reviews/config.toml
    Login,

    /// Print the currently logged-in user
    Whoami,

    /// Capture a diff and push it as a review (or new patchset with --update)
    Push(commands::push::PushArgs),

    /// Preview the diff that would be pushed, without uploading
    Diff(commands::diff::DiffArgs),

    /// Fetch a review by slug as JSON or Markdown
    Show(commands::show::ShowArgs),

    /// Publish a comment on a review (requires `reviews login`)
    Comment(commands::comment::CommentArgs),
}

fn main() {
    if let Err(err) = run() {
        eprintln!("error: {err:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Login => commands::login::run(),
        Command::Whoami => commands::whoami::run(),
        Command::Push(args) => commands::push::run(args),
        Command::Diff(args) => commands::diff::run(args),
        Command::Show(args) => commands::show::run(args),
        Command::Comment(args) => commands::comment::run(args),
    }
}
