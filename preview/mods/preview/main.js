// herdr-preview: a live preview of one Markdown or HTML file, or a web page.
//
// Two ways to show it:
// - Panel (no props): the "preview-panel" column in layouts/preview.json, toggled by the tab
//   bar's Preview button. It follows ~/.local/state/herdr-preview/target, which the
//   `herdr-preview <file|url>` command writes: line 1 is what to show, line 2 (optional) a label
//   for the header, such as the file behind a Lavish session URL.
// - Pane (props { file }, an absolute path): `herdr-preview <file> right|down`, or
//   herdr-app do pane.split '{"direction":"right","mod":"preview","props":{"file":"/abs/path.md"}}'
//
// Markdown always uses Herdr's native renderer and re-renders on save. In the panel, .html files
// and URLs use a real WebKit view: the "Herdr Preview Web" app (installed by install.sh) floats
// it over this panel's body. This mod starts that app and tells it where the body is in
// ~/.config/herdr-app/herdr-preview/panel.json, rewritten on every change and at least once a
// second; the app hides the view when the file goes stale. Without that app, or outside this
// layout, HTML falls back to the native renderer, which has no CSS and runs no scripts.
//
// This mod runs programs (open, sh, mkdir) and writes outside its folder:
// ~/.config/herdr-app/herdr-preview/ and ~/.local/state/herdr-preview/.

import { View, div } from "gpui-kit";
import { v_flex, h_flex, TextView } from "gpui-base";
import { exec, readTextFile, watchFolder, theme, props, layout, settings, appHome } from "herdr";
import * as fs from "fs/promises";

const WEB_APP = "io.github.tanviirdev.herdr-preview.web";
const MAX_BYTES = 2_000_000;
const MARKDOWN = new Set(["md", "markdown", "mdx", "mdown", "mkd"]);
const HTML = new Set(["html", "htm", "xhtml"]);
const HEADER = 30; // the header bar's height; the web view covers what's below it
const NODES = ["preview-panel", "panel", "work-body", "tabs"]; // what the geometry needs

