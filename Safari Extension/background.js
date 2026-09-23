const api = globalThis.browser ?? globalThis.chrome;

function installAntiAdblockPageGuards() {
  if (globalThis.__macAdBlockAntiAdblockInstalled) return;
  Object.defineProperty(globalThis, "__macAdBlockAntiAdblockInstalled", { value: true });
  const detector = {
    onDetected() { return this; },
    onNotDetected(callback) { if (typeof callback === "function") queueMicrotask(callback); return this; },
    check() { return false; }, clearEvent() { return this; }, emitEvent() { return this; }, setOption() { return this; }
  };
  for (const name of ["blockAdBlock", "BlockAdBlock", "fuckAdBlock", "FuckAdBlock"]) {
    if (name in globalThis) continue;
    try { Object.defineProperty(globalThis, name, { configurable: true, get: () => detector, set: () => {} }); } catch (_) {}
  }
  for (const [name, value] of [["canRunAds", true], ["isAdBlockActive", false], ["adblockDetected", false]]) {
    if (name in globalThis) continue;
    try { Object.defineProperty(globalThis, name, { configurable: true, writable: true, value }); } catch (_) {}
  }
}

async function installAntiAdblock(sender) {
  const tabId = sender?.tab?.id;
  if (!Number.isInteger(tabId)) return false;
  const target = { tabId };
  if (Number.isInteger(sender.frameId)) target.frameIds = [sender.frameId];
  try {
    await api.scripting.executeScript({ target, world: "MAIN", func: installAntiAdblockPageGuards });
    return true;
  } catch (_) { return false; }
}

async function synchronizeRules() {
  let incoming = [];
  const settings = await api.storage.local.get({ allowlistedDomains: [], pauseUntil: 0 });
  if (Number(settings.pauseUntil) > Date.now()) incoming = [];
  const allowRules = settings.allowlistedDomains.map((domain, index) => ({
    id: 2_000_000 + index,
    priority: 100_000,
    action: { type: "allow" },
    condition: {
      initiatorDomains: [domain],
      resourceTypes: ["main_frame", "sub_frame", "stylesheet", "script", "image", "font", "object", "xmlhttprequest", "ping", "media", "websocket", "other"]
    }
  }));

  try {
    const response = await api.runtime.sendNativeMessage("com.italiano88.MacAdBlock", { command: "rules" });
    incoming = Array.isArray(response?.rules) ? response.rules : [];
  } catch (error) {
    try {
      const fallback = await fetch(api.runtime.getURL("rules.json"));
      const bundledRules = await fallback.json();
      incoming = Array.isArray(bundledRules) ? bundledRules : [];
    } catch (_) {
      incoming = [];
    }
    console.warn("MacAdBlock native sync unavailable; using bundled rules");
  }

  try {
    const current = await api.declarativeNetRequest.getDynamicRules();
    await api.declarativeNetRequest.updateDynamicRules({
      removeRuleIds: current.map((rule) => rule.id),
      addRules: [...incoming, ...allowRules]
    });
    await api.storage.local.set({ lastRuleSync: Date.now(), dynamicRuleCount: incoming.length });
  } catch (error) {
    console.error("MacAdBlock rule update failed", error);
  }
}

api.runtime.onInstalled.addListener(synchronizeRules);
api.runtime.onStartup.addListener(synchronizeRules);
api.runtime.onMessage.addListener((message, sender) => {
  if (message?.command === "sync") return synchronizeRules();
  if (message?.command === "install-anti-adblock") return installAntiAdblock(sender);
});
api.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && (changes.allowlistedDomains || changes.pauseUntil)) synchronizeRules();
});
