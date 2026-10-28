(() => {
  const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const clamp = (value, min, max) => Math.min(max, Math.max(min, value));

  // Parts of each section rise once as they enter; anything still hidden after load is shown.
  const risers = [...document.querySelectorAll("[data-rise]")];
  if ("IntersectionObserver" in window && !reduced) {
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
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
          if (box.top < innerHeight && box.bottom > 0) el.classList.add("is-in");
        }
      }, 2500),
    );
  } else {
    risers.forEach((el) => el.classList.add("is-in"));
  }

  // The hero: a sample page under the ⌃⌥2 selection. The picture inside the selection is the
  // production renderer's translation; the toolbar is its real render.
  const demo = document.querySelector("[data-demo]");
  if (demo) {
    const screen = demo.querySelector(".demo-screen");
    const layers = [...demo.querySelectorAll(".demo-translation img")];
    const bar = demo.querySelector(".demo-bar");
    const barImage = bar.querySelector("img");
    const chip = demo.querySelector(".demo-chip");
    const label = document.querySelector("[data-stage-label]");
    const buttons = [...demo.querySelectorAll(".demo-compare")];
    const W = 720, H = 500, BAR_W = 552, BAR_H = 93;
    const narrow = matchMedia("(max-width: 599px)");
    const regions = [
      [12, 22, 164, 194], [204, 30, 500, 136], [204, 168, 488, 86], [204, 256, 488, 70],
      [204, 334, 488, 104], [204, 432, 320, 52],
    ];
    const start = () => (narrow.matches ? { l: 196, t: 66, w: 360, h: 264 } : { l: 204, t: 66, w: 500, h: 264 });
    let rect = start();
    let active = 0;
    let original = false;
    let timer = 0;
    let resume = 0;

    const toolbarFor = () => (original ? demo.dataset.originalToolbar : layers[active].dataset.toolbar);
    const place = () => {
      demo.style.setProperty("--l", `${rect.l}px`);
      demo.style.setProperty("--t", `${rect.t}px`);
      demo.style.setProperty("--w", `${rect.w}px`);
      demo.style.setProperty("--h", `${rect.h}px`);
      demo.style.setProperty("--r", `${Math.min(10, Math.min(rect.w, rect.h) / 6)}px`);
      let y = rect.t + rect.h + 8;
      if (y + BAR_H > H - 4) y = rect.t - BAR_H - 8 >= 4 ? rect.t - BAR_H - 8 : H - BAR_H - 4;
      // On a phone the page is cropped from the left, so the toolbar keeps to the visible side.
      const x = narrow.matches ? W - BAR_W - 8 : clamp(rect.l + rect.w / 2 - BAR_W / 2, 8, W - BAR_W - 8);
      demo.style.setProperty("--bar-x", `${x}px`);
      demo.style.setProperty("--bar-y", `${y}px`);
    };
    const hint = (x, y) => {
      chip.textContent = `${Math.round(rect.w * 2)} × ${Math.round(rect.h * 2)} px  ·  松开完成`;
      const width = chip.offsetWidth || 190;
      const cx = x + 18 + width > W - 8 ? x - width - 18 : x + 18;
      demo.style.setProperty("--chip-x", `${clamp(cx, 8, W - width - 8)}px`);
      demo.style.setProperty("--chip-y", `${clamp(y + 16, 8, H - 42)}px`);
    };
    const translation = demo.querySelector(".demo-translation");
    const swap = (index) => {
      active = index;
      layers.forEach((img, i) => img.classList.toggle("is-on", i === index));
      barImage.src = toolbarFor();
      if (label) label.textContent = layers[index].dataset.direction;
    };
    // Between languages the capture dips to the original for a moment, as it does when the app re-translates.
    const show = (index) => {
      translation.classList.add("is-swapping");
      setTimeout(() => {
        swap(index);
        translation.classList.remove("is-swapping");
      }, 320);
    };
    const setOriginal = (value) => {
      original = value;
      demo.classList.toggle("is-original", value);
      buttons.forEach((button) => button.setAttribute("aria-pressed", String((button.dataset.show === "original") === value)));
      barImage.src = toolbarFor();
      if (value) stop();
      else later(4000);
    };
    const stop = () => {
      clearInterval(timer);
      clearTimeout(resume);
      timer = 0;
    };
    const cycle = () => {
      stop();
      if (reduced || document.hidden || original) return;
      timer = setInterval(() => show((active + 1) % layers.length), 7000);
    };
    const later = (ms) => {
      stop();
      resume = setTimeout(cycle, ms);
    };

    const loadLayers = () => {
      for (const img of layers) if (img.dataset.src && !img.src.endsWith(img.dataset.src)) img.src = img.dataset.src;
      for (const name of new Set(layers.map((img) => img.dataset.toolbar))) new Image().src = name;
    };

    const point = (event) => {
      const box = screen.getBoundingClientRect();
      const scale = box.width / W;
      return { x: clamp((event.clientX - box.left) / scale, 0, W), y: clamp((event.clientY - box.top) / scale, 0, H) };
    };
    let drag = null;
    screen.addEventListener("pointerdown", (event) => {
      if (event.button !== 0 || event.target.closest(".demo-bar")) return;
      drag = { start: point(event), moved: false, id: event.pointerId };
      try {
        screen.setPointerCapture(event.pointerId);
      } catch {
        // A pointer that is no longer active cannot be captured; the drag still follows its events.
      }
      stop();
    });
    screen.addEventListener("pointermove", (event) => {
      if (!drag || event.pointerId !== drag.id) return;
      const p = point(event);
      if (!drag.moved && Math.hypot(p.x - drag.start.x, p.y - drag.start.y) < 4) return;
      drag.moved = true;
      demo.classList.add("is-dragging");
      rect = { l: Math.min(p.x, drag.start.x), t: Math.min(p.y, drag.start.y), w: Math.abs(p.x - drag.start.x), h: Math.abs(p.y - drag.start.y) };
      place();
      hint(p.x, p.y);
    });
    const release = (event) => {
      if (!drag || event.pointerId !== drag.id) return;
      const p = point(event);
      if (!drag.moved || rect.w < 24 || rect.h < 24) {
        const hit = regions.find(([l, t, w, h]) => p.x >= l && p.x <= l + w && p.y >= t && p.y <= t + h) || [0, 0, W, H];
        rect = { l: hit[0], t: hit[1], w: hit[2], h: hit[3] };
        place();
      }
      drag = null;
      demo.classList.remove("is-dragging");
      if (original) setOriginal(false);
      else later(5000);
    };
    screen.addEventListener("pointerup", release);
    screen.addEventListener("pointercancel", (event) => {
      if (!drag || event.pointerId !== drag.id) return;
      drag = null;
      demo.classList.remove("is-dragging");
      later(5000);
    });
    screen.addEventListener("keydown", (event) => {
      const step = event.altKey ? 1 : 8;
      const moves = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step] };
      const move = moves[event.key];
      if (!move) return;
      event.preventDefault();
      if (event.shiftKey) {
        rect.w = clamp(rect.w + move[0], 24, W - rect.l);
        rect.h = clamp(rect.h + move[1], 24, H - rect.t);
      } else {
        rect.l = clamp(rect.l + move[0], 0, W - rect.w);
        rect.t = clamp(rect.t + move[1], 0, H - rect.h);
      }
      place();
      later(5000);
    });
    buttons.forEach((button) => button.addEventListener("click", () => setOriginal(button.dataset.show === "original")));
    document.addEventListener("visibilitychange", () => (document.hidden ? stop() : later(2000)));
    narrow.addEventListener("change", () => {
      rect = start();
      place();
    });

    // Once on arrival the selection draws itself the way ⌃⌥2 does; then the translations take turns.
    const intro = () => {
      if (reduced) {
        rect = start();
        place();
        return;
      }
      demo.classList.add("is-dragging");
      const began = performance.now();
      const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
      const frame = (now) => {
        const t = Math.min(1, (now - began) / 1100);
        const e = ease(t);
        const target = start();
        rect = { l: target.l, t: target.t, w: Math.max(1, target.w * e), h: Math.max(1, target.h * e) };
        place();
        hint(target.l + rect.w, target.t + rect.h);
        if (t < 1) requestAnimationFrame(frame);
        else
          setTimeout(() => {
            demo.classList.remove("is-dragging");
            later(4200);
          }, 260);
      };
      requestAnimationFrame(frame);
    };

    place();
    swap(0);
    if (document.readyState === "complete") loadLayers();
    else addEventListener("load", () => setTimeout(loadLayers, 400));
    setTimeout(intro, 500);
  }

  // One control, blown up: the segmented 原文 / 译文 switch swaps the field and one word.
  const compare = document.querySelector("[data-compare]");
  if (compare) {
    const choices = [...compare.querySelectorAll("[role=radio]")];
    const word = compare.querySelector("[data-compare-word]");
    const set = (value, focus) => {
      compare.dataset.show = value;
      choices.forEach((choice) => {
        const on = choice.dataset.value === value;
        choice.setAttribute("aria-checked", String(on));
        choice.tabIndex = on ? 0 : -1;
        if (on && focus) choice.focus();
      });
      word.textContent = word.dataset[value];
    };
    choices.forEach((choice) => {
      choice.addEventListener("click", () => set(choice.dataset.value));
      choice.addEventListener("keydown", (event) => {
        if (!["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(event.key)) return;
        event.preventDefault();
        set(compare.dataset.show === "original" ? "translation" : "original", true);
      });
    });
    set(compare.dataset.show || "translation");
  }

  // How it works: one slider drives the clause and the fragment.
  const how = document.querySelector("[data-how]");
  if (how) {
    const range = how.querySelector(".how-range");
    const fill = how.querySelector(".how-fill");
    const steps = [...how.querySelectorAll(".how-step")];
    const shots = [...how.querySelectorAll(".how-shot")];
    const names = [...how.querySelectorAll(".how-names li")];
    const go = (index) => {
      range.value = index;
      range.setAttribute("aria-valuetext", names[index].textContent.trim());
      fill.style.setProperty("--p", `${(index / (steps.length - 1)) * 100}%`);
      [steps, shots, names].forEach((list) => list.forEach((el, i) => el.classList.toggle("is-on", i === index)));
    };
    range.addEventListener("input", () => go(Number(range.value)));
    names.forEach((name, index) => name.querySelector("button")?.addEventListener("click", () => go(index)));
    go(0);
  }

  // The band: a selection crosses the line as it scrolls into view, and the words under it change.
  const band = document.querySelector("[data-band]");
  if (band) {
    const line = band.querySelector(".band-line");
    let queued = false;
    const update = () => {
      queued = false;
      const box = band.getBoundingClientRect();
      const progress = clamp((innerHeight * 0.85 - box.top) / (innerHeight * 0.5), 0, 1);
      line.style.setProperty("--p", reduced ? 1 : progress.toFixed(3));
    };
    const request = () => {
      if (!queued) {
        queued = true;
        requestAnimationFrame(update);
      }
    };
    addEventListener("scroll", request, { passive: true });
    addEventListener("resize", request);
    update();
  }

  // Older browsers ignore <details name>; keep one answer open at a time there too.
  const answers = [...document.querySelectorAll(".faq-item")];
  answers.forEach((item) =>
    item.addEventListener("toggle", () => {
      if (item.open) answers.forEach((other) => other !== item && other.open && (other.open = false));
    }),
  );

})();