const isUrl = (s) => /^(https?|file):\/\//i.test(s ?? "");
const extOf = (p) => (p.match(/\.([^./?#]+)(?:[?#].*)?$/)?.[1] ?? "").toLowerCase();
const dirOf = (p) => p.slice(0, p.lastIndexOf("/")) || "/";
const baseOf = (p) => (isUrl(p) ? p.replace(/^[a-z]+:\/\//i, "") : p.slice(p.lastIndexOf("/") + 1));
const tilde = (p, home) => (home && p.startsWith(home + "/") ? "~" + p.slice(home.length) : p);
const findNode = (node, id) => {
  if (!node) return null;
  if (node.id === id) return node;
  for (const child of node.children ?? []) {
    const found = findNode(child, id);
    if (found) return found;
  }
  return null;
};
// The web view can only be placed when the layout has every node the geometry is measured from.
const webLayout = () => { const root = layout(); return NODES.every((id) => findNode(root, id)); };

// Resolves a relative link against the previewed file's folder.
function resolve(from, rel) {
  const parts = (rel.startsWith("/") ? "" : dirOf(from)).split("/");
  for (const seg of rel.split("/")) {
    if (seg === "..") parts.pop();
    else if (seg && seg !== ".") parts.push(seg);
  }
  return "/" + parts.filter(Boolean).join("/");
}

// The native renderer has no CSS or scripting, so their source would only show up as noise.
function htmlBody(html) {
  return html
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/<script\b[\s\S]*?<\/script\s*>/gi, "")
    .replace(/<style\b[\s\S]*?<\/style\s*>/gi, "")
    .replace(/<head\b[\s\S]*?<\/head\s*>/gi, "")
    .replace(/<noscript\b[\s\S]*?<\/noscript\s*>/gi, "");
}

export default class Preview extends View {
  init(initial, cx) {
    // Known at once from Herdr's home (~/.config/herdr-app); confirmed from $HOME below.
    this.home = appHome().replace(/\/\.config\/herdr-app\/?$/, "");
    this.history = [];
    this.label = null;
    this.textMode = false;
    this.webMissing = false;
    this.webDir = `${appHome()}/herdr-preview`;
    this.given = props()?.file ?? initial?.file ?? null;
    this.panel = !this.given;
    this.open(this.given, cx);
    cx.spawn(async (cx) => {
      const r = await exec("sh", ["-c", 'printf %s "$HOME"']).catch(() => null);
      if (r?.stdout) this.home = r.stdout;
      this.mdFallback = await this.readMdFallback();
      cx.notify();
      if (this.panel && this.home) this.follow(cx);
    });
    if (this.panel) cx.timer.every(200, () => this.sync());
  }

  // The app .md files opened in before install.sh took them over (recorded by the
  // Herdr Preview Links app), so "Open" doesn't loop back into another preview.
  async readMdFallback() {
    const text = await readTextFile(`${this.home}/.config/herdr-preview/settings.json`).catch(() => null);
    try { return JSON.parse(text ?? "{}").md_fallback ?? null; } catch { return null; }
  }

  // Panel mode: show whatever herdr-preview last asked for, now and whenever it asks again.
  follow(cx) {
    const dir = `${this.home}/.local/state/herdr-preview`;
    const check = async (cx) => {
      const text = await readTextFile(`${dir}/target`).catch(() => null);
      const [first, second] = (text ?? "").split("\n").map((s) => s.trim());
      const file = first || null;
      if (file && (file !== this.file || (second || null) !== this.label)) {
        this.history = [];
        this.label = second || null;
        this.open(file, cx);
        cx.notify();
      }
    };
    cx.spawn(async (cx) => {
      await exec("mkdir", ["-p", dir]).catch(() => null);
      await check(cx);
      try {
        for (;;) { await watchFolder(dir); await check(cx); }
      } catch {
        cx.timer.every(2000, (cx) => { check(cx); });
      }
    });
  }

  // Tells Herdr Preview Web where this panel's body is on Herdr's window, and whether to show.
  // Measured from the window's right and top edges, which is all the layout fixes: the
  // Files/Changes panel (when shown) and the work area's padding sit to the right.
  sync() {
    if (!this.panel) return;
    const root = layout();
    const own = findNode(root, "preview-panel"), files = findNode(root, "panel");
    const body = findNode(root, "work-body"), tabs = findNode(root, "tabs");
    const pad = body?.padding ?? 0;
    const padV = Array.isArray(pad) ? pad[0] : pad, padH = Array.isArray(pad) ? pad[1] : pad;
    const geometry = {
      visible: Boolean(this.kind === "web" && own && files && body && tabs && !own.hidden && this.size),
      right: padH + (files && !files.hidden ? (files.size?.px ?? 0) + (body?.gap ?? 0) : 0),
      top: (tabs?.size?.px ?? 0) + padV + HEADER,
      width: this.size?.width ?? 0,
      height: Math.max(0, (this.size?.height ?? 0) - HEADER),
      zoom: Number(settings()?.zoom ?? 1) || 1,
    };
    const text = JSON.stringify(geometry);
    const now = Date.now();
    if (text === this.lastGeometry && now - (this.lastWrite ?? 0) < 1000) return;
    this.lastGeometry = text;
    this.lastWrite = now;
    fs.mkdir(this.webDir, { recursive: true })
      .then(() => fs.writeFile(`${this.webDir}/panel.json`, text))
      .catch(() => {});
  }

  reloadWeb() {
    fs.mkdir(this.webDir, { recursive: true })
      .then(() => fs.writeFile(`${this.webDir}/reload`, String(Date.now())))
      .catch(() => {});
  }

  async close() {
    if (this.panel) {
      await fs.writeFile(`${this.webDir}/panel.json`, '{"visible":false,"right":0,"top":0,"width":0,"height":0}').catch(() => {});
    }
  }

  open(file, cx) {
    this.file = file;
    const web = this.panel && !this.textMode && !this.webMissing && webLayout()
      && (isUrl(file) || HTML.has(extOf(file ?? "")));
    this.kind = !file ? null : web ? "web" : HTML.has(extOf(file)) ? "html" : MARKDOWN.has(extOf(file)) ? "markdown" : "text";
    this.text = null;
    this.error = file ? null : this.panel
      ? "Nothing to preview yet. Run `herdr-preview <file>` in a terminal."
      : "No file. Run `herdr-preview <file.md|file.html>` in a terminal.";
    this.rev = (this.rev ?? 0) + 1;
    if (!file) return;
    if (this.kind === "web") {
      this.startWeb(cx);
      this.sync();
      if (isUrl(file)) return;
    } else if (isUrl(file)) {
      this.error = this.webMissing
        ? "Web pages need the Herdr Preview Web app. Run install.sh from the herdr-preview repository."
        : "Web pages show in the Preview panel only.";
      return;
    }
    this.load(cx);
    this.watch(cx);
  }

  // Starts the web view app without bringing it forward (-g), so Herdr stays the frontmost app.
  // If it isn't installed, fall back to the native renderer.
  startWeb(cx) {
    const file = this.file;
    cx.spawn(async (cx) => {
      const r = await exec("open", ["-g", "-b", WEB_APP]).catch(() => ({ code: 1 }));
      if (r.code === 0 || this.file !== file) return;
      this.webMissing = true;
      this.open(file, cx);
      this.sync();
      cx.notify();
    });
  }

  load(cx) {
    const file = this.file;
    if (this.kind === "web") { this.reloadWeb(); return; } // a saved .html reloads the web view
    cx.spawn(async (cx) => {
      let raw = null, error = null;
      try { raw = await readTextFile(file); } catch (e) { error = String(e); }
      if (file !== this.file) return;
      if (raw === null) {
        this.text = null;
        this.error = error || `Cannot read ${baseOf(file)} (missing, binary or unreadable).`;
      } else if (raw.length > MAX_BYTES) {
        this.text = null;
        this.error = `${baseOf(file)} is larger than 2 MB; open it elsewhere.`;
      } else {
        this.error = null;
        this.text = this.kind === "html" ? htmlBody(raw)
          : this.kind === "markdown" ? raw
          : "```" + extOf(file) + "\n" + raw + "\n```";
      }
      cx.notify();
    });
  }

  // macOS watches the folder recursively, so keep only wakeups that touch this file
  // (or the folder itself, which means "refresh everything").
  watch(cx) {
    const file = this.file, dir = dirOf(file);
    cx.spawn(async (cx) => {
      try {
        while (this.file === file) {
          const changed = await watchFolder(dir);
          if (this.file !== file) return;
          if (changed.some((p) => p === file || p === dir)) this.load(cx);
        }
      } catch {
        // No watcher available: poll gently instead.
        cx.timer.every(3000, (cx) => { if (this.file === file) this.load(cx); });
      }
    });
  }

  link(url, cx) {
    if (/^(https?|mailto):/i.test(url)) { exec("open", [url]); return; }
    let path = url.replace(/^file:\/\//i, "").split("#")[0].split("?")[0];
    if (!path) return; // an in-page anchor
    try { path = decodeURIComponent(path); } catch {}
    const target = path.startsWith("/") && !path.startsWith(dirOf(this.file)) && !url.startsWith("file:")
      ? resolve(this.file, path.slice(1)) : resolve(this.file, path);
    const ext = extOf(target);
    if (MARKDOWN.has(ext) || HTML.has(ext)) {
      this.history.push(this.file);
      this.label = null;
      this.open(target, cx);
      cx.notify();
    } else {
      exec("open", [target]);
    }
  }

  // "Open" hands the file to another app: Markdown to the app it opened in before the
  // takeover (if install.sh took .md files over), everything else to its default app.
  openElsewhere() {
    if (this.kind === "markdown" && this.mdFallback) exec("open", ["-b", this.mdFallback, this.file]);
    else exec("open", [this.file]);
  }

  button(t, id, label, onClick) {
    return div().id(id).px(8).py(2).rounded(5).flex_none()
      .text_color(t.muted).cursor_pointer()
      .hover((s) => s.bg(t.hover).text_color(t.foreground))
      .on_click(onClick)
      .child(label);
  }

  render(cx) {
    // Props can arrive or change after init (a pane restored with its tab, a re-split).
    const given = props()?.file ?? null;
    if (given && given !== this.given) {
      this.given = given;
      this.history = [];
      this.open(given, cx);
    }
    const t = theme();
    const name = this.label ? baseOf(this.label) : this.file ? baseOf(this.file) : "Preview";
    const where = this.label ? tilde(dirOf(this.label), this.home)
      : this.file && !isUrl(this.file) ? tilde(dirOf(this.file), this.home) : "";
    const htmlFile = Boolean(this.file) && !isUrl(this.file) && HTML.has(extOf(this.file ?? ""));
    const header = h_flex().flex_none().items_center().gap(6).px(10).h(HEADER)
      .bg(t.chrome).border_b(1).border_color(t.border).text_size(12)
      .when(this.history.length > 0, (el) => el.child(this.button(t, "back", "←", (_e, cx) => {
        this.label = null;
        this.open(this.history.pop(), cx); cx.notify();
      })))
      .child(div().flex_none().min_w(0).truncate().font_semibold().text_color(t.foreground).child(name))
      .when(Boolean(this.label && isUrl(this.file)), (el) => el.child(div().flex_none().text_color(t.accent).child("Lavish session")))
      .child(div().flex_1().min_w(0).truncate().text_color(t.dim).child(where))
      .when(this.kind === "html", (el) => el.child(div().flex_none().text_color(t.dim)
        .child(this.webMissing ? "no CSS (web view not installed)" : "no CSS")))
      // An .html file in the panel can switch between the web view and the native renderer.
      .when(this.panel && htmlFile && !this.webMissing && webLayout(), (el) => el
        .child(this.button(t, "mode", this.kind === "web" ? "Text" : "Web", (_e, cx) => {
          this.textMode = this.kind === "web";
          this.open(this.file, cx);
          this.sync();
          cx.notify();
        })))
      .when(Boolean(this.file), (el) => el
        .child(this.button(t, "reload", "Reload", (_e, cx) => this.load(cx)))
        .child(this.button(t, "open", "Open", () => this.openElsewhere())));

    let body;
    if (this.kind === "web" && !this.error) {
      // Herdr Preview Web draws the page over this. If it stays visible, the app isn't running.
      body = div().size_full().p(16).text_color(t.dim).child("Opening the web view…");
    } else if (this.error) {
      body = div().p(16).text_color(t.dim).child(this.error);
    } else if (this.text === null) {
      body = div().p(16).text_color(t.dim).child("Loading…");
    } else {
      const id = `doc-${this.rev}`;
      const view = this.kind === "html" ? TextView.html(id, this.text) : TextView.markdown(id, this.text);
      body = view.scrollable(true).selectable(true)
        .on_link_click((url, cx) => this.link(url, cx))
        .size_full().px(20).py(14).text_size(14).text_color(t.foreground);
    }

    return v_flex().id("root").size_full().bg(t.background)
      .on_size_change((size, cx) => { this.size = size; this.sync(); cx.notify(); })
      .child(header)
      .child(div().flex_1().min_h(0).child(body));
  }
}
