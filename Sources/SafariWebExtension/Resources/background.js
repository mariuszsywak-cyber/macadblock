const api = globalThis.browser ?? globalThis.chrome;
const FALLBACK_DYNAMIC_LIMIT = 30_000;
const ALLOW_RULE_ID = 1_500_000;

function installAntiAdblockPageGuards() {
  if (globalThis.__macAdBlockAntiAdblockInstalled) return;
  Object.defineProperty(globalThis, "__macAdBlockAntiAdblockInstalled", { value: true });

  const detector = {
    onDetected() { return this; },
    onNotDetected(callback) {
      if (typeof callback === "function") queueMicrotask(callback);
      return this;
    },
    check() { return false; },
    clearEvent() { return this; },
    emitEvent() { return this; },
    setOption() { return this; }
  };

  for (const name of ["blockAdBlock", "BlockAdBlock", "fuckAdBlock", "FuckAdBlock"]) {
    try {
      Object.defineProperty(globalThis, name, {
        configurable: true,
        get: () => detector,
        set: () => {}
      });
    } catch (_) {
      try { globalThis[name] = detector; } catch (_) {}
    }
  }

  for (const [name, value] of [["canRunAds", true], ["isAdBlockActive", false], ["adblockDetected", false]]) {
    if (name in globalThis) continue;
    try { Object.defineProperty(globalThis, name, { configurable: true, writable: true, value }); } catch (_) {}
  }

  const installBait = () => {
    if (!document.documentElement || document.querySelector("[data-macadblock-bait]")) return;
    const bait = document.createElement("div");
    bait.dataset.macadblockBait = "true";
    bait.className = "adsbox ad-banner ad-placement doubleclick advertisement";
    bait.setAttribute("aria-hidden", "true");
    bait.style.cssText = "display:block!important;visibility:visible!important;position:absolute!important;left:-10000px!important;top:-10000px!important;width:2px!important;height:2px!important;min-width:2px!important;min-height:2px!important;opacity:.01!important;pointer-events:none!important";
    document.documentElement.appendChild(bait);
  };
  installBait();
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", installBait, { once: true });
}

async function installAntiAdblock(sender) {
  const tabId = sender?.tab?.id;
  if (!Number.isInteger(tabId)) return false;
  const target = { tabId };
  if (Number.isInteger(sender.frameId)) target.frameIds = [sender.frameId];
  try {
    await api.scripting.executeScript({ target, world: "MAIN", func: installAntiAdblockPageGuards });
    return true;
  } catch (_) {
    return false;
  }
}

function installPopupGuard() {
  if (globalThis.__macAdBlockPopupGuard) return;
  Object.defineProperty(globalThis, "__macAdBlockPopupGuard", { value: true });

  const site = (host) => String(host).split(".").slice(-2).join(".");
  const isSameSite = (url) => {
    if (!url || /^\s*about:/i.test(String(url))) return false;
    try { return site(new URL(url, location.href).hostname) === site(location.hostname); } catch (_) { return false; }
  };

  // Reklamy-popundery (np. na stronach torrentowych) odpalają window.open z DOWOLNEGO kliknięcia w stronę —
  // także w prawdziwy, zamierzony przez użytkownika link. Zwykłego kliknięcia nie da się więc odróżnić od
  // sygnału reklamy po samym fakcie, że był "prawdziwy". Dlatego okno do innej domeny puszczamy tylko wtedy,
  // gdy użytkownik jawnie poprosił o nową kartę: Cmd/Ctrl/Shift+klik albo środkowy przycisk myszy.
  let explicitGestureUntil = 0;
  const markIfExplicit = (event) => {
    if (!event.isTrusted) return;
    if (event.button === 1 || event.ctrlKey || event.metaKey || event.shiftKey) explicitGestureUntil = Date.now() + 1000;
  };
  addEventListener("mousedown", markIfExplicit, true);
  addEventListener("auxclick", markIfExplicit, true);
  addEventListener("click", markIfExplicit, true);

  const originalOpen = globalThis.open;
  if (typeof originalOpen === "function") {
    globalThis.open = function (url, ...rest) {
      // Adresy spoza http/https (magnet:, mailto:, tel:...) nie otwierają nowej karty przeglądarki —
      // przekazujemy je zawsze, np. magnesowe linki torrentów mają działać bez specjalnego gestu.
      if (url && !/^\s*https?:/i.test(String(url))) return originalOpen.apply(this, [url, ...rest]);
      const explicit = Date.now() < explicitGestureUntil;
      if (!explicit && !isSameSite(url)) return null;
      return originalOpen.apply(this, [url, ...rest]);
    };
  }

  // Skrypty popunderów potrafią programowo "kliknąć" link do innej domeny (widoczny albo nie) zamiast wywoływać
  // window.open wprost — żadna strona nie potrzebuje robić tego skryptem, więc blokujemy to bezwarunkowo.
  const originalClick = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function () {
    if (this.target && this.target !== "_self" && !isSameSite(this.href)) return;
    return originalClick.call(this);
  };
  addEventListener("click", (event) => {
    if (event.isTrusted) return;
    const link = event.target instanceof Element ? event.target.closest("a[href]") : null;
    if (link && link.target && link.target !== "_self" && !isSameSite(link.href)) event.preventDefault();
  }, true);
}

