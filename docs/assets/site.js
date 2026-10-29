(() => {
  "use strict";
  const doc = document.documentElement;
  const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const clamp = (value, min, max) => Math.min(max, Math.max(min, value));
  const NS = "http://www.w3.org/2000/svg";
  const curves = {
    inOut: (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2),
    out: (t) => 1 - Math.pow(1 - t, 3),
    linear: (t) => t,
  };

  // ---------- small helpers ----------

  const h = (tag, props = {}, ...children) => {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(props)) {
      if (value == null || value === false) continue;
      if (key === "class") node.className = value;
      else if (key === "text") node.textContent = value;
      else if (key === "style") node.style.cssText = value;
      else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
      else node.setAttribute(key, value === true ? "" : value);
    }
    node.append(...children.flat().filter((child) => child != null && child !== false));
    return node;
  };
  const s = (tag, attrs = {}) => {
    const node = document.createElementNS(NS, tag);
    for (const [key, value] of Object.entries(attrs)) if (value != null) node.setAttribute(key, value);
    return node;
  };
  const icon = (name, extra = "") => {
    const svg = s("svg", { class: `ui-icon ui-${name} ${extra}`.trim(), viewBox: "0 0 20 20", "aria-hidden": "true" });
    svg.append(s("use", { href: `#ui-${name}` }));
    return svg;
  };
  const rectPath = (x, y, w, hgt, r) => {
    r = Math.max(0, Math.min(r, w / 2, hgt / 2));
    if (r < 0.01) return `M${x} ${y}h${w}v${hgt}h${-w}Z`;
    return `M${x + r} ${y}H${x + w - r}A${r} ${r} 0 0 1 ${x + w} ${y + r}V${y + hgt - r}A${r} ${r} 0 0 1 ${x + w - r} ${y + hgt}H${x + r}A${r} ${r} 0 0 1 ${x} ${y + hgt - r}V${y + r}A${r} ${r} 0 0 1 ${x + r} ${y}Z`;
  };
  const inset = (r, d) => ({ x: r.x + d, y: r.y + d, w: r.w - 2 * d, h: r.h - 2 * d });
  const contains = (r, p) => p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h;

  // A run of timed steps that any interaction can cancel.
  const STOP = Symbol("stopped");
  class Script {
    constructor() {
      this.controller = new AbortController();
    }
    get stopped() {
      return this.controller.signal.aborted;
    }
    stop() {
      this.controller.abort();
    }
    wait(ms) {
      return new Promise((resolve, reject) => {
        if (this.stopped) return reject(STOP);
        const timer = setTimeout(resolve, ms);
        this.controller.signal.addEventListener("abort", () => (clearTimeout(timer), reject(STOP)), { once: true });
      });
    }
    tween(ms, step, curve = curves.inOut) {
      return new Promise((resolve, reject) => {
        if (this.stopped) return reject(STOP);
        const began = performance.now();
        const frame = (now) => {
          if (this.stopped) return reject(STOP);
          const t = Math.min(1, (now - began) / ms);
          step(curve(t));
          if (t < 1) requestAnimationFrame(frame);
          else resolve();
        };
        requestAnimationFrame(frame);
      });
    }
  }
  const quiet = (error) => {
    if (error !== STOP) throw error;
  };

  // Parts of each section rise once as they enter; anything still hidden after load is shown.
  const risers = [...document.querySelectorAll("[data-rise]")];
  if ("IntersectionObserver" in window && !reduced) {
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          // A fast scroll can carry a part straight past the screen; it still counts as seen.
          if (!entry.isIntersecting && entry.boundingClientRect.top >= 0) continue;
          entry.target.classList.add("is-in");
          observer.unobserve(entry.target);
        }
      },
      { rootMargin: "0px 0px -8% 0px", threshold: 0.08 },
    );
    risers.forEach((el) => observer.observe(el));
    addEventListener("load", () =>
      setTimeout(() => {
        for (const el of risers) {
          const box = el.getBoundingClientRect();
          if (box.top < innerHeight) el.classList.add("is-in");
        }
      }, 2500),
    );
  } else {
    risers.forEach((el) => el.classList.add("is-in"));
  }

  // Older browsers ignore <details name>; keep one answer open at a time there too.
  const answers = [...document.querySelectorAll(".faq-item")];
  answers.forEach((item) =>
    item.addEventListener("toggle", () => {
      if (item.open) answers.forEach((other) => other !== item && other.open && (other.open = false));
    }),
  );

  const sceneData = document.getElementById("scene-data");
  if (!sceneData) return;
  const scene = JSON.parse(sceneData.textContent);
  const [PAGE_W, PAGE_H] = scene.page;
  const DEFAULT_CAPTURE = { x: scene.capture[0], y: scene.capture[1], w: scene.capture[2], h: scene.capture[3] };
  // The area of the last capture, which R takes again while selecting. Like the app, it outlives a restart.
  const LAST_KEY = "transeen.lastArea";
  let lastArea = (() => {
    try {
      const r = JSON.parse(localStorage.getItem(LAST_KEY));
      return r && [r.x, r.y, r.w, r.h].every(Number.isFinite) && r.w >= 12 && r.h >= 12 ? r : null;
    } catch {
      return null;
    }
  })();
  const rememberArea = (rect) => {
    lastArea = { x: rect.x, y: rect.y, w: rect.w, h: rect.h };
    try {
      localStorage.setItem(LAST_KEY, JSON.stringify(lastArea));
    } catch {}
  };
  const ORDER = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "es", "de"];
  const languages = scene.languages;
  const pageSources = {};
  for (const img of document.getElementById("kumo-pages")?.content.querySelectorAll("img") ?? []) pageSources[img.dataset.lang] = img.getAttribute("src");
  const pageFor = (lang) => pageSources[lang] || pageSources.ja;
  const warm = (lang) => {
    const img = new Image();
    img.decoding = "async";
    img.src = pageFor(lang);
    return img.decode().catch(() => {});
  };

  // ---------- what the app says, in its own words ----------

  const shortOf = (lang) => languages[lang].short;
  const directionText = (source, target) => (source === target ? `${shortOf(source)} 原文` : `${shortOf(source)} → ${shortOf(target)}`);
  const SPACE_HELP = "按住看原文（空格）";
  const SWAP_HELP = " · 再按 F1 交换语言";
  const HINT = "拖动图片移动 · 拖动边缘调整范围 · 选择工具标注";
  const doneStatus = (count) => (count ? `已翻译 ${count} 处 · ${SPACE_HELP}${SWAP_HELP}` : `没有需要翻译的文字${SWAP_HELP}`);

  // The page's text blocks inside a capture, in reading order, with the translation for `target`.
  const blocksIn = (rect, target) =>
    scene.blocks
      .filter((block) => {
        const [x, y, w, hgt] = block.r;
        const ix = Math.max(0, Math.min(x + w, rect.x + rect.w) - Math.max(x, rect.x));
        const iy = Math.max(0, Math.min(y + hgt, rect.y + rect.h) - Math.max(y, rect.y));
        return ix * iy >= w * hgt * 0.6 && /[\p{L}]/u.test(block.o) && !/^[A-Z0-9 ]+$/.test(block.o);
      })
      .map((block) => ({ original: block.o, translation: target === "ja" ? null : block.t[target] || null }));

  // Where the selection snaps under the pointer: the production region finder's answer for the
  // 8-point cell, or the whole page.
  const regionAt = (p) => {
    const map = scene.regions;
    const column = clamp(Math.floor(p.x / map.cell), 0, map.columns - 1);
    const row = clamp(Math.floor(p.y / map.cell), 0, map.rows - 1);
    const digits = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    const at = (row * map.columns + column) * map.width;
    const code = map.grid.slice(at, at + map.width);
    if (code.includes(".")) return { x: 0, y: 0, w: PAGE_W, h: PAGE_H };
    const index = map.width === 1 ? digits.indexOf(code) : digits.indexOf(code[0]) * 62 + digits.indexOf(code[1]);
    const [x, y, w, hgt] = map.rects[index];
    return { x, y, w, h: hgt };
  };

  // ---------- marks, drawn the way Annotation.draw draws them ----------

  const COLORS = [
    ["red", "#ff383c"],
    ["orange", "#ff8d28"],
    ["yellow", "#ffcc00"],
    ["green", "#34c759"],
    ["blue", "#0088ff"],
    ["white", "#ffffff"],
  ];
  const colorValue = (name) => (COLORS.find(([key]) => key === name) || COLORS[0])[1];
  const luminance = (hex) => {
    const n = parseInt(hex.slice(1), 16);
    return (0.2126 * ((n >> 16) & 255) + 0.7152 * ((n >> 8) & 255) + 0.0722 * (n & 255)) / 255;
  };
  const markBounds = (mark) => {
    if (mark.tool === "number") {
      const d = Math.max(20 + mark.width * 2, String(mark.number).length * (12 + mark.width) * 0.62 + 12);
      return { x: mark.points[0][0] - d / 2, y: mark.points[0][1] - d / 2, w: d, h: d };
    }
    const xs = mark.points.map((p) => p[0]);
    const ys = mark.points.map((p) => p[1]);
    return { x: Math.min(...xs), y: Math.min(...ys), w: Math.max(...xs) - Math.min(...xs), h: Math.max(...ys) - Math.min(...ys) };
  };
  const drawMark = (mark) => {
    const color = colorValue(mark.color);
    const b = markBounds(mark);
    if (mark.tool === "number") {
      const g = s("g", { class: "mark-number" });
      g.append(s("circle", { cx: b.x + b.w / 2, cy: b.y + b.h / 2, r: b.w / 2, fill: color }));
      const text = s("text", { x: b.x + b.w / 2, y: b.y + b.h / 2 + 0.5, fill: luminance(color) > 0.6 ? "#000" : "#fff", style: `font-size:${12 + mark.width}px` });
      text.textContent = String(mark.number);
      g.append(text);
      return g;
    }
    let d = "";
    if (mark.tool === "rectangle") d = `M${b.x} ${b.y}h${b.w}v${b.h}h${-b.w}Z`;
    else if (mark.tool === "ellipse") {
      const rx = b.w / 2, ry = b.h / 2, cx = b.x + rx, cy = b.y + ry;
      d = `M${cx - rx} ${cy}a${rx} ${ry} 0 1 0 ${2 * rx} 0a${rx} ${ry} 0 1 0 ${-2 * rx} 0`;
    } else if (mark.tool === "pen") d = "M" + mark.points.map((p) => p.join(" ")).join("L");
    else if (mark.tool === "arrow") {
      const [start, end] = [mark.points[0], mark.points[mark.points.length - 1]];
      const angle = Math.atan2(end[1] - start[1], end[0] - start[0]);
      const length = Math.max(12, mark.width * 4);
      d = `M${start.join(" ")}L${end.join(" ")}`;
      for (const offset of [-Math.PI / 6, Math.PI / 6]) d += `M${end.join(" ")}L${end[0] - Math.cos(angle + offset) * length} ${end[1] - Math.sin(angle + offset) * length}`;
    }
    return s("path", { class: "mark-stroke", d, stroke: color, "stroke-width": mark.width });
  };
  const hitMark = (mark, p) => {
    const b = markBounds(mark);
    const pad = mark.width / 2 + 5;
    if (mark.tool === "number") return Math.hypot(p.x - (b.x + b.w / 2), p.y - (b.y + b.h / 2)) <= b.w / 2 + 2;
    if (mark.tool === "rectangle" || mark.tool === "ellipse") {
      const outer = inset(b, -pad), inner = inset(b, pad);
      return contains(outer, p) && !(inner.w > 0 && inner.h > 0 && contains(inner, p));
    }
    const segments = mark.points.slice(1).map((q, i) => [mark.points[i], q]);
    return segments.some(([a, c]) => {
      const dx = c[0] - a[0], dy = c[1] - a[1];
      const t = clamp(((p.x - a[0]) * dx + (p.y - a[1]) * dy) / (dx * dx + dy * dy || 1), 0, 1);
      return Math.hypot(p.x - (a[0] + t * dx), p.y - (a[1] + t * dy)) <= pad;
    });
  };

  // The marks every demonstration starts from: a box round the price, two notes and an arrow.
  const SAMPLE_MARKS = () => [
    { tool: "rectangle", points: [[6, 100], [210, 158]], color: "red", width: 4 },
    { tool: "number", points: [[318, 175]], color: "red", width: 4, number: 1 },
    { tool: "number", points: [[318, 222]], color: "orange", width: 4, number: 2 },
    { tool: "arrow", points: [[296, 236], [232, 222]], color: "orange", width: 4 },
  ];

  // ---------- floating menus and popovers live above everything, outside clipped stages ----------

  const floatLayer = h("div", { class: "float-layer", "data-ui": "" });
  document.body.append(floatLayer);
  let openFloat = null;
  const closeFloat = () => {
    if (!openFloat) return;
    const current = openFloat;
    openFloat = null;
    current.el.classList.remove("is-open");
    current.onClose?.();
    setTimeout(() => current.el.remove(), 160);
  };
  addEventListener("pointerdown", (event) => {
    if (openFloat && !openFloat.el.contains(event.target) && !openFloat.anchor?.contains(event.target)) closeFloat();
  });
  addEventListener("keydown", (event) => {
    if (event.key === "Escape" && openFloat) {
      event.stopPropagation();
      closeFloat();
    }
  }, true);
  addEventListener("scroll", () => openFloat && !openFloat.sticky && closeFloat(), { passive: true });

  // `anchor` is a client rect; the float is drawn at `scale` so it matches the scaled screen.
  const placeFloat = (el, anchor, scale, { below = true, align = "start", gap = 4 } = {}) => {
    el.style.transformOrigin = "0 0";
    el.style.scale = String(scale);
    const width = el.offsetWidth * scale, height = el.offsetHeight * scale;
    let x = align === "center" ? anchor.left + anchor.width / 2 - width / 2 : anchor.left;
    x = clamp(x, 8, innerWidth - width - 8);
    let y = anchor.bottom + gap;
    let above = !below || y + height > innerHeight - 8;
    if (above && anchor.top - gap - height < 8) above = false;
    if (above) y = anchor.top - gap - height;
    el.style.left = `${x + scrollX}px`;
    el.style.top = `${y + scrollY}px`;
    el.classList.toggle("is-above", above);
    return { x, y, width, height, above };
  };

  const openMenu = (items, anchorEl, scale, options = {}) => {
    closeFloat();
    const menu = h("div", { class: "menu", role: "menu" });
    for (const item of items) {
      if (item.rule) menu.append(h("div", { class: "menu-rule", role: "separator" }));
      else if (item.head) menu.append(h("div", { class: "menu-head", text: item.head }));
      else {
        const button = h(
          "button",
          { class: "menu-item", type: "button", role: item.check != null ? "menuitemradio" : "menuitem", "aria-checked": item.check == null ? null : String(!!item.check), disabled: item.disabled },
          h("span", { class: "menu-mark" }, item.check ? icon("check") : item.icon ? icon(item.icon) : null),
          h("span", { text: item.label }),
          item.kbd ? h("kbd", { text: item.kbd }) : null,
        );
        button.addEventListener("click", () => {
          closeFloat();
          item.action?.();
        });
        menu.append(button);
      }
    }
    floatLayer.append(menu);
    const anchor = options.point ? { left: options.point.x, right: options.point.x, top: options.point.y, bottom: options.point.y, width: 0, height: 0 } : anchorEl.getBoundingClientRect();
    placeFloat(menu, anchor, scale, { below: true, gap: options.point ? 2 : 6 });
    openFloat = { el: menu, anchor: anchorEl, onClose: options.onClose };
    requestAnimationFrame(() => {
      menu.classList.add("is-open");
      if (options.focus) menu.querySelector(".menu-item:not(:disabled)")?.focus({ preventScroll: true });
    });
    menu.addEventListener("keydown", (event) => {
      const list = [...menu.querySelectorAll(".menu-item:not(:disabled)")];
      const index = list.indexOf(document.activeElement);
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        list[(index + (event.key === "ArrowDown" ? 1 : -1) + list.length) % list.length]?.focus();
      }
    });
    return menu;
  };

  // ---------- the toolbar ----------

  const TOOLS = [
    ["move", "cursorarrow", "选择 / 移动"],
    ["rectangle", "rectangle", "矩形"],
    ["ellipse", "circle", "椭圆"],
    ["arrow", "arrow", "箭头"],
    ["pen", "pencil", "画笔"],
    ["number", "number", "编号"],
  ];

  class Toolbar {
    constructor(onAction) {
      const button = (props, ...children) => h("button", { type: "button", class: "tb-btn", ...props }, ...children);
      this.segments = ["original", "translation"].map((id) => button({ class: "tb-btn tb-seg is-neutral", role: "radio", "data-action": id, title: "切换原文 / 译文（Tab）；按住看原文（空格）" }, id === "original" ? "原文" : "译文"));
      this.tools = TOOLS.map(([id, glyph, title]) => button({ "data-action": `tool.${id}`, "aria-label": title, title, "aria-pressed": "false" }, icon(glyph)));
      this.text = button({ class: "tb-btn tb-wide", "data-action": "text", title: "查看完整译文和原文，复制文字", "aria-expanded": "false" }, icon("text"), "文字");
      this.pin = button({ "data-action": "pin", "aria-label": "钉到屏幕上，可继续截图", title: "钉到屏幕上，可继续截图" }, icon("pin"));
      this.more = button({ "data-action": "more", "aria-label": "更多操作", title: "保存与更多操作", "aria-haspopup": "menu" }, icon("ellipsis"));
      this.copyLabel = h("span", { text: "复制" });
      this.copyIcon = icon("copy");
      this.copy = h("button", { type: "button", class: "tb-copy", "data-action": "copy", title: "复制图片（⌘C）" }, this.copyIcon, this.copyLabel);
      this.close = button({ "data-action": "close", "aria-label": "关闭（Esc）", title: "关闭（Esc）" }, icon("xmark"));
      this.lang = h("button", { type: "button", class: "tb-lang", "data-action": "lang", title: "更改原文或译文语言", "aria-haspopup": "menu" }, icon("globe"), h("span"), icon("chevron"));
      this.status = h("p", { class: "tb-status", "aria-live": "polite" });
      this.swatches = COLORS.map(([name, value], i) => h("button", { type: "button", class: "tb-swatch", role: "radio", "data-action": `color.${name}`, "data-color": name, style: `--c:${value}`, "aria-label": ["红色", "橙色", "黄色", "绿色", "蓝色", "白色"][i] }, h("i")));
      this.widths = [2, 4, 8].map((w) => button({ class: "tb-btn tb-width is-neutral", role: "radio", "data-action": `width.${w}`, "aria-label": `线宽 ${w}`, title: `线宽：${w}` }, h("i", { style: `--h:${w / 2}px` })));
      this.undo = button({ "data-action": "undo", "aria-label": "撤销（⌘Z）", title: "撤销（⌘Z）" }, icon("undo"));
      this.redo = button({ "data-action": "redo", "aria-label": "重做（⇧⌘Z）", title: "重做（⇧⌘Z）" }, icon("redo"));
      this.trash = button({ "data-action": "delete", "aria-label": "删除选中标注（Delete）", title: "删除选中标注（Delete）" }, icon("trash"));
      this.el = h(
        "div",
        { class: "tb is-plain", role: "toolbar", "aria-label": "Transeen 工具栏" },
        h(
          "div",
          { class: "tb-main" },
          h("div", { class: "tb-compare", role: "radiogroup", "aria-label": "原文 / 译文" }, this.segments),
          h("div", { class: "tb-working" }, h("svg", {}), h("span", { text: "翻译中" })),
          button({ class: "tb-btn tb-wide tb-translate", "data-action": "translate", title: "翻译选中区域（T）" }, icon("translate"), "翻译"),
          h("div", { class: "tb-sep" }),
          h("div", { class: "tb-group" }, this.tools),
          h("div", { class: "tb-sep" }),
          h("div", { class: "tb-group" }, this.text, this.pin, this.more, this.copy, this.close),
        ),
        h("div", { class: "tb-divider" }),
        h("div", { class: "tb-info" }, this.lang, this.status),
        h("div", { class: "tb-divider tb-inspector-divider" }),
        h(
          "div",
          { class: "tb-inspector" },
          h("div", { class: "tb-swatches", role: "radiogroup", "aria-label": "颜色" }, this.swatches),
          h("div", { class: "tb-sep" }),
          h("div", { class: "tb-widths", role: "radiogroup", "aria-label": "线宽" }, this.widths),
          button({ "data-action": "style", "aria-label": "自定义颜色与粗细", title: "自定义颜色与粗细" }, icon("sliders")),
          h("div", { class: "tb-spacer" }),
          h("div", { class: "tb-history" }, this.undo, this.redo, this.trash),
        ),
      );
      const spinner = this.el.querySelector(".tb-working svg");
      spinner.replaceWith(icon("spinner", "tb-spinner"));
      this.el.addEventListener("click", (event) => {
        const target = event.target.closest("[data-action]");
        if (target && !target.disabled) onAction(target.dataset.action, target);
      });
      this.el.addEventListener("pointerdown", (event) => event.stopPropagation());
    }

    update(state) {
      const el = this.el;
      el.classList.toggle("is-working", state.working && !state.translated);
      el.classList.toggle("is-untranslated", !state.working && !state.translated);
      const inspector = state.selected != null || (state.tool !== "move" && state.annotating);
      el.classList.toggle("is-plain", !inspector);
      this.segments.forEach((segment) => {
        const on = (segment.dataset.action === "translation") === (state.showing === "translation");
        segment.setAttribute("aria-checked", String(on));
      });
      this.tools.forEach((tool, i) => {
        const id = TOOLS[i][0];
        tool.setAttribute("aria-pressed", String(state.tool === id && (id !== "move" || state.selected != null)));
      });
      this.text.disabled = !state.translated;
      this.text.setAttribute("aria-pressed", String(!!state.textOpen));
      this.text.setAttribute("aria-expanded", String(!!state.textOpen));
      this.copyLabel.textContent = state.copied ? "已复制" : "复制";
      this.copyIcon.querySelector("use").setAttribute("href", state.copied ? "#ui-check" : "#ui-copy");
      this.lang.querySelector("span").textContent = state.direction;
      this.status.textContent = state.readout || state.status || HINT;
      const color = state.selectedMark?.color ?? state.color;
      const width = state.selectedMark?.width ?? state.width;
      this.swatches.forEach((swatch) => swatch.setAttribute("aria-checked", String(swatch.dataset.color === color)));
      this.widths.forEach((button) => button.setAttribute("aria-checked", String(button.dataset.action === `width.${width}`)));
      this.undo.disabled = !state.canUndo;
      this.redo.disabled = !state.canRedo;
      this.trash.disabled = state.selected == null;
    }
  }

  // ---------- one screen: a page at its own size, with the app's overlay, capture and pins on it ----------

  let screenCount = 0;
  class Screen {
    constructor(host, options = {}) {
      this.id = ++screenCount;
      this.host = host;
      this.world = host.querySelector(".screen-world");
      this.options = options;
      this.target = options.target || "en";
      this.source = "ja";
      this.detects = true;
      this.scale = 1;
      this.offset = { x: 0, y: 0 };
      this.pins = [];
      this.capture = null;
      this.selection = null;
      this.listeners = new Set();
      this.marks = [];
      this.history = { past: [], future: [] };
      this.tool = "move";
      this.annotating = false;
      this.color = "red";
      this.width = 4;
      this.selected = null;
      this.showing = "translation";
      this.peeking = false;
      this.buildOverlay();
      this.ghost = new Ghost(this.world);
      host.addEventListener("pointerdown", (event) => this.pointerDown(event));
      host.addEventListener("pointermove", (event) => this.pointerMove(event));
      host.addEventListener("pointerup", (event) => this.pointerUp(event));
      host.addEventListener("pointercancel", (event) => this.pointerUp(event, true));
      host.addEventListener("pointerleave", () => this.capture?.el.classList.remove("is-hover"));
      host.addEventListener("contextmenu", (event) => this.contextMenu(event));
      host.addEventListener("keydown", (event) => this.keyDown(event));
      host.addEventListener("keyup", (event) => {
        if (event.key === " " && this.peeking) this.peek(false);
      });
      host.addEventListener("blur", () => this.peeking && this.peek(false));
    }

    on(listener) {
      this.listeners.add(listener);
    }
    emit(type, detail) {
      for (const listener of this.listeners) listener(type, detail);
    }
    interrupt() {
      this.emit("interrupt");
    }

    // ---- geometry ----
    layout(scale, offset = { x: 0, y: 0 }) {
      this.scale = scale;
      this.offset = offset;
      this.world.style.transform = `translate(${-offset.x * scale}px, ${-offset.y * scale}px) scale(${scale})`;
      this.host.style.setProperty("--scale", scale);
      this.placeToolbar();
    }
    visible() {
      const box = this.host.getBoundingClientRect();
      const clip = this.options.clip?.getBoundingClientRect() || box;
      const left = Math.max(box.left, clip.left), right = Math.min(box.right, clip.right);
      const top = Math.max(box.top, clip.top), bottom = Math.min(box.bottom, clip.bottom);
      const p = (x, y) => ({ x: (x - box.left) / this.scale + this.offset.x, y: (y - box.top) / this.scale + this.offset.y });
      const a = p(left, top), b = p(right, bottom);
      return { x: Math.max(0, a.x), y: Math.max(0, a.y), w: Math.min(PAGE_W, b.x) - Math.max(0, a.x), h: Math.min(PAGE_H + 400, b.y) - Math.max(0, a.y) };
    }
    point(event) {
      const box = this.host.getBoundingClientRect();
      return { x: (event.clientX - box.left) / this.scale + this.offset.x, y: (event.clientY - box.top) / this.scale + this.offset.y };
    }
    clientRect(r) {
      const box = this.host.getBoundingClientRect();
      const x = box.left + (r.x - this.offset.x) * this.scale, y = box.top + (r.y - this.offset.y) * this.scale;
      return { left: x, top: y, right: x + r.w * this.scale, bottom: y + r.h * this.scale, width: r.w * this.scale, height: r.h * this.scale };
    }

    // ---- the selection overlay ----
    buildOverlay() {
      this.sel = h("div", { class: "sel", "aria-hidden": "true" });
      const svg = s("svg", { viewBox: `0 0 ${PAGE_W} ${PAGE_H}`, preserveAspectRatio: "none" });
      this.selDim = s("path", { class: "sel-dim" });
      this.selOuter = s("path", { class: "sel-outer" });
      this.selInner = s("path", { class: "sel-inner" });
      this.selCorners = s("path", { class: "sel-corners" });
      svg.append(this.selDim, this.selOuter, this.selInner, this.selCorners);
      this.chipTitle = h("span", { class: "chip-title" });
      this.chipPrompt = h("span", { class: "chip-prompt" });
      this.chip = h("div", { class: "chip" }, this.chipTitle, this.chipPrompt);
      this.sel.append(svg, this.chip);
      this.world.append(this.sel);
    }
    get title() {
      return `截屏翻译 · ${directionText(this.source, this.target)}`;
    }
    startSelection(user = true) {
      if (this.selection) return;
      closeFloat();
      this.selection = { hover: null, start: null, current: null, dragging: false, mouse: this.selection?.mouse || null };
      this.chipTitle.textContent = this.title + (lastArea ? " · R 上次区域" : "");
      this.host.classList.add("is-selecting");
      if (user) this.host.focus({ preventScroll: true });
      this.drawSelection();
      this.emit("selecting");
    }
    // R while selecting: the last capture's area, shown for a moment, then captured.
    selectLast() {
      const sel = this.selection;
      if (!sel || !lastArea || sel.taking) return false;
      const area = { ...lastArea };
      sel.taking = true;
      sel.start = null;
      sel.dragging = false;
      sel.hover = area;
      sel.mouse = { x: area.x + area.w / 2, y: area.y + area.h / 2 };
      this.drawSelection();
      setTimeout(() => {
        if (this.selection !== sel) return;
        this.selection = null;
        this.host.classList.remove("is-selecting");
        this.openCapture(area);
      }, reduced ? 0 : 220);
      return true;
    }
    cancelSelection() {
      if (!this.selection) return;
      this.selection = null;
      this.host.classList.remove("is-selecting");
      this.emit("cancel");
    }
    selectionRect() {
      const { start, current } = this.selection;
      return { x: Math.min(start.x, current.x), y: Math.min(start.y, current.y), w: Math.abs(current.x - start.x), h: Math.abs(current.y - start.y) };
    }
    hover(p) {
      if (!this.selection || this.selection.start) return;
      this.selection.mouse = p;
      const region = regionAt(p);
      this.selection.hover = region.w > 8 ? region : null;
      this.drawSelection();
    }
    press(p) {
      if (!this.selection) return;
      this.selection.start = p;
      this.selection.current = p;
      this.selection.mouse = p;
      this.selection.dragging = false;
      this.drawSelection();
    }
    dragTo(p) {
      const sel = this.selection;
      if (!sel || !sel.start) return;
      sel.current = { x: clamp(p.x, 0, PAGE_W), y: clamp(p.y, 0, PAGE_H) };
      sel.mouse = sel.current;
      if (Math.hypot(sel.current.x - sel.start.x, sel.current.y - sel.start.y) >= 5) {
        sel.dragging = true;
        sel.hover = null;
      }
      this.drawSelection();
    }
    release(p) {
      const sel = this.selection;
      if (!sel) return;
      if (sel.start) sel.current = { x: clamp(p.x, 0, PAGE_W), y: clamp(p.y, 0, PAGE_H) };
      const dragged = sel.start && sel.dragging ? this.selectionRect() : null;
      const snap = sel.hover;
      this.selection = null;
      this.host.classList.remove("is-selecting");
      let rect = null;
      if (dragged && dragged.w >= 12 && dragged.h >= 12) rect = dragged;
      else if (snap && snap.w >= 12 && snap.h >= 12) rect = snap;
      if (!rect) return this.emit("cancel");
      rect = { x: Math.round(rect.x), y: Math.round(rect.y), w: Math.round(rect.w), h: Math.round(rect.h) };
      this.openCapture(rect);
    }
    drawSelection() {
      const sel = this.selection;
      if (!sel) return;
      const highlight = sel.dragging ? this.selectionRect() : sel.hover;
      let dim = `M0 0H${PAGE_W}V${PAGE_H}H0Z`;
      if (highlight && highlight.w >= 2 && highlight.h >= 2) {
        const r = Math.min(10, Math.min(highlight.w, highlight.h) / 6);
        dim += rectPath(highlight.x, highlight.y, highlight.w, highlight.h, r);
        const o = inset(highlight, 0.5), i = inset(highlight, 1.5);
        this.selOuter.setAttribute("d", rectPath(o.x, o.y, o.w, o.h, r));
        this.selInner.setAttribute("d", rectPath(i.x, i.y, i.w, i.h, Math.max(0, r - 1)));
        this.selCorners.setAttribute("d", sel.dragging && highlight.w > 32 && highlight.h > 32 ? cornerMarks(i, Math.max(0, r - 1), 12) : "");
      } else {
        for (const path of [this.selOuter, this.selInner, this.selCorners]) path.setAttribute("d", "");
      }
      this.selDim.setAttribute("d", dim);
      let prompt = "移动鼠标选择 · 拖动框选";
      if (sel.dragging) prompt = `${Math.round(highlight.w * 2)} × ${Math.round(highlight.h * 2)} px  ·  松开完成`;
      else if (sel.hover) prompt = "点击选中 · 拖动自选";
      this.chipPrompt.textContent = prompt;
      const mouse = sel.mouse || { x: PAGE_W / 2, y: 120 };
      const width = Math.max(this.chipPrompt.offsetWidth, this.chipTitle.offsetWidth) + 24;
      const bounds = this.visible();
      let x = mouse.x + 18;
      if (x + width > bounds.x + bounds.w - 8) x = mouse.x - width - 18;
      let y = mouse.y + 16;
      if (y + 51 > bounds.y + bounds.h - 8) y = mouse.y - 51 - 18;
      x = clamp(x, bounds.x + 8, bounds.x + bounds.w - width - 8);
      y = clamp(y, bounds.y + 8, bounds.y + bounds.h - 51 - 8);
      this.chip.style.width = `${width}px`;
      this.chip.style.transform = `translate(${x}px, ${y}px)`;
    }

    // ---- the capture ----
    openCapture(rect, { translate = true, instant = false } = {}) {
      this.closeCapture({ instant: true });
      this.showing = "translation";
      this.peeking = false;
      this.copied = false;
      this.selected = null;
      this.tool = "move";
      this.annotating = false;
      this.capture = new Capture(this, rect);
      rememberArea(rect);
      this.toolbar = new Toolbar((action, el) => this.action(action, el));
      this.toolbar.el.classList.add("is-hidden");
      this.world.insertBefore(this.toolbar.el, this.sel);
      this.placeToolbar();
      this.refresh();
      if (instant || reduced) this.toolbar.el.classList.remove("is-hidden");
      else requestAnimationFrame(() => requestAnimationFrame(() => this.toolbar?.el.classList.remove("is-hidden")));
      this.emit("capture", rect);
      if (translate) this.translate({ instant });
      return this.capture;
    }
    closeCapture({ instant = false } = {}) {
      clearTimeout(this.work);
      closeFloat();
      const capture = this.capture, toolbar = this.toolbar;
      this.capture = null;
      this.toolbar = null;
      this.textOpen = false;
      if (!capture) return;
      if (instant || reduced) {
        capture.el.remove();
        toolbar?.el.remove();
      } else {
        capture.el.style.transition = "opacity 0.16s ease-out";
        capture.el.style.opacity = "0";
        if (toolbar) toolbar.el.classList.add("is-hidden");
        setTimeout(() => {
          capture.el.remove();
          toolbar?.el.remove();
        }, 180);
      }
      this.emit("close");
    }
    placeToolbar() {
      if (!this.toolbar || !this.capture) return;
      const r = this.capture.rect;
      const v = this.visible();
      const width = 536, height = this.toolbar.el.offsetHeight || 77;
      const k = this.options.toolbarScale?.(this.scale) ?? 1;
      const x = clamp(r.x + r.w / 2 - (width * k) / 2, v.x + 8, Math.max(v.x + 8, v.x + v.w - width * k - 8));
      let y = r.y + r.h + 20;
      if (y + height * k > v.y + v.h - 4 && r.y - 20 - height * k >= v.y + 4) y = r.y - 20 - height * k;
      this.toolbar.el.style.transform = `translate(${x}px, ${y}px) scale(${k})`;
      this.toolbar.el.style.transformOrigin = "0 0";
    }
    get state() {
      const selectedMark = this.selected != null ? this.marks[this.selected] : null;
      return {
        working: this.working,
        translated: this.translated,
        showing: this.peeking ? "original" : this.showing,
        tool: this.tool,
        annotating: this.annotating,
        selected: this.selected,
        selectedMark,
        color: this.color,
        width: this.width,
        copied: this.copied,
        direction: directionText(this.source, this.target),
        status: this.status,
        readout: this.readout,
        canUndo: this.history.past.length > 0,
        canRedo: this.history.future.length > 0,
        textOpen: this.textOpen,
      };
    }
    refresh() {
      if (!this.capture) return;
      this.toolbar?.update(this.state);
      this.capture.show(this.translated && !this.peeking && this.showing === "translation" ? this.target : "ja");
      this.capture.drawMarks(this.marks, this.selected);
      this.placeToolbar();
      this.emit("refresh");
    }
    translate({ instant = false } = {}) {
      if (!this.capture) return;
      clearTimeout(this.work);
      this.working = true;
      this.translated = false;
      this.capture.el.classList.add("is-working");
      const target = this.target;
      const steps = [
        [0, "正在识别与翻译…"],
        [180, "正在识别文字…"],
        [720, "正在翻译…"],
      ];
      const finish = () => {
        if (!this.capture) return;
        this.working = false;
        this.translated = true;
        this.capture.el.classList.remove("is-working");
        this.capture.setLanguage(target);
        const count = target === this.source ? 0 : blocksIn(this.capture.rect, target).filter((block) => block.translation).length;
        this.status = doneStatus(count);
        this.refresh();
        this.emit("translated", target);
      };
      if (instant || reduced) return finish();
      warm(target);
      let index = 0;
      const next = () => {
        if (!this.capture) return;
        if (index < steps.length) {
          this.status = steps[index][1];
          this.refresh();
          index += 1;
          this.work = setTimeout(next, index < steps.length ? steps[index][0] - steps[index - 1][0] : 680);
        } else warm(target).then(() => this.capture && (this.work = setTimeout(finish, 0)));
      };
      next();
    }
    setTarget(lang) {
      if (lang === this.target && this.translated) return;
      this.target = lang;
      if (this.source === lang) this.source = lang === "ja" ? "en" : "ja";
      this.showing = "translation";
      this.translate();
    }
    swap() {
      this.detects = false;
      [this.source, this.target] = [this.target, this.source];
      this.showing = "translation";
      this.translate();
      this.emit("swap");
    }
    peek(on) {
      if (!this.capture || !this.translated) return;
      this.peeking = on;
      this.refresh();
    }
    toggle() {
      if (!this.capture) return;
      this.showing = this.showing === "translation" ? "original" : "translation";
      if (this.showing === "translation" && !this.translated && !this.working) this.translate();
      this.refresh();
      this.emit("toggle", this.showing);
    }

    // ---- marks ----
    remember() {
      this.history.past.push(this.marks.map((mark) => ({ ...mark, points: mark.points.map((p) => [...p]) })));
      this.history.future = [];
    }
    restore(stack, other) {
      if (!stack.length) return;
      other.push(this.marks);
      this.marks = stack.pop();
      this.selected = null;
      this.refresh();
    }
    setMarks(marks) {
      this.marks = marks;
      this.history = { past: [], future: [] };
      this.selected = null;
      this.refresh();
    }
    chooseTool(tool) {
      this.tool = tool;
      this.annotating = tool !== "move";
      this.selected = null;
      this.capture?.el.classList.toggle("is-drawing", this.annotating);
      this.refresh();
      this.emit("tool", tool);
    }
    setColor(color) {
      this.color = color;
      if (this.selected != null) {
        this.remember();
        this.marks[this.selected].color = color;
      }
      this.refresh();
    }
    setWidth(width) {
      this.width = width;
      if (this.selected != null) {
        this.remember();
        this.marks[this.selected].width = width;
      }
      this.refresh();
    }
    nextNumber() {
      return this.marks.filter((mark) => mark.tool === "number").reduce((max, mark) => Math.max(max, mark.number), 0) + 1;
    }

    // ---- pointer ----
    pointerDown(event) {
      if (event.button !== 0 && event.pointerType === "mouse") return;
      if (event.target.closest(".tb, .pin")) return;
      this.interrupt();
      const p = this.point(event);
      if (this.selection) {
        event.preventDefault();
        this.host.setPointerCapture?.(event.pointerId);
        this.press(p);
        this.drag = { kind: "select", id: event.pointerId };
        return;
      }
      const capture = this.capture;
      if (!capture) return;
      const edges = capture.edgesAt(p);
      if (edges) {
        event.preventDefault();
        this.host.setPointerCapture?.(event.pointerId);
        this.drag = { kind: "resize", id: event.pointerId, edges, start: p, rect: { ...capture.rect } };
        this.beginResize();
        return;
      }
      if (!contains(capture.rect, p)) return;
      event.preventDefault();
      this.host.focus({ preventScroll: true });
      this.host.setPointerCapture?.(event.pointerId);
      const local = { x: p.x - capture.rect.x, y: p.y - capture.rect.y };
      const hit = this.marks.map((mark, index) => [mark, index]).reverse().find(([mark]) => hitMark(mark, local));
      if (this.annotating && this.tool !== "move" && !hit) {
        if (this.tool === "number") {
          this.remember();
          this.marks.push({ tool: "number", points: [[local.x, local.y]], color: this.color, width: this.width, number: this.nextNumber() });
          this.refresh();
          this.drag = null;
          return;
        }
        this.remember();
        this.marks.push({ tool: this.tool, points: [[local.x, local.y], [local.x, local.y]], color: this.color, width: this.width });
        this.drag = { kind: "draw", id: event.pointerId, index: this.marks.length - 1 };
        this.refresh();
        return;
      }
      if (hit) {
        this.tool = "move";
        this.annotating = false;
        this.selected = hit[1];
        this.remember();
        this.drag = { kind: "move", id: event.pointerId, last: local, moved: false };
        this.refresh();
        return;
      }
      if (this.selected != null) {
        this.selected = null;
        this.refresh();
      }
    }
    pointerMove(event) {
      const p = this.point(event);
      if (this.selection && !this.drag) return this.hover(p);
      const capture = this.capture;
      if (!this.drag) {
        if (!capture) return;
        const near = contains(inset(capture.rect, -8), p);
        capture.el.classList.toggle("is-hover", near);
        const edges = capture.edgesAt(p);
        this.host.style.cursor = edges ? EDGE_CURSORS[edges] : this.annotating && contains(capture.rect, p) ? "crosshair" : "";
        return;
      }
      if (event.pointerId !== this.drag.id) return;
      if (this.drag.kind === "select") return this.dragTo(p);
      const local = capture ? { x: clamp(p.x - capture.rect.x, 0, capture.rect.w), y: clamp(p.y - capture.rect.y, 0, capture.rect.h) } : p;
      if (this.drag.kind === "draw") {
        const mark = this.marks[this.drag.index];
        if (mark.tool === "pen") mark.points.push([local.x, local.y]);
        else mark.points[1] = [local.x, local.y];
        capture.drawMarks(this.marks, this.selected);
      } else if (this.drag.kind === "move") {
        const dx = local.x - this.drag.last.x, dy = local.y - this.drag.last.y;
        this.drag.last = local;
        this.drag.moved = true;
        const mark = this.marks[this.selected];
        mark.points = mark.points.map(([x, y]) => [x + dx, y + dy]);
        capture.drawMarks(this.marks, this.selected);
      } else if (this.drag.kind === "resize") this.resizeTo(p);
    }
    pointerUp(event, cancelled = false) {
      const p = this.point(event);
      const drag = this.drag;
      this.drag = null;
      if (this.selection) return cancelled ? this.cancelSelection() : this.release(p);
      if (!drag || event.pointerId !== drag.id) return;
      if (drag.kind === "draw") {
        const mark = this.marks[drag.index];
        const b = markBounds(mark);
        if (mark.tool !== "pen" && Math.hypot(b.w, b.h) < 4) {
          this.marks.pop();
          this.history.past.pop();
        } else this.emit("mark", mark);
        this.refresh();
      } else if (drag.kind === "move" && !drag.moved) this.history.past.pop();
      else if (drag.kind === "resize") this.endResize();
    }
    contextMenu(event) {
      if (this.selection) {
        event.preventDefault();
        this.cancelSelection();
      }
    }
    keyDown(event) {
      const meta = event.metaKey || event.ctrlKey;
      if (event.key === "Escape") {
        if (this.selection) this.cancelSelection();
        else if (this.capture) this.closeCapture();
        else return;
        event.preventDefault();
        return;
      }
      const key = event.key.toLowerCase();
      if (this.selection) {
        if (key === "r" && !meta && !event.altKey && this.selectLast()) {
          event.preventDefault();
          this.interrupt();
        }
        return;
      }
      if (!this.capture) return;
      if (event.key === " ") {
        event.preventDefault();
        if (!event.repeat) this.peek(true);
      } else if (meta && key === "z") {
        event.preventDefault();
        this.action(event.shiftKey ? "redo" : "undo");
      } else if (meta && key === "c") {
        event.preventDefault();
        this.action("copy");
      } else if (!meta && !event.altKey && { r: 1, o: 1, a: 1, p: 1, v: 1 }[key]) {
        this.chooseTool({ r: "rectangle", o: "ellipse", a: "arrow", p: "pen", v: "move" }[key]);
      } else if (!meta && key === "d") this.swap();
      else if (!meta && key === "t") this.translate();
      else if ((event.key === "Backspace" || event.key === "Delete") && this.selected != null) {
        event.preventDefault();
        this.action("delete");
      } else return;
      this.interrupt();
    }

    // ---- resizing, as the app does it since the smooth crop drag ----
    beginResize() {
      clearTimeout(this.work);
      this.capture.el.classList.add("is-resizing");
      this.capture.el.classList.remove("is-working");
      this.working = false;
      this.resized = false;
    }
    resizeTo(p) {
      const { edges, start, rect } = this.drag;
      const dx = p.x - start.x, dy = p.y - start.y;
      let { x, y, w, h: hgt } = rect;
      if (edges.includes("l")) ((x = clamp(rect.x + dx, 0, rect.x + rect.w - 24)), (w = rect.x + rect.w - x));
      if (edges.includes("r")) w = clamp(rect.w + dx, 24, PAGE_W - rect.x);
      if (edges.includes("t")) ((y = clamp(rect.y + dy, 0, rect.y + rect.h - 24)), (hgt = rect.y + rect.h - y));
      if (edges.includes("b")) hgt = clamp(rect.h + dy, 24, PAGE_H - rect.y);
      const next = { x: Math.round(x), y: Math.round(y), w: Math.round(w), h: Math.round(hgt) };
      if (next.x !== this.capture.rect.x || next.y !== this.capture.rect.y || next.w !== this.capture.rect.w || next.h !== this.capture.rect.h) {
        if (!this.resized) {
          this.resized = true;
          this.translated = false;
          this.textOpen = false;
          closeFloat();
        }
        this.capture.setRect(next);
      }
      this.readout = `${next.w * 2} × ${next.h * 2} px`;
      this.refresh();
    }
    endResize() {
      this.readout = null;
      this.capture?.el.classList.remove("is-resizing");
      if (!this.resized) return this.refresh();
      rememberArea(this.capture.rect);
      this.emit("resize", this.capture.rect);
      if (this.showing === "translation") this.translate();
      else {
        this.status = "";
        this.refresh();
      }
    }
    resizeBy(edges, from, to, ms, script) {
      // For demonstrations: the same path a drag takes.
      this.drag = { kind: "resize", id: -1, edges, start: from, rect: { ...this.capture.rect } };
      this.beginResize();
      return script
        .tween(ms, (t) => {
          const p = { x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t };
          this.ghost.at(p);
          if (this.drag) this.resizeTo(p);
        })
        .finally(() => {
          if (this.drag?.id === -1) {
            this.drag = null;
            this.endResize();
          }
        });
    }

    // ---- toolbar actions ----
    action(id, el) {
      this.interrupt();
      this.perform(id, el);
    }
    // The same actions for a demonstration, which must not cancel itself.
    perform(id, el) {
      if (id === "original" || id === "translation") {
        this.showing = id;
        if (id === "translation" && !this.translated && !this.working) this.translate();
        this.refresh();
        this.emit("toggle", id);
      } else if (id.startsWith("tool.")) this.chooseTool(this.tool === id.slice(5) ? "move" : id.slice(5));
      else if (id.startsWith("color.")) this.setColor(id.slice(6));
      else if (id.startsWith("width.")) this.setWidth(Number(id.slice(6)));
      else if (id === "undo") this.restore(this.history.past, this.history.future);
      else if (id === "redo") this.restore(this.history.future, this.history.past);
      else if (id === "delete" && this.selected != null) {
        this.remember();
        this.marks.splice(this.selected, 1);
        this.selected = null;
        this.refresh();
      } else if (id === "copy") this.copy();
      else if (id === "close") this.closeCapture();
      else if (id === "pin") this.pin();
      else if (id === "translate") this.translate();
      else if (id === "lang") this.languageMenu(el);
      else if (id === "more") this.moreMenu(el);
      else if (id === "text") this.transcript(el);
      else if (id === "style") this.chooseTool(this.tool);
    }
    languageMenu(anchor) {
      const items = [{ head: "原文语言" }, { label: "自动识别", icon: this.detects ? null : "globe", check: this.detects || null, action: () => ((this.detects = true), (this.source = "ja"), this.translate()) }];
      for (const lang of ORDER) items.push({ label: languages[lang].name, check: !this.detects && this.source === lang, action: () => ((this.detects = false), (this.source = lang), this.translate()) });
      items.push({ head: "译文语言" });
      for (const lang of ORDER) items.push({ label: languages[lang].name, check: this.target === lang, action: () => this.setTarget(lang) });
      items.push({ rule: true }, { label: "交换语言", action: () => this.swap() });
      openMenu(items, anchor, this.menuScale(), { focus: false });
    }
    moreMenu(anchor) {
      openMenu(
        [
          { label: "保存图片…", icon: "save", action: () => this.copy(true) },
          { label: "重新框选", icon: "viewfinder", action: () => (this.closeCapture({ instant: true }), this.startSelection()) },
          { rule: true },
          { label: "撤销", icon: "undo", disabled: !this.history.past.length, action: () => this.action("undo") },
          { label: "重做", icon: "redo", disabled: !this.history.future.length, action: () => this.action("redo") },
          { label: "删除选中标注", icon: "trash", disabled: this.selected == null, action: () => this.action("delete") },
          { rule: true },
          { label: `交换语言 · ${directionText(this.source, this.target)}`, icon: "swap", action: () => this.swap() },
          { label: "重新翻译", icon: "retry", disabled: this.working, action: () => this.translate() },
        ],
        anchor,
        this.menuScale(),
      );
    }
    menuScale() {
      return clamp(this.scale * (this.options.toolbarScale?.(this.scale) ?? 1), 0.75, 1.15);
    }
    transcript(anchor) {
      if (this.textOpen) return closeFloat();
      closeFloat();
      const blocks = blocksIn(this.capture.rect, this.target);
      const body = h("div", { class: "pop-body" }, blocks.map((block) => h("div", { class: "pop-block" }, block.translation && block.translation !== block.original ? h("p", { class: "pop-original", text: block.original, lang: "ja" }) : null, h("p", { text: block.translation || block.original, lang: block.translation ? this.target : "ja" }))));
      const check = h("input", { type: "checkbox" });
      const copyLabel = h("span", { text: "复制文字" });
      const copyIcon = icon("copy");
      const pop = h(
        "div",
        { class: "pop", role: "dialog", "aria-label": "完整译文" },
        h("div", { class: "pop-head" }, h("div", { class: "pop-title" }, h("strong", { text: this.translated ? "完整译文" : "识别文字" }), h("span", { text: directionText(this.source, this.target) })), h("label", { class: "pop-check" }, check, "对照原文")),
        h("div", { class: "pop-rule" }),
        body,
        h("div", { class: "pop-rule" }),
        h("div", { class: "pop-foot" }, h("span", { text: "文字可选择、复制" }), h("button", { type: "button", class: "pop-copy", onclick: () => {
          const text = blocks.map((block) => block.translation || block.original).join("\n\n");
          navigator.clipboard?.writeText(text).catch(() => {});
          copyLabel.textContent = "已复制";
          copyIcon.querySelector("use").setAttribute("href", "#ui-check");
        } }, copyIcon, copyLabel)),
      );
      check.addEventListener("change", () => pop.classList.toggle("is-comparing", check.checked));
      floatLayer.append(pop);
      const box = anchor.getBoundingClientRect();
      const placed = placeFloat(pop, box, this.menuScale(), { below: true, align: "center", gap: 10 });
      pop.style.setProperty("--arrow", `${clamp((box.left + box.width / 2 - placed.x) / this.menuScale(), 24, 396)}px`);
      this.textOpen = true;
      this.refresh();
      openFloat = { el: pop, anchor, sticky: true, onClose: () => ((this.textOpen = false), this.refresh()) };
      requestAnimationFrame(() => pop.classList.add("is-open"));
      this.emit("text");
    }
    copy(save = false) {
      if (!this.capture) return;
      const picture = this.snapshot();
      this.copied = true;
      this.refresh();
      this.emit(save ? "save" : "copy", picture);
      setTimeout(() => this.capture && this.closeCapture(), reduced ? 0 : 220);
    }
    snapshot() {
      const capture = this.capture;
      return { rect: { ...capture.rect }, lang: capture.shownLanguage, marks: this.marks.map((mark) => ({ ...mark, points: mark.points.map((p) => [...p]) })) };
    }

    // ---- pins ----
    pin() {
      if (!this.capture) return;
      const picture = this.snapshot();
      const other = picture.lang === "ja" ? (this.translated ? this.target : null) : "ja";
      const pin = new Pin(this, picture, other);
      this.pins.push(pin);
      this.closeCapture({ instant: true });
      this.emit("pin", pin);
      return pin;
    }
  }

  const EDGE_CURSORS = { l: "ew-resize", r: "ew-resize", t: "ns-resize", b: "ns-resize", lt: "nwse-resize", rb: "nwse-resize", rt: "nesw-resize", lb: "nesw-resize" };

  // Accent brackets that run along the rounded outline through each corner's arc.
  const cornerMarks = (r, radius, length) => {
    const rad = Math.min(radius, r.w / 2, r.h / 2);
    const arm = Math.max(0, Math.min(length, r.w / 2 - rad - 2, r.h / 2 - rad - 2));
    const x0 = r.x, y0 = r.y, x1 = r.x + r.w, y1 = r.y + r.h;
    const arc = (x, y) => (rad > 0.5 ? `A${rad} ${rad} 0 0 1 ${x} ${y}` : `L${x} ${y}`);
    return [
      `M${x0} ${y0 + rad + arm}L${x0} ${y0 + rad}${arc(x0 + rad, y0)}L${x0 + rad + arm} ${y0}`,
      `M${x1 - rad - arm} ${y0}L${x1 - rad} ${y0}${arc(x1, y0 + rad)}L${x1} ${y0 + rad + arm}`,
      `M${x1} ${y1 - rad - arm}L${x1} ${y1 - rad}${arc(x1 - rad, y1)}L${x1 - rad - arm} ${y1}`,
      `M${x0 + rad + arm} ${y1}L${x0 + rad} ${y1}${arc(x0, y1 - rad)}L${x0} ${y1 - rad - arm}`,
    ].join("");
  };

  // ---------- a capture on a screen ----------

  let gradientCount = 0;
  class Capture {
    constructor(screen, rect) {
      this.screen = screen;
      this.rect = { ...rect };
      this.layers = {};
      this.shownLanguage = "ja";
      this.pic = h("div", { class: "cap-pic" });
      const id = `sweep-${++gradientCount}`;
      this.chrome = s("svg", { class: "cap-chrome", "aria-hidden": "true" });
      const defs = s("defs");
      const gradient = s("linearGradient", { id, x1: "0", y1: "0", x2: "1", y2: "0" });
      [["0", "#338cff"], ["0.25", "#40f2eb"], ["0.5", "#b861ff"], ["0.75", "#ff6bb8"], ["1", "#338cff"]].forEach(([offset, color]) => gradient.append(s("stop", { offset, "stop-color": color })));
      if (!reduced) {
        gradient.append(s("animateTransform", { attributeName: "gradientTransform", type: "translate", values: "-0.8 0;-0.2 0;0.2 0", keyTimes: "0;0.5;1", calcMode: "spline", keySplines: "0.42 0 0.58 1;0.42 0 0.58 1", dur: "1.35s", repeatCount: "indefinite" }));
      }
      defs.append(gradient);
      this.outer = s("path", { class: "cap-idle-outer" });
      this.inner = s("path", { class: "cap-idle-inner" });
      this.sweep = s("path", { class: "cap-sweep", stroke: `url(#${id})` });
      this.handles = s("g");
      this.chrome.append(defs, this.sweep, this.outer, this.inner, this.handles);
      this.marks = s("svg", { class: "cap-marks", "aria-hidden": "true" });
      this.el = h("div", { class: "cap", role: "img", "aria-label": "截图" }, this.pic, this.marks, this.chrome);
      screen.world.insertBefore(this.el, screen.sel);
      this.layer("ja");
      this.setRect(rect);
    }
    layer(lang) {
      if (this.layers[lang]) return this.layers[lang];
      const img = h("img", { src: pageFor(lang), width: PAGE_W, height: PAGE_H, alt: "", draggable: "false", decoding: "async" });
      const el = h("div", { class: "cap-layer is-hidden" }, img);
      this.pic.append(el);
      this.layers[lang] = el;
      this.position(el);
      return el;
    }
    position(layer) {
      const img = layer.firstChild;
      img.style.left = `${-this.rect.x}px`;
      img.style.top = `${-this.rect.y}px`;
      img.style.width = `${PAGE_W}px`;
      img.style.height = `${PAGE_H}px`;
    }
    setRect(rect) {
      this.rect = { ...rect };
      const { x, y, w, h: hgt } = rect;
      this.el.style.transform = `translate(${x}px, ${y}px)`;
      this.el.style.width = `${w}px`;
      this.el.style.height = `${hgt}px`;
      Object.values(this.layers).forEach((layer) => this.position(layer));
      this.chrome.setAttribute("viewBox", `0 0 ${w} ${hgt}`);
      this.marks.setAttribute("viewBox", `0 0 ${w} ${hgt}`);
      const b = inset({ x: 0, y: 0, w, h: hgt }, 1.2);
      const border = rectPath(b.x, b.y, b.w, b.h, 10);
      this.outer.setAttribute("d", border);
      this.inner.setAttribute("d", border);
      this.sweep.setAttribute("d", border);
      const r = Math.min(10, b.w / 2, b.h / 2), k = r * (1 - 1 / Math.SQRT2);
      const points = [[b.x + k, b.y + k], [b.x + b.w - k, b.y + k], [b.x + b.w - k, b.y + b.h - k], [b.x + k, b.y + b.h - k]];
      if (b.w >= 64) points.push([b.x + b.w / 2, b.y], [b.x + b.w / 2, b.y + b.h]);
      if (b.h >= 64) points.push([b.x, b.y + b.h / 2], [b.x + b.w, b.y + b.h / 2]);
      this.handles.replaceChildren(...points.map(([cx, cy]) => s("circle", { class: "cap-handle", cx, cy, r: 4 })));
    }
    // Which edges a point grabs: 4 points inside the picture to 8 outside, corners 16 along.
    edgesAt(p) {
      const r = this.rect;
      if (!contains(inset(r, -8), p) || contains(inset(r, 4), p)) return null;
      const nearL = p.x <= r.x + 4, nearR = p.x >= r.x + r.w - 4, nearT = p.y <= r.y + 4, nearB = p.y >= r.y + r.h - 4;
      let edges = "";
      if (nearL || ((nearT || nearB) && p.x <= r.x + 16 && p.x < r.x + r.w / 2)) edges += "l";
      else if (nearR || ((nearT || nearB) && p.x >= r.x + r.w - 16)) edges += "r";
      if (nearT || ((nearL || nearR) && p.y <= r.y + 16 && p.y < r.y + r.h / 2)) edges += "t";
      else if (nearB || ((nearL || nearR) && p.y >= r.y + r.h - 16)) edges += "b";
      return edges || null;
    }
    show(lang) {
      const wanted = this.layer(lang);
      this.shownLanguage = lang;
      for (const [key, layer] of Object.entries(this.layers)) layer.classList.toggle("is-hidden", key !== lang && key !== "ja");
      // The original stays underneath, so a crossfade never shows the page through it.
      this.layers.ja.classList.remove("is-hidden");
      wanted.classList.remove("is-hidden");
    }
    setLanguage(lang) {
      this.layer(lang);
    }
    drawMarks(marks, selected) {
      this.marks.replaceChildren(...marks.map(drawMark));
      if (selected != null && marks[selected]) {
        const mark = marks[selected];
        if (mark.tool === "arrow") {
          for (const p of [mark.points[0], mark.points[mark.points.length - 1]]) this.marks.append(s("circle", { class: "mark-grip", cx: p[0], cy: p[1], r: 3 }));
        } else {
          const b = inset(markBounds(mark), -4);
          this.marks.append(s("rect", { class: "mark-select", x: b.x, y: b.y, width: b.w, height: b.h }));
          if (mark.tool !== "number") for (const [cx, cy] of [[b.x, b.y], [b.x + b.w, b.y], [b.x + b.w, b.y + b.h], [b.x, b.y + b.h]]) this.marks.append(s("circle", { class: "mark-grip", cx, cy, r: 3 }));
        }
      }
    }
  }

  // ---------- a pinned picture: it floats, moves with the mouse and has its own menu ----------

  class Pin {
    constructor(screen, picture, other) {
      this.screen = screen;
      this.picture = picture;
      this.other = other;
      this.lang = picture.lang;
      const { x, y, w, h: hgt } = picture.rect;
      this.pos = { x, y };
      this.img = h("img", { src: pageFor(this.lang), width: PAGE_W, height: PAGE_H, alt: "", draggable: "false", style: `position:absolute;left:${-x}px;top:${-y}px;width:${PAGE_W}px;height:${PAGE_H}px;max-width:none` });
      const marks = s("svg", { class: "cap-marks", viewBox: `0 0 ${w} ${hgt}`, "aria-hidden": "true" });
      marks.append(...picture.marks.map(drawMark));
      this.el = h("div", { class: "pin", tabindex: "0", role: "img", "aria-label": "钉住的截图", style: `width:${w}px;height:${hgt}px` }, this.img, marks);
      screen.world.insertBefore(this.el, screen.sel);
      this.move(0, 0);
      this.el.addEventListener("pointerdown", (event) => this.down(event));
      this.el.addEventListener("contextmenu", (event) => {
        event.preventDefault();
        this.menu({ x: event.clientX, y: event.clientY });
      });
      this.el.addEventListener("keydown", (event) => {
        if (event.key === "Escape") {
          event.stopPropagation();
          this.close();
        } else if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "c") {
          event.preventDefault();
          screen.emit("copy", { ...this.picture, lang: this.lang });
        }
      });
      if (!reduced) {
        this.el.animate([{ transform: `translate(${x}px, ${y}px) scale(1)`, boxShadow: "0 0 0 0 rgba(0,0,0,0)" }, { transform: `translate(${x}px, ${y - 6}px) scale(1.012)` }, { transform: `translate(${x}px, ${y}px) scale(1)` }], { duration: 420, easing: "cubic-bezier(0.22, 1, 0.36, 1)" });
      }
      this.el.focus({ preventScroll: true });
    }
    move(dx, dy) {
      this.pos.x += dx;
      this.pos.y += dy;
      this.el.style.transform = `translate(${this.pos.x}px, ${this.pos.y}px)`;
    }
    down(event) {
      if (event.button === 2) return;
      event.stopPropagation();
      event.preventDefault();
      this.screen.interrupt();
      this.el.focus({ preventScroll: true });
      this.el.parentNode.insertBefore(this.el, this.screen.sel);
      const start = this.screen.point(event);
      let last = start;
      const move = (e) => {
        const p = this.screen.point(e);
        this.move(p.x - last.x, p.y - last.y);
        last = p;
      };
      const up = () => {
        removeEventListener("pointermove", move);
        removeEventListener("pointerup", up);
        this.screen.emit("pinmove", this);
      };
      addEventListener("pointermove", move);
      addEventListener("pointerup", up);
    }
    menu(point) {
      const items = [
        { label: "复制图片", kbd: "⌘C", action: () => this.screen.emit("copy", { ...this.picture, lang: this.lang }) },
        { label: "保存图片…", kbd: "⌘S", action: () => this.screen.emit("save", { ...this.picture, lang: this.lang }) },
      ];
      if (this.other) items.push({ label: this.lang === "ja" ? "显示译文" : "显示原文", action: () => this.swapLayer() });
      items.push({ rule: true }, { label: "关闭", kbd: "⎋", action: () => this.close() });
      openMenu(items, this.el, this.screen.menuScale(), { point });
    }
    swapLayer() {
      [this.lang, this.other] = [this.other, this.lang];
      this.img.src = pageFor(this.lang);
    }
    close() {
      this.screen.pins = this.screen.pins.filter((pin) => pin !== this);
      if (reduced) this.el.remove();
      else this.el.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 140 }).finished.then(() => this.el.remove());
      this.screen.emit("unpin", this);
    }
  }

  // ---------- the demonstration pointer ----------

  class Ghost {
    constructor(world) {
      this.el = h("div", { class: "ghost", "aria-hidden": "true" });
      for (const [name, cls] of [["cur-arrow", "ghost-arrow"], ["cur-cross", "ghost-cross"], ["cur-resize", "ghost-resize"]]) {
        const svg = s("svg", { class: cls, viewBox: "0 0 24 24" });
        svg.append(s("use", { href: `#${name}` }));
        this.el.append(svg);
      }
      world.append(this.el);
      this.p = { x: 0, y: 0 };
    }
    at(p) {
      this.p = { ...p };
      this.el.style.transform = `translate(${p.x}px, ${p.y}px)`;
    }
    show(on = true, kind = "arrow") {
      this.el.classList.toggle("is-on", on);
      this.el.classList.toggle("is-cross", kind === "cross");
      this.el.classList.toggle("is-resize", kind === "resize");
    }
    down(on) {
      this.el.classList.toggle("is-down", on);
    }
    glide(script, to, ms = 700, curve = curves.inOut) {
      const from = { ...this.p };
      return script.tween(ms, (t) => this.at({ x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t }), curve);
    }
  }

  // ---------- keycaps that press like the keys they name ----------

  const pressKeys = (group, script) => {
    const keys = [...group.querySelectorAll("kbd")];
    if (reduced || !script) {
      group.classList.add("is-pressed");
      setTimeout(() => group.classList.remove("is-pressed"), 160);
      return Promise.resolve();
    }
    return (async () => {
      for (const key of keys) {
        key.classList.add("is-down");
        await script.wait(90);
      }
      await script.wait(140);
      keys.forEach((key) => key.classList.remove("is-down"));
    })();
  };

  // The real F1 starts a selection on the screen in view, or swaps languages if a result is open.
  const shortcutTargets = new Set();
  addEventListener("keydown", (event) => {
    if (event.key !== "F1" || event.metaKey || event.ctrlKey || event.altKey || event.repeat) return;
    const visible = [...shortcutTargets].find((target) => {
      const box = target.screen.host.getBoundingClientRect();
      return box.bottom > 80 && box.top < innerHeight - 80;
    });
    if (!visible) return;
    event.preventDefault();
    visible.press();
  });

  // ---------- the hero: F1, a selection, a capture translated in place ----------

  const page = { zh: doc.lang.startsWith("zh") };
  const inView = (el, margin = 0) => {
    const box = el.getBoundingClientRect();
    return box.bottom > margin && box.top < innerHeight - margin;
  };
  const whenSeen = (el, run, threshold = 0.35) => {
    if (!("IntersectionObserver" in window)) return run();
    const observer = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) {
        observer.disconnect();
        run();
      }
    }, { threshold });
    observer.observe(el);
  };

  // Moves the pointer and lets the screen react on every frame, as a real mouse would.
  const travel = (screen, script, to, ms, mode = "hover") => {
    const from = { ...screen.ghost.p };
    return script.tween(ms, (t) => {
      const p = { x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t };
      screen.ghost.at(p);
      if (mode === "hover") screen.hover(p);
      else if (mode === "drag") screen.dragTo(p);
    });
  };
  const clickAt = async (screen, script, el) => {
    const box = el.getBoundingClientRect();
    const host = screen.host.getBoundingClientRect();
    const to = { x: (box.left + box.width / 2 - host.left) / screen.scale + screen.offset.x, y: (box.top + box.height / 2 - host.top) / screen.scale + screen.offset.y };
    await screen.ghost.glide(script, to, 650);
    screen.ghost.down(true);
    await script.wait(110);
    screen.ghost.down(false);
  };

  const heroHost = document.querySelector('[data-screen="hero"]');
  if (heroHost) {
    const stage = heroHost.closest(".stage");
    const keys = stage.querySelector("[data-shortcut]");
    const narrow = matchMedia("(max-width: 599px)");
    // The page at its own size where it fits; on a narrow stage it keeps the capture's side in view.
    // The toolbar shrinks only when it would not fit across the stage.
    const screen = new Screen(heroHost, {
      target: heroHost.dataset.target || "en",
      clip: stage,
      toolbarScale: (scale) => Math.min(1, (heroHost.getBoundingClientRect().width - 16) / (536 * scale)),
    });
    const layout = () => {
      const box = heroHost.getBoundingClientRect();
      const width = box.width;
      // On a short screen the page shrinks a little, so the capture and its toolbar fit the first view.
      const room = (innerHeight - (box.top + scrollY) - 12) / 492;
      const scale = narrow.matches ? clamp(width / 420, 0.6, 1) : clamp(Math.min(width / 420, room, 1), 0.8, 1);
      const x = clamp(PAGE_W - width / scale, 0, PAGE_W);
      const y = narrow.matches ? 40 : 0;
      heroHost.style.height = `${Math.round((512 - y) * scale)}px`;
      heroHost.style.width = x === 0 ? `${Math.round(PAGE_W * scale)}px` : "";
      screen.layout(scale, { x, y });
    };
    layout();
    addEventListener("resize", layout);
    narrow.addEventListener("change", layout);

    let script = null;
    const stop = () => {
      if (!script) return;
      script.stop();
      script = null;
      screen.ghost.show(false);
      screen.ghost.down(false);
    };
    screen.on((type) => {
      if (type === "interrupt") stop();
      keys.classList.toggle("is-inviting", (type === "close" || type === "cancel" || type === "pin") && !screen.capture);
      if (type === "selecting" || type === "capture") keys.classList.remove("is-inviting");
    });
    const press = () => {
      stop();
      pressKeys(keys);
      if (screen.capture) screen.swap();
      else if (screen.selection) screen.cancelSelection();
      else screen.startSelection();
    };
    keys.addEventListener("click", press);
    shortcutTargets.add({ screen, press });

    const intro = async () => {
      if (reduced) {
        screen.openCapture(DEFAULT_CAPTURE, { instant: true });
        return;
      }
      script = new Script();
      const run = script;
      const ghost = screen.ghost;
      try {
        ghost.at({ x: 690, y: 470 });
        ghost.show(true);
        await run.wait(650);
        await pressKeys(keys, run);
        screen.startSelection(false);
        ghost.show(true, "cross");
        screen.hover(ghost.p);
        await travel(screen, run, { x: 230, y: 250 }, 1000);
        await run.wait(450);
        await travel(screen, run, { x: 600, y: 152 }, 700);
        await run.wait(350);
        await travel(screen, run, { x: DEFAULT_CAPTURE.x, y: DEFAULT_CAPTURE.y }, 480);
        screen.press(ghost.p);
        ghost.down(true);
        await travel(screen, run, { x: DEFAULT_CAPTURE.x + DEFAULT_CAPTURE.w, y: DEFAULT_CAPTURE.y + DEFAULT_CAPTURE.h }, 1100, "drag");
        await run.wait(220);
        ghost.down(false);
        screen.release(ghost.p);
        ghost.show(true);
        await new Promise((resolve) => {
          const done = (type) => type === "translated" && (screen.listeners.delete(done), resolve());
          screen.on(done);
        });
        await run.wait(900);
        await clickAt(screen, run, screen.toolbar.segments[0]);
        screen.perform("original");
        await run.wait(1000);
        await clickAt(screen, run, screen.toolbar.segments[1]);
        screen.perform("translation");
        await run.wait(500);
        await ghost.glide(run, { x: 700, y: 560 }, 700);
      } catch (error) {
        quiet(error);
      } finally {
        if (script === run) script = null;
        ghost.show(false);
        ghost.down(false);
        if (!screen.capture && !screen.selection) screen.openCapture(DEFAULT_CAPTURE, { instant: true });
      }
    };
    warm(screen.target);
    const begin = () => whenSeen(heroHost, () => setTimeout(intro, 300), 0.5);
    if (document.readyState === "complete") begin();
    else addEventListener("load", begin, { once: true });
  }

  // ---------- one control, blown up: 原文 / 译文 ----------

  const compare = document.querySelector("[data-compare]");
  if (compare) {
    const choices = [...compare.querySelectorAll("[role=radio]")];
    const word = compare.querySelector("[data-compare-word]");
    let shown = compare.dataset.show || "translation";
    const render = (value) => {
      compare.dataset.show = value;
      choices.forEach((choice) => {
        const on = choice.dataset.value === value;
        choice.setAttribute("aria-checked", String(on));
        choice.tabIndex = on ? 0 : -1;
      });
      if (word) word.textContent = word.dataset[value === "translation" ? "translation" : "original"];
    };
    const set = (value, focus) => {
      shown = value;
      render(value);
      if (focus) choices.find((choice) => choice.dataset.value === value)?.focus();
    };
    choices.forEach((choice) => {
      choice.addEventListener("click", () => set(choice.dataset.value));
      choice.addEventListener("keydown", (event) => {
        if (!["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(event.key)) return;
        event.preventDefault();
        set(shown === "original" ? "translation" : "original", true);
      });
    });
    compare.querySelector('[data-key="toggle"]')?.addEventListener("click", (event) => {
      pressKeys(event.currentTarget);
      set(shown === "original" ? "translation" : "original");
    });
    const peek = compare.querySelector('[data-key="peek"]');
    if (peek) {
      const hold = (on) => {
        peek.classList.toggle("is-held", on);
        render(on ? "original" : shown);
      };
      peek.addEventListener("pointerdown", (event) => {
        event.preventDefault();
        peek.setPointerCapture?.(event.pointerId);
        hold(true);
      });
      for (const type of ["pointerup", "pointercancel", "lostpointercapture"]) peek.addEventListener(type, () => hold(false));
      peek.addEventListener("keydown", (event) => {
        if ((event.key === " " || event.key === "Enter") && !event.repeat) {
          event.preventDefault();
          hold(true);
        }
      });
      peek.addEventListener("keyup", (event) => (event.key === " " || event.key === "Enter") && hold(false));
      peek.addEventListener("click", (event) => event.preventDefault());
    }
    render(shown);
  }

  // ---------- how it works: one slider through the production stages ----------

  const how = document.querySelector("[data-how]");
  if (how) {
    const range = how.querySelector(".how-range");
    const fill = how.querySelector(".how-fill");
    const steps = [...how.querySelectorAll(".how-step")];
    const shots = [...how.querySelectorAll(".how-shot")];
    const names = [...how.querySelectorAll(".how-names li")];
    const boxes = how.querySelector("[data-lines]");
    const lines = scene.lines[how.dataset.lines || "en"] || [];
    if (boxes) {
      boxes.setAttribute("viewBox", `0 0 ${DEFAULT_CAPTURE.w} ${DEFAULT_CAPTURE.h}`);
      lines.forEach((line, i) => boxes.append(s("rect", { x: line.x - 2, y: line.y - 2, width: line.w + 4, height: line.h + 4, style: `--i:${i}` })));
    }
    let current = -1;
    const go = (index) => {
      if (index === current) return;
      const previous = current;
      current = index;
      range.value = index;
      range.setAttribute("aria-valuetext", names[index].textContent.trim());
      fill.style.setProperty("--p", `${(index / (steps.length - 1)) * 100}%`);
      [steps, names].forEach((list) => list.forEach((el, i) => el.classList.toggle("is-on", i === index)));
      shots.forEach((shot, i) => {
        shot.classList.toggle("is-on", i === index);
        shot.classList.toggle("is-under", i === previous);
      });
      how.dataset.stage = String(index);
    };
    range.addEventListener("input", () => go(Number(range.value)));
    names.forEach((name, index) => name.querySelector("button")?.addEventListener("click", () => go(index)));
    go(0);
  }

  // ---------- a capture you can work with: one held screen, six controls ----------

  const work = document.querySelector("[data-work]");
  if (work) {
    const host = work.querySelector('[data-screen="work"]');
    const frame = work.querySelector(".work-stage");
    const count = work.querySelector("[data-count]");
    const items = [...work.querySelectorAll(".work-item")];
    const list = work.querySelector(".work-list");
    const sideways = matchMedia("(max-width: 1023px)");
    const screen = new Screen(host, {
      target: host.dataset.target || "en",
      clip: frame,
      toolbarScale: (scale) => Math.min(1, (host.getBoundingClientRect().width - 16) / (536 * scale)),
    });
    const focus = { x: DEFAULT_CAPTURE.x - 20, y: DEFAULT_CAPTURE.y - 24, w: DEFAULT_CAPTURE.w + 40, h: DEFAULT_CAPTURE.h + 140 };
    const layout = () => {
      const box = host.getBoundingClientRect();
      const scale = clamp(Math.min(box.width / 420, box.height / focus.h), 0.6, 1.5);
      const x = clamp(focus.x + focus.w / 2 - box.width / scale / 2, 0, Math.max(0, PAGE_W - box.width / scale));
      const y = clamp(focus.y + focus.h / 2 - box.height / scale / 2, 0, Math.max(0, PAGE_H - box.height / scale));
      screen.layout(scale, { x, y });
    };
    const chat = work.querySelector("[data-chat]");
    const thread = chat?.querySelector("[data-thread]");
    const controls = {
      tools: [...work.querySelectorAll("[data-work-tool]")],
      colors: [...work.querySelectorAll("[data-work-color]")],
      langs: [...work.querySelectorAll("[data-work-lang]")],
      edge: work.querySelector("[data-work-edge]"),
      pin: work.querySelector("[data-work-pin]"),
      again: work.querySelector("[data-work-again]"),
      last: work.querySelector("[data-work-last]"),
      copy: work.querySelector("[data-work-copy]"),
      text: work.querySelector("[data-work-text]"),
    };
    const ensure = ({ marks = true } = {}) => {
      if (screen.selection) screen.cancelSelection();
      if (!screen.capture) {
        screen.openCapture(DEFAULT_CAPTURE, { instant: true });
        if (marks) screen.setMarks(SAMPLE_MARKS());
      }
      return screen.capture;
    };
    const clearPins = () => {
      for (const pin of [...screen.pins]) pin.close();
      chat?.classList.remove("is-open");
    };
    const sync = () => {
      controls.tools.forEach((button) => button.setAttribute("aria-pressed", String(screen.capture != null && screen.tool === button.dataset.workTool && screen.annotating)));
      controls.colors.forEach((button) => button.setAttribute("aria-checked", String(screen.color === button.dataset.workColor)));
      controls.langs.forEach((button) => button.setAttribute("aria-checked", String(screen.capture != null && screen.target === button.dataset.workLang)));
      if (controls.edge && screen.capture && !controls.edge.matches(":active")) controls.edge.value = String(screen.capture.rect.y + screen.capture.rect.h);
      if (controls.again) controls.again.classList.toggle("is-inviting", !screen.capture && !screen.selection && screen.pins.length > 0);
      if (controls.last) {
        const offer = !!screen.selection && !!lastArea && !screen.selection.taking;
        controls.last.hidden = !offer;
        controls.last.classList.toggle("is-inviting", offer);
      }
      if (controls.copy) controls.copy.classList.toggle("is-done", !!screen.copied && !!screen.capture);
    };
    screen.on((type, detail) => {
      sync();
      if (type === "copy" && chat) paste(detail);
    });

    const snapshotView = (picture, width) => {
      const { rect, lang, marks } = picture;
      const k = width / rect.w;
      const img = h("img", { src: pageFor(lang), alt: "", width: PAGE_W, height: PAGE_H, style: `position:absolute;left:${-rect.x * k}px;top:${-rect.y * k}px;width:${PAGE_W * k}px;height:${PAGE_H * k}px;max-width:none` });
      const svg = s("svg", { class: "cap-marks", viewBox: `0 0 ${rect.w} ${rect.h}`, "aria-hidden": "true" });
      svg.append(...marks.map(drawMark));
      return h("div", { class: "chat-picture", style: `width:${width}px;height:${rect.h * k}px` }, img, svg);
    };
    const paste = (picture) => {
      chat.classList.add("is-open");
      const bubble = h("div", { class: "chat-row is-mine" }, snapshotView(picture, 170));
      thread.append(bubble);
      thread.scrollTop = thread.scrollHeight;
      if (!reduced) bubble.animate([{ opacity: 0, transform: "translateY(8px)" }, { opacity: 1, transform: "none" }], { duration: 260, easing: "cubic-bezier(0.22, 1, 0.36, 1)" });
    };

    let script = null;
    const stop = () => {
      script?.stop();
      script = null;
      screen.ghost.show(false);
    };
    screen.on((type) => type === "interrupt" && stop());
    const scenes = {
      mark: async (run) => {
        clearPins();
        const fresh = !screen.capture;
        ensure({ marks: false });
        if (fresh || !screen.marks.length) {
          screen.setMarks([]);
          for (const mark of SAMPLE_MARKS()) {
            await run.wait(260);
            screen.marks.push(mark);
            screen.refresh();
          }
        }
        if (!screen.annotating) screen.chooseTool("rectangle");
      },
      language: async () => {
        clearPins();
        ensure();
        if (screen.annotating) screen.chooseTool("move");
      },
      edge: async (run) => {
        clearPins();
        const capture = ensure();
        if (screen.annotating) screen.chooseTool("move");
        if (capture.rect.h !== DEFAULT_CAPTURE.h || reduced) return;
        const ghost = screen.ghost;
        const bottom = { x: capture.rect.x + capture.rect.w / 2, y: capture.rect.y + capture.rect.h };
        ghost.at({ x: bottom.x + 60, y: bottom.y + 60 });
        ghost.show(true);
        capture.el.classList.add("is-hover");
        await ghost.glide(run, bottom, 700);
        ghost.show(true, "resize");
        ghost.down(true);
        await screen.resizeBy("b", bottom, { x: bottom.x, y: bottom.y + 72 }, 900, run);
        ghost.down(false);
        await run.wait(400);
        ghost.show(false);
      },
      pin: async () => {
        chat?.classList.remove("is-open");
        if (!screen.capture && !screen.pins.length) ensure();
        if (screen.annotating) screen.chooseTool("move");
      },
      copy: async () => {
        clearPins();
        ensure();
        if (screen.annotating) screen.chooseTool("move");
      },
      text: async () => {
        clearPins();
        ensure();
        if (screen.annotating) screen.chooseTool("move");
      },
    };
    let active = null;
    let tabs = [];
    const enter = (item) => {
      if (active === item) return;
      active = item;
      items.forEach((other) => other.classList.toggle("is-on", other === item));
      tabs.forEach((tab) => {
        const on = tab.dataset.tab === item.dataset.step;
        tab.setAttribute("aria-selected", String(on));
        tab.tabIndex = on ? 0 : -1;
      });
      if (count) count.textContent = String(items.indexOf(item) + 1);
      work.dataset.step = item.dataset.step;
      stop();
      closeFloat();
      script = new Script();
      const run = script;
      scenes[item.dataset.step]?.(run).catch(quiet).finally(() => {
        if (script === run) script = null;
        sync();
      });
    };
    // The step in the middle of the screen is the one shown; on a narrow screen, the card swiped into view.
    let observer = null;
    const watch = () => {
      observer?.disconnect();
      if (!("IntersectionObserver" in window) || sideways.matches) return;
      observer = new IntersectionObserver((entries) => {
        const visible = entries.filter((entry) => entry.isIntersecting).sort((a, b) => b.intersectionRatio - a.intersectionRatio);
        if (visible[0]) enter(visible[0].target);
      }, { rootMargin: "-45% 0px -45% 0px" });
      items.forEach((item) => observer.observe(item));
    };
    tabs = [...work.querySelectorAll("[data-tab]")];
    tabs.forEach((tab, index) => {
      tab.addEventListener("click", () => enter(items.find((item) => item.dataset.step === tab.dataset.tab)));
      tab.addEventListener("keydown", (event) => {
        const step = { ArrowRight: 1, ArrowLeft: -1 }[event.key];
        if (!step) return;
        const next = tabs[(index + step + tabs.length) % tabs.length];
        next.focus();
        next.click();
      });
    });
    watch();
    sideways.addEventListener("change", () => (watch(), layout()));
    // A reload can land in the middle of the list: start with the step nearest the middle of the screen.
    const nearest = () => {
      const box = work.getBoundingClientRect();
      if (box.bottom < 0 || box.top > innerHeight) return;
      if (sideways.matches) return enter(items[0]);
      const middle = innerHeight / 2;
      const best = items.reduce((a, b) => (Math.abs(b.getBoundingClientRect().top + b.offsetHeight / 2 - middle) < Math.abs(a.getBoundingClientRect().top + a.offsetHeight / 2 - middle) ? b : a));
      enter(best);
    };
    addEventListener("load", () => setTimeout(nearest, 120), { once: true });
    whenSeen(frame, () => !active && enter(items[0]), 0.3);

    controls.tools.forEach((button) => button.addEventListener("click", () => {
      ensure();
      screen.interrupt();
      const tool = button.dataset.workTool;
      screen.chooseTool(screen.tool === tool && screen.annotating ? "move" : tool);
      sync();
    }));
    controls.colors.forEach((button) => button.addEventListener("click", () => {
      ensure();
      screen.setColor(button.dataset.workColor);
      if (!screen.annotating && screen.selected == null) screen.chooseTool(screen.tool === "move" ? "pen" : screen.tool);
      sync();
    }));
    controls.langs.forEach((button) => button.addEventListener("click", () => {
      ensure();
      screen.interrupt();
      screen.setTarget(button.dataset.workLang);
      sync();
    }));
    if (controls.edge) {
      controls.edge.min = String(DEFAULT_CAPTURE.y + 40);
      controls.edge.max = String(PAGE_H - 8);
      controls.edge.value = String(DEFAULT_CAPTURE.y + DEFAULT_CAPTURE.h);
      let dragging = false;
      controls.edge.addEventListener("input", () => {
        const capture = ensure();
        screen.interrupt();
        if (!dragging) {
          dragging = true;
          screen.drag = { kind: "resize", id: -2, edges: "b", start: { x: 0, y: capture.rect.y + capture.rect.h }, rect: { ...capture.rect } };
          screen.beginResize();
          capture.el.classList.add("is-hover");
        }
        screen.resizeTo({ x: 0, y: Number(controls.edge.value) });
      });
      controls.edge.addEventListener("change", () => {
        if (!dragging) return;
        dragging = false;
        screen.drag = null;
        screen.endResize();
      });
    }
    controls.pin?.addEventListener("click", () => {
      screen.interrupt();
      if (!screen.capture) ensure();
      pressKeys(controls.pin);
      screen.pin();
      sync();
    });
    controls.again?.addEventListener("click", () => {
      screen.interrupt();
      pressKeys(controls.again);
      if (screen.capture) screen.swap();
      else screen.startSelection();
      sync();
    });
    controls.last?.addEventListener("click", () => {
      screen.interrupt();
      pressKeys(controls.last);
      screen.selectLast();
      sync();
    });
    controls.copy?.addEventListener("click", () => {
      ensure();
      screen.interrupt();
      screen.action("copy");
    });
    controls.text?.addEventListener("click", () => {
      ensure();
      screen.interrupt();
      const anchor = screen.toolbar?.text;
      if (anchor) screen.transcript(anchor);
    });
    shortcutTargets.add({ screen, press: () => (pressKeys(controls.again || controls.pin), screen.capture ? screen.swap() : screen.startSelection()) });

    layout();
    addEventListener("resize", layout);
    whenSeen(work, () => warm(screen.target), 0);
  }

  // ---------- eight languages: one capture, any of them ----------

  const shelf = document.querySelector("[data-languages]");
  if (shelf) {
    const buttons = [...shelf.querySelectorAll("[data-lang-choice]")];
    const shot = shelf.querySelector(".language-shot");
    const pictures = shot.querySelector(".language-pictures");
    const label = shot.querySelector("[data-direction]");
    const layers = {};
    const layer = (lang) => {
      if (layers[lang]) return layers[lang];
      const img = h("img", { src: pageFor(lang), alt: "", width: PAGE_W, height: PAGE_H, decoding: "async" });
      const el = h("div", { class: "language-picture" }, img);
      pictures.append(el);
      layers[lang] = el;
      return el;
    };
    pictures.querySelectorAll(".language-picture[data-lang]").forEach((el) => (layers[el.dataset.lang] = el));
    let current = shelf.dataset.start || "en";
    const choose = (lang) => {
      current = lang;
      buttons.forEach((button) => {
        const on = button.dataset.langChoice === lang;
        button.setAttribute("aria-checked", String(on));
        button.tabIndex = on ? 0 : -1;
      });
      const next = layer(lang);
      const reveal = () => {
        if (current !== lang) return;
        Object.entries(layers).forEach(([key, el]) => el.classList.toggle("is-on", key === lang));
      };
      const img = next.querySelector("img");
      if (img.complete) reveal();
      else img.addEventListener("load", reveal, { once: true });
      if (label) label.textContent = lang === "ja" ? directionText("ja", "ja") : directionText("ja", lang);
    };
    buttons.forEach((button, index) => {
      button.addEventListener("click", () => choose(button.dataset.langChoice));
      button.addEventListener("keydown", (event) => {
        const step = { ArrowDown: 1, ArrowRight: 1, ArrowUp: -1, ArrowLeft: -1 }[event.key];
        if (!step) return;
        event.preventDefault();
        const next = buttons[(index + step + buttons.length) % buttons.length];
        next.focus();
        choose(next.dataset.langChoice);
      });
      button.addEventListener("pointerenter", () => warm(button.dataset.langChoice), { once: true });
    });
    choose(current);
  }
})();
