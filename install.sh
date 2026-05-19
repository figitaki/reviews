#!/usr/bin/env sh
set -eu

REPO="${REVIEWS_REPO:-figitaki/reviews}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
VERSION="${REVIEWS_VERSION:-}"
SKILL_MODE="prompt"
ASSUME_YES=0

usage() {
  cat <<'EOF'
Install the Reviews CLI.

Usage:
  install.sh [options]

Options:
  --version <version>     Install a specific CLI version, e.g. 0.1.0 or cli-v0.1.0.
  --install-dir <dir>     Install the reviews binary into <dir>.
  --with-skills           Also install packaged Reviews agent skills.
  --no-skills             Do not install agent skills.
  --yes                   Answer yes to prompts.
  -h, --help              Show this help.

Environment:
  REVIEWS_VERSION         Same as --version.
  REVIEWS_REPO            GitHub repo to install from. Defaults to figitaki/reviews.
  REVIEWS_RELEASES_API_URL
                          Override the GitHub releases API URL, mainly for tests.
  INSTALL_DIR             Same as --install-dir.
  REVIEWS_SKILLS_DIR      Colon-separated skill destinations for custom agents.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      if [ -z "$VERSION" ]; then
        echo "error: --version requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --install-dir)
      INSTALL_DIR="${2:-}"
      if [ -z "$INSTALL_DIR" ]; then
        echo "error: --install-dir requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --with-skills)
      SKILL_MODE="yes"
      shift
      ;;
    --no-skills)
      SKILL_MODE="no"
      shift
      ;;
    --yes|-y)
      ASSUME_YES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

need curl
need tar

os="$(uname -s)"
arch="$(uname -m)"

case "$os:$arch" in
  Darwin:arm64) target="macos-arm64" ;;
  Darwin:x86_64) target="macos-x64" ;;
  Linux:aarch64|Linux:arm64) target="linux-arm64" ;;
  Linux:x86_64|Linux:amd64) target="linux-x64" ;;
  *)
    echo "error: unsupported platform: $os $arch" >&2
    exit 1
    ;;
esac

tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

tag=""
if [ -n "$VERSION" ]; then
  case "$VERSION" in
    cli-v*) tag="$VERSION" ;;
    v*) tag="cli-${VERSION}" ;;
    *) tag="cli-v${VERSION}" ;;
  esac
  api_url="https://api.github.com/repos/$REPO/releases/tags/$tag"
else
  api_url="https://api.github.com/repos/$REPO/releases"
fi

if [ -n "${REVIEWS_RELEASES_API_URL:-}" ]; then
  api_url="$REVIEWS_RELEASES_API_URL"
fi

echo "Finding Reviews CLI release for $target..."
release_json="$tmp/releases.json"
curl -fsSL "$api_url" -o "$release_json"

asset_url="$(
  sed -n "s/.*\"browser_download_url\": *\"\([^\"]*reviews-cli-[^\"]*-${target}\.tar\.gz\)\".*/\1/p" "$release_json" | head -n 1
)"

if [ -z "$asset_url" ]; then
  echo "error: no Reviews CLI artifact found for $target" >&2
  if [ -n "$tag" ]; then
    echo "looked for tag: $tag" >&2
  fi
  exit 1
fi

archive="$tmp/reviews-cli.tar.gz"
extract_dir="$tmp/extract"
mkdir -p "$extract_dir"

echo "Downloading $asset_url..."
curl -fL "$asset_url" -o "$archive"
tar -xzf "$archive" -C "$extract_dir"

if [ ! -f "$extract_dir/reviews" ]; then
  echo "error: release archive did not contain a reviews binary" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
cp "$extract_dir/reviews" "$INSTALL_DIR/reviews"
chmod 0755 "$INSTALL_DIR/reviews"

echo "Installed reviews to $INSTALL_DIR/reviews"

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    echo "note: $INSTALL_DIR is not on PATH"
    ;;
esac

prompt_yes() {
  question="$1"
  if [ "$ASSUME_YES" -eq 1 ]; then
    return 0
  fi
  if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
    return 1
  fi
  if ! printf "%s [y/N] " "$question" > /dev/tty 2>/dev/null; then
    return 1
  fi
  if ! IFS= read -r answer < /dev/tty 2>/dev/null; then
    return 1
  fi
  case "$answer" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

skill_destinations() {
  if [ -n "${REVIEWS_SKILLS_DIR:-}" ]; then
    old_ifs="$IFS"
    IFS=":"
    for dir in $REVIEWS_SKILLS_DIR; do
      [ -n "$dir" ] && printf '%s\n' "$dir"
    done
    IFS="$old_ifs"
  fi

  if [ -d "$HOME/.codex" ]; then
    printf '%s\n' "$HOME/.codex/skills"
  fi

  if [ -d "$HOME/.claude" ]; then
    printf '%s\n' "$HOME/.claude/skills"
  fi
}

install_skills() {
  src_root="$extract_dir/skills"
  if [ ! -d "$src_root" ]; then
    echo "No packaged skills found in this release archive."
    return 0
  fi

  destinations="$(skill_destinations | awk '!seen[$0]++')"
  if [ -z "$destinations" ]; then
    echo "No supported agent skill directory detected."
    echo "Set REVIEWS_SKILLS_DIR=/path/to/skills to install for a custom harness."
    return 0
  fi

  timestamp="$(date +%Y%m%d%H%M%S)"
  echo "$destinations" | while IFS= read -r dest; do
    [ -z "$dest" ] && continue
    mkdir -p "$dest"
    for skill in reviews-overview writing-review-packets using-reviews-locally; do
      src="$src_root/$skill"
      target_dir="$dest/$skill"
      [ -d "$src" ] || continue

      if [ -e "$target_dir" ] || [ -L "$target_dir" ]; then
        if [ "$ASSUME_YES" -eq 1 ]; then
          backup="$target_dir.backup.$timestamp"
          mv "$target_dir" "$backup"
          echo "Backed up existing $target_dir to $backup"
        elif prompt_yes "Replace existing skill $target_dir?"; then
          backup="$target_dir.backup.$timestamp"
          mv "$target_dir" "$backup"
          echo "Backed up existing $target_dir to $backup"
        else
          echo "Skipped existing $target_dir"
          continue
        fi
      fi

      cp -R "$src" "$target_dir"
      echo "Installed $skill to $target_dir"
    done
  done
}

case "$SKILL_MODE" in
  yes)
    install_skills
    ;;
  no)
    ;;
  prompt)
    if prompt_yes "Install Reviews agent skills for Codex, Claude, or a custom harness?"; then
      install_skills
    fi
    ;;
esac

echo "Done. Configure credentials separately with reviews login or ~/.config/reviews/config.toml."
