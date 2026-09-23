(() => {
  const api = globalThis.browser ?? globalThis.chrome;
  const stylePrefix = "macadblock-cosmetic-style";
  const hostname = location.hostname.replace(/^www\./, "").toLowerCase();
  const isOnetContext = hostname === "onet.pl" || hostname.endsWith(".onet.pl") || /(^|\.)onet\.pl$/i.test((() => {
    try { return new URL(document.referrer).hostname; } catch (_) { return ""; }
  })());
  let protectionActive = false;
  let antiAdblockActive = false;
  let proceduralRules = [];
  let scanPending = false;

  const builtInSelectors = [
    "iframe[src*='doubleclick.net']", "iframe[src*='googlesyndication.com']",
    "iframe[src*='googleadservices.com']", "[aria-label*='reklama' i]",
    "[aria-label*='advertisement' i]", "[data-testid*='advert' i]", "[data-ad-slot]",
    "[data-ad-unit]", "[data-advertisement]", "ins.adsbygoogle", "[id^='div-gpt-ad']",
    "[class*='adform-adbox' i]", "[class*='advertWrapper' i]", "[class*='sponsored-slot' i]",
    "[class~='advertisement']", "[class*='ad-slot' i]", "[class*='ad_container' i]",
    "[class*='ad-container' i]", "[class*='AdSlotPlaceholder' i]", "[data-slotplthr]",
    "[data-slot-container]", "[id^='ad-slot' i]", "[id^='google_ads' i]"
  ];

  const onetSelectors = [
    "[data-slotplthr]",
    "[class*='AdSlotPlaceholder_placeholder']",
    "iframe[src*='cacheableShow.html' i]",
    "iframe[src*='cacheableShow' i]"
  ];

  const antiAdblockText = /(?:wyłącz|wylacz|dezaktywuj|disable|turn off|désactivez|desactivez|deaktivieren|disattiva).{0,160}(?:ad\s*block|blok(?:er|owanie)\s*reklam|werbeblocker|bloqueur\s+de\s+publicit)|(?:ad\s*block|blok(?:er|owanie)\s*reklam|werbeblocker|bloqueur\s+de\s+publicit).{0,160}(?:wykryt|detected|détecté|erkannt|whitelist|białej liście|bialej liscie)|ads?\s*1\s*hour|close\s+and\s+reload|you\s+may\s+see\s+a\s+short\s+ad\s+or\s+video/i;
  const antiAdblockSelector = [
    "[role='dialog']", "[aria-modal='true']", "[class*='adblock' i]", "[id*='adblock' i]",
    "[class*='anti-ad' i]", "[id*='anti-ad' i]", "[class*='ads1hour' i]", "[id*='ads1hour' i]",
    "[class*='overlay' i]", "[class*='modal' i]", "[class*='backdrop' i]"
  ].join(",");

  function domainMatches(domain) {
    const normalized = String(domain ?? "").replace(/^\*\.?/, "").toLowerCase();
    return normalized && (hostname === normalized || hostname.endsWith(`.${normalized}`));
  }

  function ruleApplies(rule) {
    if (rule.excludedDomains?.some(domainMatches)) return false;
    return !rule.includedDomains?.length || rule.includedDomains.some(domainMatches);
  }

  function scriptletKey(item) {
    return [item?.name, ...(item?.arguments ?? [])].join("\u0000");
  }

  // Scriptlety wykonuje serwis w tle, bo treść strony ma własny kontekst JavaScript.
  // Reguła wyjątku `#@%#` o tej samej nazwie i argumentach wyłącza odpowiadający jej scriptlet.
  async function requestScriptlets(list, globallyExempt) {
    if (!Array.isArray(list) || list.length === 0 || globallyExempt) return;
    const applicable = list.filter(ruleApplies);
    const exceptions = new Set(applicable.filter((item) => item.isException).map(scriptletKey));
    const active = applicable.filter((item) => !item.isException && !exceptions.has(scriptletKey(item)));
    if (active.length === 0) return;
    try { await api.runtime.sendMessage({ command: "scriptlets", scriptlets: active.slice(0, 100) }); } catch (_) {}
  }

  function query(selector, root = document) {
    try { return [...root.querySelectorAll(selector)]; } catch (_) { return []; }
  }

  // Selektor trafia do arkusza <style>. Nawiasy klamrowe lub komentarz pozwoliłyby skompromitowanej liście
  // wstrzyknąć dowolny CSS (np. url(...) do wycieku danych), więc takie selektory są odrzucane.
  function isSafeSelector(selector) {
    return typeof selector === "string" && selector.length > 0 && selector.length <= 8_000 && !/[{}]|\/\*/.test(selector);
  }

  const appliedStyles = new WeakMap();
  let pendingBlockedAds = 0;
  let blockedAdsFlushTimer = 0;

  // Liczniki zapisujemy zbiorczo, żeby równoległe ramki nie nadpisywały sobie wyników.
  function recordBlockedAds(count = 1) {
    pendingBlockedAds += count;
    if (blockedAdsFlushTimer) return;
    blockedAdsFlushTimer = setTimeout(async () => {
      const added = pendingBlockedAds;
      pendingBlockedAds = 0;
      blockedAdsFlushTimer = 0;
      try {
        const values = await api.storage.local.get({ blockedAds: 0 });
        await api.storage.local.set({ blockedAds: Number(values.blockedAds) + added });
      } catch (_) {}
    }, 2_000);
  }

  function safeStyle(style) {
    if (typeof style !== "string" || style.length > 2_000) return null;
    if (/url\s*\(|image-set\s*\(|@import|expression\s*\(|javascript:|\/\*|\/\//i.test(style)) return null;
    return style;
  }

  function installStyles(selectors, styleRules) {
    document.querySelectorAll(`[id^='${stylePrefix}']`).forEach((node) => node.remove());
    const declarations = [
      ...selectors.map((selector) => `${selector}{display:none!important;}`),
      ...styleRules.map((rule) => `${rule.selector}{${rule.argument}}`)
    ];
    let chunk = "";
    let index = 0;
    for (const declaration of declarations) {
      if (chunk.length + declaration.length > 500_000) {
        appendStyle(chunk, index++);
        chunk = "";
      }
      chunk += `${declaration}\n`;
    }
    if (chunk) appendStyle(chunk, index);
  }

  function appendStyle(text, index) {
    const style = document.createElement("style");
    style.id = `${stylePrefix}-${index}`;
    style.textContent = text;
    (document.head ?? document.documentElement).appendChild(style);
  }

  function parseText(value) {
    const trimmed = value.trim();
    if (trimmed.startsWith("/") && trimmed.lastIndexOf("/") > 0) {
      const end = trimmed.lastIndexOf("/");
      try { return new RegExp(trimmed.slice(1, end), trimmed.slice(end + 1)); } catch (_) { return null; }
    }
    return trimmed.replace(/^['"]|['"]$/g, "");
  }

  function proceduralMatches(selector) {
    const pathMatch = selector.match(/^(.*):matches-path\((.*?)\)$/s);
    if (pathMatch) {
      const matcher = parseText(pathMatch[2]);
      const matches = matcher instanceof RegExp ? matcher.test(location.pathname) : location.pathname.includes(matcher ?? "");
      return matches ? query(pathMatch[1] || "*") : [];
    }

    const minimumTextMatch = selector.match(/^(.*):min-text-length\((\d+)\)$/s);
    if (minimumTextMatch) {
      const minimum = Math.min(Number(minimumTextMatch[2]), 100_000);
      return query(minimumTextMatch[1] || "*").filter((node) => (node.textContent ?? "").trim().length >= minimum);
    }

    const cssMatch = selector.match(/^(.*):matches-css\(([^:]+):(.*)\)$/s);
    if (cssMatch) {
      const property = cssMatch[2].trim();
      const matcher = parseText(cssMatch[3]);
      return query(cssMatch[1] || "*").filter((node) => {
        const value = getComputedStyle(node).getPropertyValue(property).trim();
        return matcher instanceof RegExp ? matcher.test(value) : value.includes(matcher ?? "");
      });
    }

    const xpath = selector.match(/^:xpath\((.*)\)$/s);
    if (xpath) {
      try {
        const result = document.evaluate(xpath[1], document, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
        return Array.from({ length: result.snapshotLength }, (_, index) => result.snapshotItem(index)).filter(Boolean);
      } catch (_) { return []; }
    }

    const textMatch = selector.match(/^(.*?):(?:has-text|contains)\((.*?)\)(.*)$/s);
    if (textMatch) {
      const matcher = parseText(textMatch[2]);
      return query(textMatch[1] || "*").filter((node) => matcher instanceof RegExp ? matcher.test(node.textContent ?? "") : (node.textContent ?? "").includes(matcher ?? ""));
    }

    const attrMatch = selector.match(/^(.*?):matches-attr\(([^=)]+)(?:=(.*))?\)$/s);
    if (attrMatch) {
      const base = attrMatch[1] || "*";
      const name = attrMatch[2].trim();
      const matcher = attrMatch[3] ? parseText(attrMatch[3]) : null;
      return query(`${base}[${CSS.escape(name)}]`).filter((node) => {
        const value = node.getAttribute(name) ?? "";
        return !matcher || (matcher instanceof RegExp ? matcher.test(value) : value.includes(matcher));
      });
    }

    const upwardMatch = selector.match(/^(.*):upward\(([^)]+)\)$/s);
    if (upwardMatch) {
      const amount = Number(upwardMatch[2]);
      return query(upwardMatch[1]).map((node) => {
        if (Number.isInteger(amount) && amount > 0 && amount < 20) {
          for (let index = 0; index < amount && node; index += 1) node = node.parentElement;
          return node;
        }
        try { return node.closest(upwardMatch[2]); } catch (_) { return null; }
      }).filter(Boolean);
    }
    return query(selector);
  }

  function applyProceduralRule(rule) {
    let selector = rule.selector;
    let operation = rule.action;
    let argument = rule.argument;
    const operator = selector.match(/^(.*):(remove-attr|remove-class)\(([^)]+)\)$/s);
    if (operator) {
      selector = operator[1];
      operation = operator[2];
      argument = operator[3].replace(/^['"]|['"]$/g, "");
    }
    for (const node of proceduralMatches(selector)) {
      if (!(node instanceof Element)) continue;
      if (operation === "remove") node.remove();
      else if (operation === "remove-attr") node.removeAttribute(argument);
      else if (operation === "remove-class") node.classList.remove(argument);
      else if (operation === "style") {
        // Każdy styl nakładamy na element tylko raz — ponowne dopisywanie wywoływałoby kolejne mutacje DOM i skany.
        if (!safeStyle(argument)) continue;
        const applied = appliedStyles.get(node) ?? new Set();
        if (applied.has(argument)) continue;
        applied.add(argument);
        appliedStyles.set(node, applied);
        node.style.cssText += `;${argument}`;
      } else if (node.style.getPropertyValue("display") !== "none") {
        node.style.setProperty("display", "none", "important");
      }
    }
  }

  function collapseAdvertisementSlot(label) {
    if (label.dataset.macAdBlockHidden) return;
    label.dataset.macAdBlockHidden = "true";
    recordBlockedAds(1);
    let candidate = label;
    for (let depth = 0; depth < 6; depth += 1) {
      const parent = candidate.parentElement;
      if (!parent || parent.matches("body, main, article, [role='main']")) break;
      const remainingText = parent.innerText?.replace(/REKLAMA|ADVERTISEMENT|SPONSORED/gi, "").trim();
      if (remainingText || parent.querySelector("article, main, nav")) break;
      candidate = parent;
    }
    candidate.style.setProperty("display", "none", "important");
    for (const property of ["min-height", "height", "margin", "padding"]) candidate.style.setProperty(property, "0", "important");
  }

  function hideAdvertisementLabels(root = document) {
    const elements = root.nodeType === Node.ELEMENT_NODE ? [root, ...query("div, aside, section, span, p", root)] : query("div, aside, section, span, p", root);
    for (const element of elements) {
      if (element.children.length > 2 || !/^(REKLAMA|ADVERTISEMENT|SPONSORED)$/i.test(element.textContent?.trim() ?? "")) continue;
      const slot = element.closest("[data-testid*='advert' i], [class*='advert' i], [class*='ad-slot' i], [class*='AdSlotPlaceholder' i], [id*='advert' i], [id^='ad-' i]");
      if (slot) slot.style.setProperty("display", "none", "important"); else collapseAdvertisementSlot(element);
    }
  }

  function collapseEmptyAdvertisementSlots(root = document) {
    const selectors = [
      "[data-ad-slot]", "[data-ad-unit]", "[data-advertisement]", "[data-slotplthr]",
      "[id^='div-gpt-ad']", "[id^='google_ads']", "[id^='ad-slot' i]",
      "[class*='AdSlotPlaceholder' i]", "[class*='ad-slot' i]", "[class*='ad_container' i]",
      "[class*='ad-container' i]", "[class*='advertWrapper' i]"
    ];
    for (const slot of query(selectors.join(","), root)) {
      if (!(slot instanceof HTMLElement) || slot.dataset.macAdBlockCollapsed) continue;
      const visibleContent = slot.querySelector("img[src], video, article, main, nav, a[href]:not([href=''])");
      const meaningfulText = (slot.innerText ?? "").replace(/REKLAMA|ADVERTISEMENT|SPONSORED/gi, "").trim();
      if (visibleContent || meaningfulText.length > 12) continue;
      slot.dataset.macAdBlockCollapsed = "true";
      slot.style.setProperty("display", "none", "important");
      for (const property of ["min-height", "height", "max-height", "margin", "padding"]) slot.style.setProperty(property, "0", "important");
    }
  }

  function collapseOnetAdvertisements(root = document) {
    if (!isOnetContext) return;

    for (const slot of query(onetSelectors.join(","), root)) {
      if (!(slot instanceof HTMLElement) || slot.dataset.macAdBlockCollapsed) continue;
      slot.dataset.macAdBlockCollapsed = "true";
      slot.style.setProperty("display", "none", "important");
      for (const property of ["min-height", "height", "max-height", "margin", "padding"]) slot.style.setProperty(property, "0", "important");
    }

    const selfPromotion = document.querySelector("#template-container .autopromo-label, #template-container .maintenance-modal");
    if (selfPromotion && !document.documentElement.dataset.macAdBlockCollapsed) {
      document.documentElement.dataset.macAdBlockCollapsed = "true";
      document.documentElement.style.setProperty("display", "none", "important");
    }
  }

  function restorePageInteraction() {
    for (const element of [document.documentElement, document.body]) {
      if (!element) continue;
      for (const property of ["overflow", "overflow-y", "position", "padding-right", "pointer-events", "filter", "backdrop-filter"]) {
        element.style.removeProperty(property);
      }
      element.removeAttribute("inert");
      if (element.getAttribute("aria-hidden") === "true") element.removeAttribute("aria-hidden");
      for (const name of [...element.classList]) {
        if (/(?:adblock|modal-open|no-scroll|noscroll|overflow-hidden)/i.test(name)) element.classList.remove(name);
      }
    }
  }

  function normalizedText(element) {
    return (element.innerText ?? element.textContent ?? "").replace(/\s+/g, " ").trim().slice(0, 6_000);
  }

  function isLargeFixedLayer(element) {
    const style = getComputedStyle(element);
    if (!["fixed", "sticky", "absolute"].includes(style.position)) return false;
    const rect = element.getBoundingClientRect();
    const zIndex = Number.parseInt(style.zIndex, 10);
    return rect.width >= innerWidth * 0.28
      && rect.height >= innerHeight * 0.18
      && (!Number.isFinite(zIndex) || zIndex >= 10);
  }

  function modalContainerFor(element) {
    let current = element;
    let fixedCandidate = null;
    for (let depth = 0; current && depth < 10; depth += 1) {
      if (current.matches(antiAdblockSelector)) return current;
      if (!fixedCandidate && isLargeFixedLayer(current)) fixedCandidate = current;
      if (current.parentElement?.matches("html, body")) break;
      current = current.parentElement;
    }
    return fixedCandidate ?? element;
  }

  function hideBlockingLayers(candidate) {
    const layers = query(`${antiAdblockSelector}, body > div, body > iframe`).slice(0, 800);
    for (const layer of layers) {
      if (!(layer instanceof HTMLElement) || layer === candidate || candidate.contains(layer)) continue;
      const style = getComputedStyle(layer);
      const rect = layer.getBoundingClientRect();
      const coversViewport = ["fixed", "sticky"].includes(style.position)
        && rect.width >= innerWidth * 0.65
        && rect.height >= innerHeight * 0.65;
      const related = layer.contains(candidate)
        || /(?:backdrop|overlay|adblock|ads1hour|modal)/i.test(`${layer.id} ${layer.className}`)
        || antiAdblockText.test(normalizedText(layer));
      if (!coversViewport || !related) continue;
      layer.dataset.macAdBlockAntiAdblock = "true";
      layer.style.setProperty("display", "none", "important");
      layer.style.setProperty("pointer-events", "none", "important");
    }
  }

  function hideAntiAdblockMessages(root = document) {
    if (!antiAdblockActive) return;
    const directCandidates = query(antiAdblockSelector, root);
    const textCandidates = query("body *", root)
      .filter((element) => element instanceof HTMLElement && element.childElementCount <= 12 && antiAdblockText.test(normalizedText(element)))
      .slice(0, 600);
    let hidden = 0;
    for (const node of [...new Set([...directCandidates, ...textCandidates])].slice(0, 900)) {
      if (!(node instanceof HTMLElement) || node.dataset.macAdBlockAntiAdblock) continue;
      const text = normalizedText(node);
      if (!antiAdblockText.test(text)) continue;
      const candidate = modalContainerFor(node);
      if (!(candidate instanceof HTMLElement) || candidate.matches("html, body")) continue;
      candidate.dataset.macAdBlockAntiAdblock = "true";
      candidate.style.setProperty("display", "none", "important");
      candidate.style.setProperty("pointer-events", "none", "important");
      hidden += 1;
      hideBlockingLayers(candidate);
    }
    if (!hidden) return;
    restorePageInteraction();
    api.storage.local.get({ antiAdblockBypasses: 0 }).then((state) => api.storage.local.set({ antiAdblockBypasses: Number(state.antiAdblockBypasses) + hidden }));
    if (window.top !== window) {
      try { window.top.postMessage({ type: "macadblock-anti-adblock-hidden" }, "*"); } catch (_) {}
    }
  }

  let lastHeavyScan = 0;
  let heavyScanTimer = 0;

  // Skanowanie całego DOM (etykiety reklam, komunikaty anty-adblock, reguły proceduralne) jest kosztowne,
  // więc wykonujemy je najwyżej raz na 750 ms, niezależnie od liczby mutacji strony.
  function runHeavyScan() {
    lastHeavyScan = performance.now();
    hideAntiAdblockMessages();
    hideAdvertisementLabels();
    for (const rule of proceduralRules) applyProceduralRule(rule);
  }

  function scheduleScan() {
    if (!protectionActive || scanPending) return;
    scanPending = true;
    requestAnimationFrame(() => {
      scanPending = false;
      if (!protectionActive) return;
      collapseOnetAdvertisements();
      collapseEmptyAdvertisementSlots();
      const wait = 750 - (performance.now() - lastHeavyScan);
      if (wait <= 0) {
        runHeavyScan();
      } else if (!heavyScanTimer) {
        heavyScanTimer = setTimeout(() => {
          heavyScanTimer = 0;
          if (protectionActive) runHeavyScan();
        }, wait);
      }
    });
  }


  function siteOfHost(host) {
    return String(host).split(".").slice(-2).join(".");
  }

  function isCrossSiteHref(url) {
    try { return siteOfHost(new URL(url, location.href).hostname) !== siteOfHost(location.hostname); } catch (_) { return false; }
  }

  function looksLikeClickCatcher(element) {
    if (!(element instanceof HTMLElement)) return false;
    const style = getComputedStyle(element);
    const rect = element.getBoundingClientRect();
    if (rect.width < 24 || rect.height < 24) return false;
    const opacity = Number.parseFloat(style.opacity);
    const invisible = (Number.isFinite(opacity) && opacity <= 0.05) || style.visibility === "hidden";
    const textless = (element.innerText ?? "").trim().length === 0 && element.children.length === 0;
    return invisible || textless;
  }

  // Wiele stron (torrenty, streamingi) kładzie niewidoczny link reklamowy na kategorii/przycisku:
  // klik trafia w niego, otwiera reklamę w nowej karcie, a prawdziwy link pod spodem i tak nawiguje.
  // Wykrywamy taki "click catcher" przez elementsFromPoint i klikamy zamiast niego prawdziwy element.
  function installClickHijackGuard() {
    document.addEventListener("click", (event) => {
      if (!protectionActive || !event.isTrusted || event.defaultPrevented) return;
      if (typeof document.elementsFromPoint !== "function") return;
      const stack = document.elementsFromPoint(event.clientX, event.clientY);
      const topIndex = stack.findIndex((node) => node instanceof HTMLAnchorElement && node.href);
      if (topIndex === -1) return;
      const overlay = stack[topIndex];
      const opensNewTab = overlay.target && overlay.target !== "_self";
      if (!opensNewTab || !isCrossSiteHref(overlay.href) || !looksLikeClickCatcher(overlay)) return;
      const real = stack.slice(topIndex + 1).find((node) =>
        node instanceof Element && node.closest("a[href], button, [role='button']")
      );
      if (!real) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      const target = real.closest("a[href], button, [role='button']");
      if (target instanceof HTMLElement) target.click();
    }, true);
  }

  let startGeneration = 0;

  async function start() {
    const generation = ++startGeneration;
    const state = await api.storage.local.get({ customSelectors: [], customSelectorsByDomain: {}, allowlistedDomains: [], pauseUntil: 0, compiledCosmeticRules: null, antiAdblockEnabled: true, antiAdblockDisabledDomains: [] });
    if (generation !== startGeneration) return;
    protectionActive = Number(state.pauseUntil) <= Date.now() && !state.allowlistedDomains.some(domainMatches);
    if (!protectionActive) return;
    try { api.runtime.sendMessage({ command: "install-popup-guard" }); } catch (_) {}
    antiAdblockActive = state.antiAdblockEnabled && !state.antiAdblockDisabledDomains.some(domainMatches);
    if (antiAdblockActive) {
      try { await api.runtime.sendMessage({ command: "install-anti-adblock" }); } catch (_) {}
    }
    let payload = state.compiledCosmeticRules;
    if (!payload) {
      try { payload = await api.runtime.sendMessage({ command: "cosmetic-rules" }); } catch (_) {}
    }
    if (generation !== startGeneration) return;
    payload ??= { rules: [], exemptDomains: [] };
    const globallyExempt = payload.exemptDomains?.some(domainMatches);
    requestScriptlets(payload.scriptlets ?? [], globallyExempt);
    const applicable = (payload.rules ?? []).filter(ruleApplies);
    const exceptions = new Set(applicable.filter((rule) => rule.isException).map((rule) => rule.selector));
    const active = applicable.filter((rule) => !rule.isException && !exceptions.has(rule.selector) && (!globallyExempt || rule.includedDomains?.length));
    const hideSelectors = active.filter((rule) => rule.action === "hide" && isSafeSelector(rule.selector)).map((rule) => rule.selector);
    const styleRules = active.filter((rule) => rule.action === "style" && isSafeSelector(rule.selector) && safeStyle(rule.argument)).map((rule) => ({ selector: rule.selector, argument: safeStyle(rule.argument) }));
    proceduralRules = active.filter((rule) => ["remove", "procedural"].includes(rule.action));
    const custom = [...state.customSelectors, ...(state.customSelectorsByDomain[hostname] ?? [])].filter(isSafeSelector);
    const platformSelectors = isOnetContext ? [...builtInSelectors, ...onetSelectors] : builtInSelectors;
    installStyles([...new Set([...platformSelectors, ...hideSelectors, ...custom])].slice(0, 25_000), styleRules.slice(0, 5_000));
    scheduleScan();
  }

  // Zmiana ustawień lub reguł stosowana jest na żywo, bez przeładowywania kart i ramek
  // (przeładowanie gubiłoby wpisany tekst, odtwarzane wideo i stan stron).
  let restartTimer = 0;
  function restart() {
    document.querySelectorAll(`[id^='${stylePrefix}']`).forEach((node) => node.remove());
    protectionActive = false;
    antiAdblockActive = false;
    proceduralRules = [];
    start();
  }

  api.storage.onChanged.addListener((changes, area) => {
    if (area !== "local") return;
    if (!(changes.customSelectors || changes.customSelectorsByDomain || changes.compiledCosmeticRules || changes.allowlistedDomains || changes.pauseUntil || changes.antiAdblockEnabled || changes.antiAdblockDisabledDomains)) return;
    clearTimeout(restartTimer);
    restartTimer = setTimeout(restart, 300);
  });
  if (window.top === window) {
    window.addEventListener("message", (event) => {
      if (!antiAdblockActive || event.data?.type !== "macadblock-anti-adblock-hidden") return;
      const frame = query("iframe").find((item) => item.contentWindow === event.source);
      if (frame instanceof HTMLElement && isLargeFixedLayer(frame)) {
        frame.style.setProperty("display", "none", "important");
        hideBlockingLayers(frame);
        restorePageInteraction();
      }
    });
  }
  const observeMutations = () => {
    if (!document.documentElement) return;
    new MutationObserver(scheduleScan).observe(document.documentElement, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ["class", "style", "src", "data-slotplthr", "aria-modal"]
    });
  };
  installClickHijackGuard();
  if (document.documentElement) observeMutations();
  else document.addEventListener("readystatechange", observeMutations, { once: true });
  start();
})();
