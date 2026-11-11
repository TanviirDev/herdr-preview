#!/bin/sh
# Removes herdr-preview. Gives .md files back to the app they opened in before, switches the
# Herdr window back to the main layout, and deletes only what install.sh added.
# Uses the same HERDR_APP_HOME, HERDR_PREVIEW_BIN_DIR and HERDR_PREVIEW_APPS_DIR as install.sh.
set -eu

app_home=${HERDR_APP_HOME:-$HOME/.config/herdr-app}
bin_dir=${HERDR_PREVIEW_BIN_DIR:-$HOME/.local/bin}
apps_dir=${HERDR_PREVIEW_APPS_DIR:-$HOME/Applications}
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

say() { printf '%s\n' "$*"; }
ours() { grep -rqsE 'herdr-preview|preview-tabs' "$1"; }
remove() {
  [ -e "$1" ] || [ -L "$1" ] || return 0
  if ours "$1"; then rm -rf "$1"; say "removed: $1"; else say "kept (not from herdr-preview): $1"; fi
}

# 1. .md files go back to their previous app.
links="$apps_dir/Herdr Preview Links.app/Contents/MacOS/HerdrPreviewLinks"
if [ -x "$links" ]; then "$links" --uninstall || say "warning: couldn't hand .md files back; set their app in Finder (Cmd+I, Open with, Change All)"; fi

# 2. Leave the preview layout if it's showing, before its files go.
if command -v herdr-app >/dev/null 2>&1; then
  if herdr-app status 2>/dev/null | grep -q '"layout": "preview"'; then
    herdr-app do layout.switch '{"name":"main"}' >/dev/null 2>&1 && say "switched the Herdr window back to the main layout"
  fi
fi

# 3. The helper apps.
pkill -f "Herdr Preview Web.app/Contents/MacOS/HerdrPreviewWeb" 2>/dev/null || true
for name in "Herdr Preview Web" "Herdr Preview Links"; do
  app="$apps_dir/$name.app"
  [ -d "$app" ] || continue
  "$lsregister" -u "$app" 2>/dev/null || true
  rm -rf "$app"
  say "removed: $app"
done

# 4. The layout, mods and command.
remove "$app_home/layouts/preview.json"
remove "$app_home/mods/preview"
remove "$app_home/mods/preview-tabs"
remove "$bin_dir/herdr-preview"
if [ -L "$bin_dir/mdp" ] && [ "$(readlink "$bin_dir/mdp")" = herdr-preview ]; then
  rm "$bin_dir/mdp"
  say "removed: $bin_dir/mdp"
fi

# 5. Its own state files only; the folders go if nothing else is in them.
rm -f "$app_home/herdr-preview/panel.json" "$app_home/herdr-preview/reload" "$app_home/herdr-preview/helper.json"
rm -f "$HOME/.local/state/herdr-preview/target" "$HOME/.local/state/herdr-preview/target.tmp"
rm -f "$HOME/.config/herdr-preview/settings.json"
rmdir "$app_home/herdr-preview" "$HOME/.local/state/herdr-preview" "$HOME/.config/herdr-preview" 2>/dev/null || true

say "Done."
