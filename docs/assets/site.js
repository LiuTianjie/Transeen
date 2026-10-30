(() => {
  const reduce = matchMedia("(prefers-reduced-motion: reduce)");
  const still = () => reduce.matches || document.documentElement.hasAttribute("data-still");
  const zh = document.documentElement.lang.startsWith("zh");

  // Sticky navigation picks up its border once the page moves under it.
  const nav = document.querySelector(".nav");
  const top = document.querySelector("[data-top]");
  if (nav && top) {
    new IntersectionObserver(([entry]) => nav.classList.toggle("is-stuck", !entry.isIntersecting)).observe(top);
  }

  const reveals = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window) {
    const seen = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            entry.target.classList.add("in");
            seen.unobserve(entry.target);
          }
        }
      },
      { rootMargin: "0px 0px -12% 0px" }
    );
    reveals.forEach((el) => seen.observe(el));
  } else {
    reveals.forEach((el) => el.classList.add("in"));
  }

  // Guide: mark the section being read in the table of contents.
  const toc = document.querySelectorAll(".toc a");
  if (toc.length) {
    const links = new Map([...toc].map((a) => [a.hash.slice(1), a]));
    const current = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          toc.forEach((a) => a.classList.remove("is-current"));
          links.get(entry.target.id)?.classList.add("is-current");
        }
      },
      { rootMargin: "-20% 0px -70% 0px" }
    );
    links.forEach((_, id) => {
      const section = document.getElementById(id);
      if (section) current.observe(section);
    });
  }

  const demo = document.querySelector(".demo");
  if (demo) scene(demo);

  function scene(demo) {
    const win = demo.querySelector(".window");
    const card = win.querySelector(".card");
    const frame = win.querySelector(".frame");
    const size = win.querySelector(".frame-size");
    const scan = win.querySelector(".scan");
    const hits = win.querySelector(".hits");
    const cursor = win.querySelector(".cursor");
    const press = win.querySelector(".press");
    const toolbar = win.querySelector(".toolbar");
    const status = toolbar.querySelector('[data-ui="status"]');
    const dir = toolbar.querySelector('[data-ui="dir"]');
    const viewButtons = toolbar.querySelectorAll("[data-view]");
    const chips = document.querySelectorAll(".chip[data-lang]");
    const replay = document.querySelector(".replay");
    const blocks = [...card.querySelectorAll("[data-k]")];

    const ui = zh
      ? { original: "原文", translation: "译文", copy: "复制", translating: "正在翻译…", done: (n) => `已翻译 ${n} 处`, peek: "按住看原文 (空格)", release: "松开完成" }
      : { original: "Original", translation: "Translation", copy: "Copy", translating: "Translating…", done: (n) => `Translated ${n} items`, peek: "Hold to See Original (Space)", release: "Release to finish" };
    const short = { en: "EN", "zh-Hans": "中文", "zh-Hant": "繁中", ko: "KO", fr: "FR", es: "ES", de: "DE" };
    const text = {
      label: { ja: "選択中の列車", en: "Selected train", "zh-Hans": "已选列车", "zh-Hant": "已選列車", ko: "선택한 열차", fr: "Train choisi", es: "Tren elegido", de: "Gewählter Zug" },
      badge: { ja: "残りわずか", en: "Few seats left", "zh-Hans": "余票不多", "zh-Hant": "座位不多", ko: "잔여석 적음", fr: "Presque complet", es: "Quedan pocas", de: "Fast ausgebucht" },
      train: { ja: "しらかぜ 23号", en: "Shirakaze 23", "zh-Hans": "白风 23 号", "zh-Hant": "白風 23 號", ko: "시라카제 23호", fr: "Shirakaze n° 23", es: "Shirakaze n.º 23", de: "Shirakaze 23" },
      from: { ja: "東京", en: "Tokyo", "zh-Hans": "东京", "zh-Hant": "東京", ko: "도쿄", fr: "Tokyo", es: "Tokio", de: "Tokio" },
      dur: { ja: "2時間15分", en: "2 h 15 min", "zh-Hans": "2小时15分", "zh-Hant": "2小時15分", ko: "2시간 15분", fr: "2 h 15", es: "2 h 15 min", de: "2 Std. 15 Min." },
      to: { ja: "京都", en: "Kyoto", "zh-Hans": "京都", "zh-Hant": "京都", ko: "교토", fr: "Kyoto", es: "Kioto", de: "Kyoto" },
      seat: { ja: "指定席・7号車 12番E席（窓側）", en: "Reserved · Car 7, seat 12E (window)", "zh-Hans": "指定席 · 7 号车 12E 座（靠窗）", "zh-Hant": "指定席・7 號車 12E 座（靠窗）", ko: "지정석 · 7호차 12E석 (창가)", fr: "Place réservée · voiture 7, 12E (fenêtre)", es: "Reservado · coche 7, asiento 12E (ventana)", de: "Reserviert · Wagen 7, Platz 12E (Fenster)" },
      fare: { ja: "大人1名・税込", en: "1 adult, tax included", "zh-Hans": "成人 1 名 · 含税", "zh-Hant": "成人 1 名・含稅", ko: "성인 1명 · 세금 포함", fr: "1 adulte, TTC", es: "1 adulto, impuestos incl.", de: "1 Erwachsener, inkl. MwSt." },
      buy: { ja: "予約へ進む", en: "Continue to booking", "zh-Hans": "继续预订", "zh-Hant": "繼續預訂", ko: "예약 계속하기", fr: "Continuer la réservation", es: "Continuar con la reserva", de: "Weiter zur Buchung" },
      note: { ja: "発車6分前まで、何度でも変更できます。", en: "Change it as often as you like until 6 minutes before departure.", "zh-Hans": "发车 6 分钟前都能随时更改，不限次数。", "zh-Hant": "發車 6 分鐘前都能隨時更改，不限次數。", ko: "출발 6분 전까지 몇 번이든 변경할 수 있습니다.", fr: "Modifiable à volonté jusqu’à 6 minutes avant le départ.", es: "Puedes cambiarlo cuantas veces quieras hasta 6 minutos antes de salir.", de: "Bis 6 Minuten vor Abfahrt beliebig oft änderbar." },
    };

    toolbar.querySelector('[data-ui="original"]').textContent = ui.original;
    toolbar.querySelector('[data-ui="translation"]').textContent = ui.translation;
    toolbar.querySelector('[data-ui="copy"]').textContent = ui.copy;

    const state = { target: zh ? "zh-Hans" : "en", view: "original", run: 0, ready: false, scale: 1, crop: 0 };
    const W = 1000;
    const H = 620;

    // The window keeps its 1000-point layout and is scaled to the column; narrow screens show its
    // right half, where the capture is, so the text stays readable.
    const viewport = demo.querySelector(".demo-viewport");
    new ResizeObserver(() => {
      const width = viewport.clientWidth;
      const crop = width < 640 ? 470 : 0;
      const s = width / (W - crop);
      state.scale = s;
      state.crop = crop;
      demo.style.setProperty("--s", s);
      demo.style.setProperty("--vh", `${H}px`);
      win.style.setProperty("--tx", `${-crop * s}px`);
      if (state.ready || demo.classList.contains("is-captured")) placeToolbar();
    }).observe(viewport);

    const sleep = (ms, run) =>
      new Promise((resolve, reject) => setTimeout(() => (run === state.run ? resolve() : reject("stale")), ms));
    const frameOf = () => box(card);

    function box(el) {
      const a = el.getBoundingClientRect();
      const b = win.getBoundingClientRect();
      const s = state.scale;
      return { x: (a.left - b.left) / s, y: (a.top - b.top) / s, w: a.width / s, h: a.height / s };
    }

    function textBox(el) {
      const range = document.createRange();
      range.selectNodeContents(el);
      const rects = [...range.getClientRects()];
      const b = win.getBoundingClientRect();
      const s = state.scale;
      return rects.map((r) => ({ x: (r.left - b.left) / s, y: (r.top - b.top) / s, w: r.width / s, h: r.height / s }));
    }

    function place(el, r) {
      el.style.left = `${r.x}px`;
      el.style.top = `${r.y}px`;
      el.style.width = `${r.w}px`;
      el.style.height = `${r.h}px`;
    }

    // Like the app, a translation keeps its place and size, and shrinks only when it would not fit.
    function fit(el) {
      el.style.fontSize = "";
      let px = parseFloat(getComputedStyle(el).fontSize);
      const floor = px * 0.72;
      while ((el.scrollWidth > el.clientWidth + 0.5 || el.scrollHeight > el.clientHeight + 1) && px > floor) {
        px -= 0.5;
        el.style.fontSize = `${px}px`;
      }
    }

    function write(el, lang) {
      el.textContent = text[el.dataset.k][lang];
      el.lang = lang;
      fit(el);
    }

    function showAll(lang) {
      blocks.forEach((el) => write(el, lang));
    }

    function setView(view) {
      state.view = view;
      viewButtons.forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.view === view)));
      showAll(view === "original" ? "ja" : state.target);
    }

    function setChips() {
      chips.forEach((c) => c.setAttribute("aria-pressed", String(c.dataset.lang === state.target)));
      dir.textContent = `JA → ${short[state.target]}`;
    }

    function placeToolbar() {
      const f = frameOf();
      toolbar.style.left = "0px";
      const w = toolbar.offsetWidth;
      const right = Math.min(W - 10, f.x + f.w);
      const k = Math.min(1, (right - state.crop - 10) / w);
      toolbar.style.setProperty("--k", k);
      toolbar.style.left = `${right - w}px`;
      toolbar.style.top = `${Math.min(H - toolbar.offsetHeight - 8, f.y + f.h + 10)}px`;
    }

    function reset() {
      state.ready = false;
      demo.classList.remove("is-captured", "is-dim", "is-snapped", "is-done");
      toolbar.classList.remove("is-live");
      hits.replaceChildren();
      scan.classList.remove("is-running");
      press.classList.remove("is-on");
      setView("original");
      setChips();
      place(frame, { x: 330, y: 360, w: 0, h: 0 });
      cursor.style.transform = "translate(330px, 360px)";
      cursor.classList.remove("is-down", "is-hidden");
    }

    function finish() {
      const f = frameOf();
      place(frame, f);
      demo.classList.add("is-dim", "is-snapped", "is-captured", "is-done");
      cursor.classList.add("is-hidden");
      setView("translation");
      status.textContent = `${ui.done(blocks.length)} · ${ui.peek}`;
      placeToolbar();
      toolbar.classList.add("is-live");
      state.ready = true;
    }

    async function translate(run, fast) {
      const lines = blocks.flatMap((el) => textBox(el).map((r) => ({ el, r })));
      hits.replaceChildren(
        ...lines.map(({ r }, i) => {
          const hit = document.createElement("span");
          hit.className = "hit";
          place(hit, { x: r.x - 3, y: r.y - 1, w: r.w + 6, h: r.h + 2 });
          hit.style.transitionDelay = `${fast ? 0 : i * 45}ms`;
          return hit;
        })
      );
      void hits.offsetWidth;
      hits.classList.add("is-on");
      if (!fast) {
        scan.style.setProperty("--scan-h", `${frameOf().h + 80}px`);
        scan.classList.add("is-running");
        await sleep(1000, run);
      }
      viewButtons.forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.view === "translation")));
      status.textContent = `${ui.translating} 0/${blocks.length}`;
      blocks.forEach((el, i) => {
        el.style.transitionDelay = `${i * 30}ms`;
        el.classList.add("is-lift");
      });
      await sleep(fast ? 260 : 520, run);
      // Apple Translation answers in groups of 8; the toolbar counts them as they arrive.
      for (const group of [blocks.slice(0, 8), blocks.slice(8)]) {
        group.forEach((el, i) => {
          el.style.transitionDelay = "0ms";
          el.classList.add("is-enter");
          el.classList.remove("is-lift");
          write(el, state.target);
          void el.offsetWidth;
          el.style.transitionDelay = `${i * 40}ms`;
          el.classList.remove("is-enter");
        });
        const done = blocks.indexOf(group[group.length - 1]) + 1;
        status.textContent = `${ui.translating} ${done}/${blocks.length}`;
        await sleep(fast ? 220 : 480, run);
      }
      state.view = "translation";
      hits.classList.remove("is-on");
      status.textContent = `${ui.done(blocks.length)} · ${ui.peek}`;
    }

    async function play() {
      const run = ++state.run;
      reset();
      if (still()) {
        finish();
        return;
      }
      try {
        await sleep(500, run);
        press.classList.add("is-on");
        demo.classList.add("is-dim");
        await sleep(650, run);
        press.classList.remove("is-on");
        const f = frameOf();
        cursor.style.transform = `translate(${f.x + f.w * 0.62}px, ${f.y + f.h * 0.56}px)`;
        await sleep(420, run);
        size.textContent = `${Math.round(f.w * 2)} × ${Math.round(f.h * 2)} px · ${ui.release}`;
        place(frame, f);
        demo.classList.add("is-snapped");
        await sleep(900, run);
        cursor.classList.add("is-down");
        await sleep(160, run);
        demo.classList.add("is-captured");
        cursor.classList.remove("is-down");
        cursor.classList.add("is-hidden");
        placeToolbar();
        status.textContent = ui.translating;
        await translate(run, false);
        demo.classList.add("is-done");
        toolbar.classList.add("is-live");
        state.ready = true;
      } catch (error) {
        if (error !== "stale") throw error;
      }
    }

    async function retarget(lang) {
      state.target = lang;
      setChips();
      if (!state.ready) {
        play();
        return;
      }
      const run = ++state.run;
      if (still()) {
        setView("translation");
        return;
      }
      try {
        state.ready = false;
        await translate(run, true);
        state.ready = true;
      } catch (error) {
        if (error !== "stale") throw error;
      }
    }

    chips.forEach((chip) => chip.addEventListener("click", () => retarget(chip.dataset.lang)));
    replay?.addEventListener("click", play);
    viewButtons.forEach((b) =>
      b.addEventListener("click", () => {
        if (state.ready) setView(b.dataset.view);
      })
    );

    let peeking = false;
    demo.addEventListener("keydown", (event) => {
      if (event.key !== " ") return;
      event.preventDefault();
      if (state.ready && !peeking) {
        peeking = true;
        setView("original");
      }
    });
    const unpeek = () => {
      if (!peeking) return;
      peeking = false;
      setView("translation");
    };
    demo.addEventListener("keyup", (event) => event.key === " " && unpeek());
    demo.addEventListener("blur", unpeek);
    demo.addEventListener("pointerdown", (event) => {
      if (state.ready && !event.target.closest(".toolbar")) {
        peeking = true;
        setView("original");
      }
    });
    addEventListener("pointerup", unpeek);
    addEventListener("pointercancel", unpeek);

    reset();
    const start = () => (document.fonts?.ready ?? Promise.resolve()).then(play);
    if (document.documentElement.hasAttribute("data-still")) {
      start();
      return;
    }
    const rect = demo.getBoundingClientRect();
    if (rect.top < innerHeight && rect.bottom > 0) {
      start();
      return;
    }
    new IntersectionObserver(([entry], observer) => {
      if (entry.isIntersecting) {
        observer.disconnect();
        start();
      }
    }).observe(demo);
  }
})();