async function installPopupGuardFor(sender) {
  const tabId = sender?.tab?.id;
  if (!Number.isInteger(tabId)) return false;
  const target = { tabId };
  if (Number.isInteger(sender.frameId)) target.frameIds = [sender.frameId];
  try {
    await api.scripting.executeScript({ target, world: "MAIN", func: installPopupGuard });
    return true;
  } catch (_) {
    return false;
  }
}

function allowRulesFor(domains) {
  return domains.flatMap((domain, index) => [
    {
      id: ALLOW_RULE_ID + index * 2,
      priority: 1_000_000,
      action: { type: "allowAllRequests" },
      condition: { urlFilter: `||${domain}^`, resourceTypes: ["main_frame"] }
    },
    {
      id: ALLOW_RULE_ID + index * 2 + 1,
      priority: 1_000_000,
      action: { type: "allow" },
      condition: {
        initiatorDomains: [domain],
        resourceTypes: ["sub_frame", "stylesheet", "script", "image", "font", "object", "xmlhttprequest", "ping", "media", "websocket", "other"]
      }
    }
  ]);
}

// Biblioteka scriptletów wykonywana w kontekście strony (świat MAIN). Nazwy muszą odpowiadać
// `ScriptletInvocation.supportedNames` w Swift. Argumenty są wyłącznie danymi — nic nie jest
// wykonywane jako kod z listy filtrów, więc uszkodzona lista nie uruchomi dowolnego skryptu.
function macAdBlockScriptletRunner(invocations) {
  const state = globalThis.__macAdBlockScriptlets ?? (globalThis.__macAdBlockScriptlets = { applied: new Set() });

  const literal = (raw) => {
    switch (raw) {
      case "true": return true;
      case "false": return false;
      case "null": return null;
      case "undefined": return undefined;
      case "noopFunc": return function () {};
      case "trueFunc": return function () { return true; };
      case "falseFunc": return function () { return false; };
      case "emptyArr": return [];
      case "emptyObj": return {};
      case "''":
      case '""': return "";
      default: {
        const number = Number(raw);
        return raw !== "" && Number.isFinite(number) ? number : raw;
      }
    }
  };

  const matcher = (raw) => {
    if (typeof raw !== "string" || raw === "") return null;
    if (raw.length > 2 && raw.startsWith("/") && raw.lastIndexOf("/") > 0) {
      const end = raw.lastIndexOf("/");
      try { return new RegExp(raw.slice(1, end), raw.slice(end + 1)); } catch (_) {}
    }
    return { test: (value) => String(value).includes(raw) };
  };

  // Własność może jeszcze nie istnieć — wtedy zakładamy setter i czekamy, aż strona utworzy obiekt.
  const definePath = (owner, parts, install) => {
    if (!owner || parts.length === 0) return;
    const [head, ...rest] = parts;
    if (rest.length === 0) { install(owner, head); return; }
    const existing = owner[head];
    if (existing && (typeof existing === "object" || typeof existing === "function")) {
      definePath(existing, rest, install);
      return;
    }
    let stored = existing;
    try {
      Object.defineProperty(owner, head, {
        configurable: true,
        get() { return stored; },
        set(value) {
          stored = value;
          if (value && (typeof value === "object" || typeof value === "function")) {
            try { definePath(value, rest, install); } catch (_) {}
          }
        }
      });
    } catch (_) {}
  };

  const prune = (target, paths) => {
    if (!target || typeof target !== "object") return target;
    for (const path of paths) {
      const parts = path.split(".");
      let owner = target;
      for (let index = 0; index < parts.length - 1 && owner; index += 1) owner = owner[parts[index]];
      if (owner && typeof owner === "object") {
        try { delete owner[parts[parts.length - 1]]; } catch (_) {}
      }
    }
    return target;
  };

  function wrapTimer(name, args) {
    const needle = matcher(args[0] ?? "");
    const delay = args[1] === undefined || args[1] === "" ? null : Number(args[1]);
    const original = globalThis[name];
    if (typeof original !== "function") return;
    globalThis[name] = function (handler, timeout, ...rest) {
      const source = typeof handler === "function" ? String(handler) : String(handler ?? "");
      const delayMatches = delay === null || Number(timeout) === delay;
      if (delayMatches && (!needle || needle.test(source))) return 0;
      return original.call(this, handler, timeout, ...rest);
    };
  }

  const library = {
    "set-constant": (args) => {
      const value = literal(args[1]);
      definePath(globalThis, String(args[0] ?? "").split("."), (target, key) => {
        try { Object.defineProperty(target, key, { configurable: true, get: () => value, set: () => {} }); } catch (_) {}
      });
    },
    "abort-on-property-read": (args) => {
      definePath(globalThis, String(args[0] ?? "").split("."), (target, key) => {
        try {
          Object.defineProperty(target, key, {
            configurable: true,
            get() { throw new ReferenceError(String(key)); },
            set() {}
          });
        } catch (_) {}
      });
    },
    "abort-on-property-write": (args) => {
      definePath(globalThis, String(args[0] ?? "").split("."), (target, key) => {
        let stored = target[key];
        try {
          Object.defineProperty(target, key, {
            configurable: true,
            get() { return stored; },
            set() { throw new ReferenceError(String(key)); }
          });
        } catch (_) {}
      });
    },
    "json-prune": (args) => {
      const paths = String(args[0] ?? "").split(/\s+/).filter(Boolean);
      if (paths.length === 0 || state.jsonPruned) return;
      state.jsonPruned = true;
      const needle = matcher(args[1] ?? "");
      const originalParse = JSON.parse;
      JSON.parse = function (text, reviver) {
        const result = originalParse.call(this, text, reviver);
        if (needle && !needle.test(String(text))) return result;
        return prune(result, paths);
      };
      if (globalThis.Response?.prototype?.json) {
        const originalJson = Response.prototype.json;
        Response.prototype.json = function () {
          return originalJson.call(this).then((value) => prune(value, paths));
        };
      }
    },
    "prevent-settimeout": (args) => wrapTimer("setTimeout", args),
    "prevent-setinterval": (args) => wrapTimer("setInterval", args),
    "prevent-window-open": (args) => {
      const needle = matcher(args[0] ?? "");
      const original = globalThis.open;
      if (typeof original !== "function") return;
      globalThis.open = function (url, ...rest) {
        if (!needle || needle.test(String(url ?? ""))) return null;
        return original.apply(this, [url, ...rest]);
      };
    }
  };

  const aliases = {
    set: "set-constant",
    aopr: "abort-on-property-read",
    aopw: "abort-on-property-write",
    "no-settimeout-if": "prevent-settimeout",
    "no-setinterval-if": "prevent-setinterval",
    nowoif: "prevent-window-open"
  };

  for (const invocation of Array.isArray(invocations) ? invocations : []) {
    const name = aliases[invocation?.name] ?? invocation?.name;
    const args = Array.isArray(invocation?.arguments) ? invocation.arguments : [];
    const key = `${name}\u0000${args.join("\u0000")}`;
    if (!library[name] || state.applied.has(key)) continue;
    state.applied.add(key);
    try { library[name](args); } catch (_) {}
  }
}

