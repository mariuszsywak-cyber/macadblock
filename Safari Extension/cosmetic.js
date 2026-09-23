(() => {
  const api = globalThis.browser ?? globalThis.chrome;
  const styleID = "macadblock-cosmetic-style";
  let protectionActive = false;
  let antiAdblockActive = false;
  const hostname = location.hostname.replace(/^www\./, "").toLowerCase();
  const isOnetContext = hostname === "onet.pl" || hostname.endsWith(".onet.pl");
  const antiAdblockText = /(?:wyłącz|wylacz|dezaktywuj|disable|turn off|remove|désactivez|desactivez|deaktivieren|disattiva).{0,100}(?:ad\s*block|blok(?:er|owanie)\s*reklam|werbeblocker|bloqueur\s+de\s+publicit)|(?:ad\s*block|blok(?:er|owanie)\s*reklam|werbeblocker|bloqueur\s+de\s+publicit).{0,100}(?:wykryt|detected|détecté|erkannt|whitelist|białej liście|bialej liscie)/i;
  const builtInSelectors = [
    "iframe[src*='doubleclick.net']",
    "iframe[src*='googlesyndication.com']",
    "iframe[src*='googleadservices.com']",
    "[aria-label*='reklama' i]",
    "[aria-label*='advertisement' i]",
    "[data-testid*='advert' i]",
    "[data-ad-slot]",
    "[class~='advertisement']",
    "[class*='ad-slot' i]",
    "[class*='ad_container' i]",
    "[class*='ad-container' i]",
    "[class*='AdSlotPlaceholder' i]",
    "[data-slotplthr]",
    "[data-slot-container]",
    "[id^='ad-slot' i]",
    "[id^='google_ads' i]"
  ];

  if (isOnetContext) builtInSelectors.push(
    "[class*='AdSlotPlaceholder_placeholder']",
    "iframe[src*='cacheableShow.html' i]",
    "iframe[src*='cacheableShow' i]"
  );

  function installStyle(customSelectors = []) {
    document.getElementById(styleID)?.remove();
    const selectors = [...new Set([...builtInSelectors, ...customSelectors])]
      .filter((selector) => typeof selector === "string" && selector.length < 1000);
    const style = document.createElement("style");
    style.id = styleID;
    style.textContent = `${selectors.join(",\n")} { display: none !important; }`;
    (document.head ?? document.documentElement).appendChild(style);
  }

  function collapseAdvertisementSlot(label) {
    if (label.dataset.macAdBlockHidden) return;
    label.dataset.macAdBlockHidden = "true";
    api.storage.local.get({ blockedAds: 0, savedBytes: 0 }).then((values) => api.storage.local.set({ blockedAds: Number(values.blockedAds) + 1, savedBytes: Number(values.savedBytes) + 120_000 }));
    label.style.setProperty("display", "none", "important");
    let candidate = label;
    for (let depth = 0; depth < 5; depth += 1) {
      const parent = candidate.parentElement;
      if (!parent || parent.matches("body, main, article, [role='main']")) break;
      const remainingText = parent.innerText?.replace(/REKLAMA|ADVERTISEMENT/gi, "").trim();
      if (remainingText) break;
      candidate = parent;
    }
    candidate.style.setProperty("display", "none", "important");
    candidate.style.setProperty("min-height", "0", "important");
    candidate.style.setProperty("height", "0", "important");
    candidate.style.setProperty("margin", "0", "important");
    candidate.style.setProperty("padding", "0", "important");
  }

  function hideAdvertisementLabels(root = document) {
    const elements = [];
    if (root.nodeType === Node.ELEMENT_NODE) elements.push(root);
    elements.push(...(root.querySelectorAll?.("div, aside, section, span, p") ?? []));
    for (const element of elements) {
      if (element.children.length > 2 || element.textContent?.trim().toUpperCase() !== "REKLAMA") continue;
      const slot = element.closest("[data-testid*='advert' i], [class*='advert' i], [class*='ad-slot' i], [id*='advert' i], [id^='ad-' i]");
      if (slot) {
        slot.style.setProperty("display", "none", "important");
      } else {
        collapseAdvertisementSlot(element);
      }
    }
  }

  function hideAntiAdblockMessages(root = document) {
    if (!antiAdblockActive || window.top !== window) return;
    const selectors = "[role='dialog'],[aria-modal='true'],[class*='adblock' i],[id*='adblock' i],[class*='anti-ad' i],[id*='anti-ad' i],[class*='overlay' i],[class*='modal' i],[style*='position: fixed' i]";
    let hidden = 0;
    for (const node of [...(root.querySelectorAll?.(selectors) ?? [])].slice(0, 600)) {
      if (!(node instanceof HTMLElement) || node.dataset.macAdBlockAntiAdblock) continue;
      const text = (node.innerText ?? node.textContent ?? "").replace(/\s+/g, " ").trim().slice(0, 4000);
      if (!antiAdblockText.test(text)) continue;
      node.dataset.macAdBlockAntiAdblock = "true";
      node.style.setProperty("display", "none", "important");
      node.style.setProperty("pointer-events", "none", "important");
      hidden += 1;
    }
    if (!hidden) return;
    for (const element of [document.documentElement, document.body]) {
      if (!element) continue;
      element.style.removeProperty("overflow");
      element.style.removeProperty("position");
      for (const name of [...element.classList]) if (/(?:adblock|modal-open|no-scroll|noscroll|overflow-hidden)/i.test(name)) element.classList.remove(name);
    }
    api.storage.local.get({ antiAdblockBypasses: 0 }).then((state) => api.storage.local.set({ antiAdblockBypasses: Number(state.antiAdblockBypasses) + hidden }));
  }

  api.storage.local.get({ customSelectors: [], customSelectorsByDomain: {}, allowlistedDomains: [], pauseUntil: 0, antiAdblockEnabled: true, antiAdblockDisabledDomains: [] }).then(({ customSelectors, customSelectorsByDomain, allowlistedDomains, pauseUntil, antiAdblockEnabled, antiAdblockDisabledDomains }) => {
    const domain = hostname;
    protectionActive = Number(pauseUntil) <= Date.now() && !allowlistedDomains.includes(domain);
    antiAdblockActive = protectionActive && antiAdblockEnabled && !antiAdblockDisabledDomains.includes(domain);
    if (antiAdblockActive) api.runtime.sendMessage({ command: "install-anti-adblock" }).catch(() => {});
    if (protectionActive) { installStyle([...customSelectors, ...(customSelectorsByDomain[domain] ?? [])]); hideAdvertisementLabels(); hideAntiAdblockMessages(); }
  });

  api.storage.onChanged.addListener((changes, area) => {
    if (area === "local" && protectionActive && (changes.customSelectors || changes.customSelectorsByDomain)) location.reload();
  });

  const observer = new MutationObserver((records) => {
    for (const record of records) {
      for (const node of record.addedNodes) {
        if (protectionActive && node.nodeType === Node.ELEMENT_NODE) { hideAdvertisementLabels(node); hideAntiAdblockMessages(node); }
      }
    }
  });
  observer.observe(document.documentElement, { childList: true, subtree: true });
})();
