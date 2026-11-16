// SameKeys website. Everything here is an enhancement: without it the page
// still reads, and the download buttons still lead to the Releases page.

// The download buttons, at the top and in the Download section: straight to
// the latest release's disk image (SK-304), with its version under the lower
// one, once there is a release; until then, a note that none exists yet.
(async () => {
  const buttons = document.querySelectorAll("[data-download]");
  const status = document.querySelector("[data-release-status]");
  if (!buttons.length || !status) return;
  try {
    const response = await fetch("https://api.github.com/repos/lynnjeans/samekeys/releases/latest", {
      headers: { Accept: "application/vnd.github+json" },
    });
    if (response.status === 404) {
      status.textContent = status.dataset.none;
      return;
    }
    if (!response.ok) return;
    const release = await response.json();
    const dmg = (release.assets || []).find((asset) => asset.name.endsWith(".dmg"));
    if (!dmg) return;
    buttons.forEach((button) => { button.href = dmg.browser_download_url; });
    const version = release.tag_name.replace(/^v/, "");
    status.textContent = status.dataset.version.replace("{version}", version);
  } catch {
    // Offline or rate-limited: the Releases page link stays.
  }
})();

// A one-line offer of the reader's own language, never a redirect: search
// engines and people who chose this page keep it.
(() => {
  // Relative, so a local copy works too; <html data-root> leads to the site's root.
  const root = document.documentElement.dataset.root || "./";
  const pages = { en: root, "zh-Hans": root + "zh-hans/", ja: root + "ja/" };
  const offers = {
    en: "This page is also available in English.",
    "zh-Hans": "本页有简体中文版。",
    ja: "このページは日本語でもご覧いただけます。",
  };
  const close = { en: "Close", "zh-Hans": "关闭", ja: "閉じる" };
  const current = document.documentElement.lang;
  const key = "samekeys.languageOffer";
  let dismissed = false;
  try { dismissed = localStorage.getItem(key) === "dismissed"; } catch {}
  if (dismissed) return;

  const wanted = (navigator.languages || [navigator.language]).map((tag) => {
    const lower = tag.toLowerCase();
    if (lower.startsWith("zh")) return "zh-Hans";
    if (lower.startsWith("ja")) return "ja";
    if (lower.startsWith("en")) return "en";
    return null;
  }).find(Boolean);
  if (!wanted || wanted === current) return;

  const bar = document.createElement("div");
  bar.className = "suggest";
  bar.lang = wanted;
  bar.innerHTML = `<div class="wrap"><a href="${pages[wanted]}" hreflang="${wanted}">${offers[wanted]} →</a>
    <button type="button" aria-label="${close[wanted]}">×</button></div>`;
  bar.querySelector("button").addEventListener("click", () => {
    bar.remove();
    try { localStorage.setItem(key, "dismissed"); } catch {}
  });
  document.querySelector(".site-header").after(bar);
})();