async function runScriptlets(list, sender) {
  const tabId = sender?.tab?.id;
  if (!Number.isInteger(tabId) || !Array.isArray(list) || list.length === 0) return false;
  const target = { tabId };
  if (Number.isInteger(sender.frameId)) target.frameIds = [sender.frameId];
  try {
    await api.scripting.executeScript({ target, world: "MAIN", func: macAdBlockScriptletRunner, args: [list.slice(0, 100)] });
    return true;
  } catch (_) {
    return false;
  }
}

async function nativePayload() {
  try {
    const response = await api.runtime.sendNativeMessage("com.italiano88.MacAdBlock", { command: "rules" });
    return {
      rules: Array.isArray(response?.rules) ? response.rules : [],
      cosmetic: response?.cosmetic ?? { rules: [], exemptDomains: [], unsupportedRuleCount: 0 },
      allowlist: Array.isArray(response?.allowlist) ? response.allowlist : null
    };
  } catch (error) {
    try {
      const response = await fetch(api.runtime.getURL("rules.json"));
      return { failed: true, rules: await response.json(), cosmetic: { rules: [], exemptDomains: [], unsupportedRuleCount: 0 } };
    } catch (_) {
      return { failed: true, rules: [], cosmetic: { rules: [], exemptDomains: [], unsupportedRuleCount: 0 } };
    }
  }
}

