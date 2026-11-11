#!/bin/sh
# Installs herdr-preview: a Preview panel for the Herdr app, on macOS or Linux.
# (Windows: install.ps1.) On Linux it installs the panel, the layout and the command; the web
# view and .md click routing are macOS-only, so HTML shows as plain text there.
#
# Usage: ./install.sh [--no-md-clicks] [--no-switch] [--update]
#   --no-md-clicks  leave .md files alone: Cmd-clicked .md links won't open in the panel (macOS)
#   --no-switch     don't switch the Herdr window to the "preview" layout afterwards
#   --update        replace an earlier herdr-preview install's files (never anyone else's)
#
# Where things go (override with these variables):
#   HERDR_APP_HOME          ~/.config/herdr-app  layouts/preview.json, mods/preview, mods/preview-tabs
#   HERDR_PREVIEW_BIN_DIR   ~/.local/bin         herdr-preview, plus an mdp alias when that name is free
#   HERDR_PREVIEW_APPS_DIR  ~/Applications       Herdr Preview Web.app, Herdr Preview Links.app
# Undo everything with ./uninstall.sh.
set -eu
here=$(cd "$(dirname "$0")" && pwd)

md_clicks=1 switch=1 update=0
for arg in "$@"; do
  case $arg in
    --no-md-clicks) md_clicks=0 ;;
    --no-switch) switch=0 ;;
    --update) update=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "install.sh: unknown option $arg (see --help)" >&2; exit 2 ;;
  esac
done

app_home=${HERDR_APP_HOME:-$HOME/.config/herdr-app}
bin_dir=${HERDR_PREVIEW_BIN_DIR:-$HOME/.local/bin}
apps_dir=${HERDR_PREVIEW_APPS_DIR:-$HOME/Applications}
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

mac=0
case "$(uname -s)" in
  Darwin) mac=1 ;;
  Linux) say "Linux: installing the panel, layout and command; the web view and .md click routing are macOS-only" ;;
  *) die "unsupported system $(uname -s); on Windows run install.ps1" ;;
esac
[ "$mac" = 0 ] || command -v swiftc >/dev/null 2>&1 || die "swiftc not found. Install the Xcode Command Line Tools first: xcode-select --install"
have_herdr=1
command -v herdr-app >/dev/null 2>&1 || { have_herdr=0; say "note: herdr-app isn't on PATH, so nothing will be checked or switched in the Herdr app"; }

# Every file herdr-preview installs names itself (the layout names its tab bar, preview-tabs).
ours() { grep -rqsE 'herdr-preview|preview-tabs' "$1"; }

# place <src> <dst>: copy, never over someone else's file; with --update, replace our own.
place() {
  src=$1 dst=$2
  if [ -e "$dst" ]; then
    if diff -rq -x gpui-kit.d.ts -x jsconfig.json "$src" "$dst" >/dev/null 2>&1; then
      say "unchanged: $dst"
      return
    fi
    if ! ours "$dst"; then die "$dst exists and isn't from herdr-preview; move it aside first"; fi
    [ "$update" = 1 ] || die "$dst is from an earlier herdr-preview install; rerun with --update to replace it"
    rm -rf "$dst"
  fi
  mkdir -p "$(dirname "$dst")"
  cp -R "$src" "$dst"
  say "installed: $dst"
}

# 1. macOS: the two helper apps, built on this Mac, before the mods: Herdr reloads a mod the moment
#    its files land, and a reloaded panel starts the web view app straight away. Quit a running
#    web view so the new build starts.
if [ "$mac" = 1 ]; then
  pkill -x HerdrPreviewWeb 2>/dev/null || true
  "$here/native/build.sh" "$apps_dir"
  "$lsregister" -f "$apps_dir/Herdr Preview Web.app" "$apps_dir/Herdr Preview Links.app"
fi

# 2. The Herdr layout and its two mods.
place "$here/preview/layouts/preview.json" "$app_home/layouts/preview.json"
place "$here/preview/mods/preview" "$app_home/mods/preview"
place "$here/preview/mods/preview-tabs" "$app_home/mods/preview-tabs"

# 3. The command, and a short mdp alias only when nothing else has that name.
place "$here/bin/herdr-preview" "$bin_dir/herdr-preview"
chmod +x "$bin_dir/herdr-preview"
if [ ! -e "$bin_dir/mdp" ] && ! command -v mdp >/dev/null 2>&1; then
  ln -s herdr-preview "$bin_dir/mdp"
  say "installed: $bin_dir/mdp (alias for herdr-preview)"
else
  say "note: mdp is already taken here, so no alias; use herdr-preview"
fi
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) say "note: $bin_dir isn't on your PATH; add it to use herdr-preview from a terminal" ;;
esac


# 4. Cmd-clicked .md links: make Herdr Preview Links the .md default, recording the old one.
if [ "$mac" = 0 ]; then
  : # .md click routing is macOS-only
elif [ "$md_clicks" = 1 ]; then
  if "$apps_dir/Herdr Preview Links.app/Contents/MacOS/HerdrPreviewLinks" --install --cli "$bin_dir/herdr-preview"; then
    say "Cmd-clicked .md links in Herdr now open in the Preview panel"
  else
    say "warning: macOS didn't make Herdr Preview Links the .md default, so Cmd-clicked .md links won't reach the panel."
    say "         Set it by hand: select a .md file in Finder, Cmd+I, Open with: Herdr Preview Links, Change All."
  fi
else
  say "skipped: .md files keep their current app (--no-md-clicks)"
fi

# 5. Check the mods load, then show the layout.
if [ "$have_herdr" = 1 ]; then
  herdr-app check "$app_home/mods/preview"
  herdr-app check "$app_home/mods/preview-tabs"
  if [ "$switch" = 1 ]; then
    if herdr-app do layout.switch '{"name":"preview"}' >/dev/null 2>&1; then
      say "switched the Herdr window to the preview layout (Ctrl+Shift+L cycles layouts)"
    else
      say "note: open the Herdr app, then pick the preview layout (Ctrl+Shift+L cycles layouts)"
    fi
  fi
fi

say ""
say "Done. Click Preview at the top right of the Herdr window, or run: herdr-preview README.md"
