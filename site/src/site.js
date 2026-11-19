// agneta.dahlbom.io: the screenshots' light and dark switch, copy buttons, the current section in a page's contents,
// and the install page's order of downloads. Every page reads and works without it. It reads nothing of the address
// but the fragment, and sends nothing anywhere (site/build.py checks).
(() => {
  // The install page (/get/): an app that sent the user here names the Mac's architecture in the fragment (#arm64 or
  // #x86_64), which the browser never sends anywhere. That download goes first, marked; without one, both stay as they are.
  const downloads = document.querySelector("[data-downloads]");
  if (downloads) {
    const order = () => {
      const arch = location.hash.slice(1);
      const mine = arch === "arm64" || arch === "x86_64" ? downloads.querySelector(`[data-arch="${arch}"]`) : null;
      for (const link of downloads.querySelectorAll("[data-arch]")) {
        link.classList.toggle("suggested", link === mine);
        link.querySelector(".mine")?.remove();
      }
      if (!mine) return;
      downloads.prepend(mine);
      const badge = document.createElement("span");
      badge.className = "mine";
      badge.textContent = "This Mac";
      mine.querySelector(".arch").append(badge);
    };
    order();
    addEventListener("hashchange", order);
  }

  const shots = document.querySelector("[data-shots]");
  const control = document.querySelector(".appearance");
  if (shots && control) {
    const dark = matchMedia("(prefers-color-scheme: dark)");
    let chosen = null;
    const show = (mode) => {
      shots.dataset.shots = mode;
      for (const button of control.querySelectorAll("button")) {
        button.setAttribute("aria-pressed", String(button.dataset.appearance === mode));
      }
    };
    show(dark.matches ? "dark" : "light");
    dark.addEventListener("change", (event) => chosen || show(event.matches ? "dark" : "light"));
    control.addEventListener("click", (event) => {
      const button = event.target.closest("button");
      if (button) show((chosen = button.dataset.appearance));
    });
    control.hidden = false;
  }

  for (const pre of document.querySelectorAll("pre[data-copy]")) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "copy";
    button.textContent = "Copy";
    button.setAttribute("aria-live", "polite");
    let timer;
    button.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(pre.querySelector("code").textContent);
        button.textContent = "Copied";
      } catch {
        button.textContent = "Select to copy";
      }
      clearTimeout(timer);
      timer = setTimeout(() => (button.textContent = "Copy"), 1800);
    });
    pre.append(button);
  }

  const links = [...document.querySelectorAll(".toc a")];
  const headings = links.map((a) => document.getElementById(a.hash.slice(1))).filter(Boolean);
  if (headings.length && "IntersectionObserver" in window) {
    const visible = new Set();
    const mark = () => {
      const current = headings.find((h) => visible.has(h)) ||
        [...headings].reverse().find((h) => h.getBoundingClientRect().top < 120);
      for (const a of links) {
        if (current && a.hash === "#" + current.id) a.setAttribute("aria-current", "true");
        else a.removeAttribute("aria-current");
      }
    };
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) entry.isIntersecting ? visible.add(entry.target) : visible.delete(entry.target);
      mark();
    }, { rootMargin: "-52px 0px -60% 0px" });
    headings.forEach((h) => observer.observe(h));
  }
})();