function hashString(text) {
  let hash = 2166136261;
  for (let index = 0; index < text.length; index += 1) {
    hash ^= text.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0).toString(16);
}

/// Zapisuje wyjątki w aplikacji (App Group) i dopiero jej odpowiedź trafia do pamięci rozszerzenia.
async function pushAllowlist(domains) {
  const unique = [...new Set((domains ?? []).map((domain) => String(domain).trim().toLowerCase()).filter(Boolean))].sort();
  let stored = unique;
  try {
    const response = await api.runtime.sendNativeMessage("com.italiano88.MacAdBlock", { command: "allowlist", domains: unique });
    if (Array.isArray(response?.allowlist)) stored = response.allowlist;
  } catch (_) {
    // Aplikacja może być zamknięta — wyjątek działa wtedy tylko w rozszerzeniu, do następnej synchronizacji.
  }
  await api.storage.local.set({ allowlistedDomains: stored, pauseUntil: 0 });
  await synchronizeRules();
  return stored;
}

async function synchronizeRules() {
  const settings = await api.storage.local.get({ allowlistedDomains: [], pauseUntil: 0, statsVersion: 0 });
  if (settings.statsVersion < 2) {
    // Wcześniejsze wersje doliczały wymyśloną liczbę zaoszczędzonych bajtów — zerujemy ją.
    await api.storage.local.set({ statsVersion: 2, savedBytes: 0 });
  }
  const payload = await nativePayload();
  if (payload.failed) {
    // Chwilowy błąd komunikacji z aplikacją nie może wyczyścić działających reguł — zachowujemy zainstalowane.
    try {
      const existing = await api.declarativeNetRequest.getDynamicRules();
      const stored = await api.storage.local.get({ compiledCosmeticRules: null });
      if (existing.length > 0) {
        payload.rules = existing.filter((rule) => rule.id < ALLOW_RULE_ID);
        payload.cosmetic = stored.compiledCosmeticRules ?? payload.cosmetic;
      }
    } catch (_) {}
  }
  // Aplikacja jest właścicielem listy wyjątków: to ona zna je we wszystkich warstwach ochrony.
  let allowlistedDomains = settings.allowlistedDomains;
  if (!payload.failed && Array.isArray(payload.allowlist)) {
    allowlistedDomains = payload.allowlist;
    if (JSON.stringify(allowlistedDomains) !== JSON.stringify(settings.allowlistedDomains)) {
      await api.storage.local.set({ allowlistedDomains });
    }
  }
  const paused = Number(settings.pauseUntil) > Date.now();
  const allowRules = allowRulesFor(allowlistedDomains);
  const advertisedLimit = Number(api.declarativeNetRequest.MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES);
  const limit = Number.isFinite(advertisedLimit) && advertisedLimit > 0 ? advertisedLimit : FALLBACK_DYNAMIC_LIMIT;
  const available = Math.max(0, limit - allowRules.length);
  const incoming = paused ? [] : payload.rules.slice(0, available);
  const rulesToInstall = [...incoming, ...allowRules];
  const cosmetic = paused ? { rules: [], exemptDomains: [], unsupportedRuleCount: 0 } : payload.cosmetic;

  try {
    const current = await api.declarativeNetRequest.getDynamicRules();
    // Gdy nic się nie zmieniło, nie przebudowujemy reguł i nie zapisujemy kosztownych danych ponownie
    // (zapis wywołałby też odświeżenie stylów we wszystkich otwartych kartach).
    const signature = hashString(JSON.stringify([rulesToInstall, cosmetic]));
    const stored = await api.storage.local.get({ rulesSignature: "" });
    if (stored.rulesSignature === signature && current.length === rulesToInstall.length) {
      await api.storage.local.set({ lastRuleSync: Date.now() });
    } else {
      await api.declarativeNetRequest.updateDynamicRules({
        removeRuleIds: current.map((rule) => rule.id),
        addRules: rulesToInstall
      });
      await api.storage.local.set({
        compiledCosmeticRules: cosmetic,
        rulesSignature: signature,
        lastRuleSync: Date.now(),
        dynamicRuleCount: incoming.length,
        droppedDynamicRuleCount: Math.max(0, payload.rules.length - incoming.length)
      });
    }
  } catch (error) {
    console.error("MacAdBlock rule update failed", error);
  }

  try {
    await api.declarativeNetRequest.setExtensionActionOptions({ displayActionCountAsBadgeText: true });
  } catch (_) {}
}

