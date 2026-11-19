// Site settings. Edit these two lines when you have them; everything else follows.
window.CHOMP = {
  // The App Store link once the app is live, e.g. "https://apps.apple.com/app/id1234567890".
  // While empty, download buttons say "Coming soon to the App Store".
  appStoreUrl: "",
  // Where people can email you. While empty, the contact page lists the in-app options only.
  contactEmail: "",
};

(function () {
  const cfg = window.CHOMP;

  // Download buttons
  document.querySelectorAll("[data-download]").forEach((el) => {
    // Buttons marked data-short (the header) get a short label so they never wrap.
    const short = el.hasAttribute("data-short");
    if (cfg.appStoreUrl) {
      el.href = cfg.appStoreUrl;
      el.querySelector("[data-download-label]").textContent = short ? "Get Chomp" : "Download on the App Store";
    } else {
      el.removeAttribute("href");
      el.setAttribute("aria-disabled", "true");
      el.querySelector("[data-download-label]").textContent = short ? "Coming soon" : "App Store: coming soon";
    }
  });

  // Contact email
  document.querySelectorAll("[data-email]").forEach((el) => {
    if (cfg.contactEmail) {
      el.hidden = false;
      el.querySelectorAll("a[data-email-link]").forEach((a) => {
        a.href = "mailto:" + cfg.contactEmail + (a.dataset.subject ? "?subject=" + encodeURIComponent(a.dataset.subject) : "");
        if (a.hasAttribute("data-email-text")) a.textContent = cfg.contactEmail;
      });
    }
  });
  document.querySelectorAll("[data-no-email]").forEach((el) => { el.hidden = !!cfg.contactEmail; });

  // Mobile menu
  const toggle = document.querySelector(".nav-toggle");
  if (toggle) toggle.addEventListener("click", () => {
    const open = document.body.classList.toggle("menu-open");
    toggle.setAttribute("aria-expanded", String(open));
  });

  document.querySelectorAll("[data-year]").forEach((el) => { el.textContent = new Date().getFullYear(); });
})();

// Invite and club pages: read the code from ?c=CODE (also accepts ?code= or #CODE).
window.chompInvite = function (kind) {
  const params = new URLSearchParams(location.search);
  const raw = params.get("c") || params.get("code") || location.hash.slice(1) || "";
  const code = raw.toUpperCase().replace(/[^A-Z0-9]/g, "");
  const valid = code.length >= 4 && code.length <= 12;
  document.querySelectorAll("[data-has-code]").forEach((el) => { el.hidden = !valid; });
  document.querySelectorAll("[data-no-code]").forEach((el) => { el.hidden = valid; });
  if (!valid) return;
  document.querySelectorAll("[data-code]").forEach((el) => { el.textContent = code; });
  const open = document.querySelector("[data-open-app]");
  if (open) open.href = "chomp://" + kind + "/" + code;
  const copy = document.querySelector("[data-copy]");
  if (copy) copy.addEventListener("click", async () => {
    try { await navigator.clipboard.writeText(code); copy.textContent = "Copied"; }
    catch { copy.textContent = code; }
    setTimeout(() => { copy.textContent = "Copy code"; }, 2000);
  });
};

// Hero: a runner collects a street of coins (skipped when motion is reduced).
window.chompHero = function (svg) {
  if (!svg) return;
  const path = svg.querySelector("#street");
  const coinsG = svg.querySelector("#coins");
  const runner = svg.querySelector("#runner");
  const len = path.getTotalLength();
  const n = 26, coins = [];
  for (let i = 0; i < n; i++) {
    const p = path.getPointAtLength((i + 0.5) * len / n);
    const c = document.createElementNS("http://www.w3.org/2000/svg", "circle");
    c.setAttribute("cx", p.x); c.setAttribute("cy", p.y); c.setAttribute("r", 7);
    c.setAttribute("class", "coin");
    coinsG.appendChild(c); coins.push({ el: c, at: (i + 0.5) / n });
  }
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const place = (t) => {
    const p = path.getPointAtLength(t * len);
    runner.setAttribute("transform", `translate(${p.x} ${p.y})`);
    coins.forEach((c) => c.el.classList.toggle("got", c.at <= t));
  };
  if (reduce) { place(0.62); return; }
  const dur = 7000, rest = 1400;
  let start = null;
  const frame = (ts) => {
    if (start === null) start = ts;
    const e = (ts - start) % (dur + rest);
    place(Math.min(1, e / dur));
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
};
