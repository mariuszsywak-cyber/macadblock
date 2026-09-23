(() => {
  // Dotyczy tylko YouTube: chowa nakładki reklam wideo i klika przycisk „Pomiń reklamę”,
  // gdy YouTube go udostępnia — to ten sam przycisk, który kliknąłby użytkownik ręcznie.
  // Nie ingeruje w odtwarzanie samego materiału. Respektuje globalną pauzę i wyjątki domen,
  // tak samo jak cosmetic.js — bez własnego, osobnego ustawienia po stronie appki.
  const api = globalThis.browser ?? globalThis.chrome;
  const hostname = location.hostname.replace(/^www\./, "").toLowerCase();

  function domainMatches(domain) {
    const normalized = String(domain ?? "").replace(/^\*\.?/, "").toLowerCase();
    return normalized && (hostname === normalized || hostname.endsWith(`.${normalized}`));
  }

  const styleId = "macadblock-youtube-style";
  const adSelectors = [
    ".video-ads", ".ytp-ad-module", ".ytp-ad-overlay-container", ".ytp-ad-overlay-slot",
    "ytd-promoted-sparkles-web-renderer", "ytd-promoted-video-renderer",
    "ytd-display-ad-renderer", "ytd-in-feed-ad-layout-renderer", "ytd-ad-slot-renderer",
    "ytd-banner-promo-renderer", "ytd-statement-banner-renderer", "ytd-mealbar-promo-renderer",
    "masthead-ad", "#masthead-ad", "ytd-companion-slot-renderer", "yt-mealbar-promo-renderer"
  ];
  const skipSelectors = [".ytp-ad-skip-button", ".ytp-skip-ad-button", ".ytp-ad-skip-button-modern"];

  let observer = null;

  function ensureStyle() {
    if (document.getElementById(styleId)) return;
    const style = document.createElement("style");
    style.id = styleId;
    style.textContent = adSelectors.map((selector) => `${selector} { display: none !important; }`).join("\n");
    (document.head || document.documentElement).appendChild(style);
  }

  function removeStyle() {
    document.getElementById(styleId)?.remove();
  }

  function clickSkipButtons() {
    for (const selector of skipSelectors) {
      document.querySelectorAll(selector).forEach((button) => {
        if (button instanceof HTMLElement) button.click();
      });
    }
  }

  function start() {
    if (observer) return;
    ensureStyle();
    clickSkipButtons();
    observer = new MutationObserver(() => clickSkipButtons());
    observer.observe(document.documentElement, { childList: true, subtree: true });
  }

  function stop() {
    observer?.disconnect();
    observer = null;
    removeStyle();
  }

  async function refresh() {
    let active = true;
    try {
      const state = await api.storage.local.get({ pauseUntil: 0, allowlistedDomains: [] });
      active = Number(state.pauseUntil) <= Date.now() && !(state.allowlistedDomains ?? []).some(domainMatches);
    } catch (_) {
      active = true;
    }
    if (active) start(); else stop();
  }

  refresh();
  api.storage?.onChanged?.addListener((changes, area) => {
    if (area !== "local") return;
    if ("pauseUntil" in changes || "allowlistedDomains" in changes) refresh();
  });
})();
