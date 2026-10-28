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

  const capture = document.querySelector(".capture");
  const buttons = document.querySelectorAll("[data-demo]");
  buttons.forEach((button) =>
    button.addEventListener("click", () => {
      capture.dataset.view = button.dataset.demo;
      capture
        .querySelector(".original")
        .setAttribute(
          "aria-hidden",
          String(button.dataset.demo !== "original"),
        );
      capture
        .querySelector(".translated")
        .setAttribute(
          "aria-hidden",
          String(button.dataset.demo !== "translated"),
        );
      buttons.forEach((item) =>
        item.setAttribute("aria-pressed", String(item === button)),
      );
      document.querySelector("#demo-status").textContent = button.dataset.label;
    }),
  );
  const dialog = document.querySelector(".lightbox");
  document.querySelector(".zoom").addEventListener("click", () => {
    const original = capture.dataset.view === "original";
    const source = capture.querySelector(
      original ? ".original" : ".translated",
    );
    const image = dialog.querySelector("img");
    image.src = source.src;
    image.alt = source.alt;
    dialog.showModal();
  });
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