api.runtime.onInstalled.addListener(synchronizeRules);
api.runtime.onStartup.addListener(synchronizeRules);

// Aplikacja nie potrafi wysłać rozszerzeniu sygnału o nowych regułach, więc rozszerzenie co jakiś czas
// samo pobiera je przez native messaging (zmiana jest zapisywana tylko wtedy, gdy reguły się różnią).
const SYNC_ALARM = "macadblock-sync";
try {
  api.alarms?.create(SYNC_ALARM, { delayInMinutes: 1, periodInMinutes: 30 });
  api.alarms?.onAlarm.addListener((alarm) => {
    if (alarm.name === SYNC_ALARM) synchronizeRules();
  });
} catch (_) {}
api.runtime.onMessage.addListener((message, sender) => {
  if (message?.command === "sync") return synchronizeRules();
  if (message?.command === "allowlist-set") return pushAllowlist(message.domains);
  if (message?.command === "custom-rule") {
    return api.runtime.sendNativeMessage("com.italiano88.MacAdBlock", { command: "custom-rule", rule: message.rule })
      .catch(() => ({ saved: false }));
  }
  if (message?.command === "install-anti-adblock") return installAntiAdblock(sender);
  if (message?.command === "install-popup-guard") return installPopupGuardFor(sender);
  if (message?.command === "scriptlets") return runScriptlets(message.scriptlets, sender);
  if (message?.command === "cosmetic-rules") {
    return api.storage.local.get({ compiledCosmeticRules: { rules: [], exemptDomains: [], unsupportedRuleCount: 0 } })
      .then((value) => value.compiledCosmeticRules);
  }
  return undefined;
});
api.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && (changes.allowlistedDomains || changes.pauseUntil)) synchronizeRules();
});
