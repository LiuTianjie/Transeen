(() => {
  const menu = document.querySelector(".site-menu");
  const toggle = document.querySelector(".menu-toggle");
  const closeMenu = () => {
    menu.classList.remove("open");
    toggle.setAttribute("aria-expanded", "false");
    document.body.classList.remove("menu-open");
  };
  toggle.addEventListener("click", () => {
    const open = toggle.getAttribute("aria-expanded") !== "true";
    toggle.setAttribute("aria-expanded", String(open));
    menu.classList.toggle("open", open);
    document.body.classList.toggle("menu-open", open);
  });
  menu
    .querySelectorAll("a")
    .forEach((link) => link.addEventListener("click", closeMenu));
  document.addEventListener("keydown", (event) => {
    if (
      event.key === "Escape" &&
      toggle.getAttribute("aria-expanded") === "true"
    ) {
      closeMenu();
      toggle.focus();
    }
  });
  matchMedia("(min-width: 761px)").addEventListener("change", (event) => {
    if (event.matches) closeMenu();
  });

  const comparisons = [...document.querySelectorAll(".comparison")];
  const setComparison = (position) => {
    comparisons.forEach((comparison) => {
      const range = comparison.querySelector(".comparison-range");
      comparison.style.setProperty("--split", `${position}%`);
      comparison.dataset.position = position;
      range.value = position;
      range.setAttribute(
        "aria-valuetext",
        document.documentElement.lang === "zh-CN"
          ? `原文 ${position}%，译文 ${100 - position}%`
          : `Original ${position}%, translation ${100 - position}%`,
      );
    });
  };
  comparisons.forEach((comparison) => {
    const range = comparison.querySelector(".comparison-range");
    // Pointer capture keeps the divider attached even outside the picture.
    const updateFromPointer = (event) => {
      const bounds = comparison.getBoundingClientRect();
      const position = Math.round(
        Math.max(
          0,
          Math.min(100, ((event.clientX - bounds.left) / bounds.width) * 100),
        ),
      );
      setComparison(position);
    };
    let dragging = false;
    range.addEventListener("pointerdown", (event) => {
      if (event.button !== 0) return;
      dragging = true;
      range.focus({ preventScroll: true });
      range.setPointerCapture(event.pointerId);
      updateFromPointer(event);
      event.preventDefault();
    });
    range.addEventListener("pointermove", (event) => {
      if (dragging) updateFromPointer(event);
    });
    range.addEventListener("pointerup", () => {
      dragging = false;
    });
    range.addEventListener("pointercancel", () => {
      dragging = false;
    });
    range.addEventListener("lostpointercapture", () => {
      dragging = false;
    });
    range.addEventListener("input", () => setComparison(Number(range.value)));
  });
  setComparison(50);
  const dialog = document.querySelector(".lightbox");
  document
    .querySelector(".zoom")
    .addEventListener("click", () => dialog.showModal());
  dialog
    .querySelector(".lightbox-close")
    .addEventListener("click", () => dialog.close());
  dialog.addEventListener("click", (event) => {
    const box = dialog.getBoundingClientRect();
    if (
      event.clientX < box.left ||
      event.clientX > box.right ||
      event.clientY < box.top ||
      event.clientY > box.bottom
    )
      dialog.close();
  });

  if (
    "IntersectionObserver" in window &&
    !matchMedia("(prefers-reduced-motion: reduce)").matches
  ) {
    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.remove("pending");
            observer.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.06 },
    );
    document.querySelectorAll(".reveal").forEach((item) => {
      item.classList.add("pending");
      observer.observe(item);
    });
    document.documentElement.classList.add("js");
  }
})();
