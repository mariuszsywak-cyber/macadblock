const EN = {
  "Reguły wymagają synchronizacji": "Rules need syncing",
  "Reguły zsynchronizowane przed chwilą": "Rules synced just now",
  "Ta witryna": "This site",
  "Wstrzymana na wszystkich witrynach": "Paused on all sites",
  "Wyłączona dla tej witryny": "Off for this site",
  "Ochrona aktywna": "Protection active",
  "Włączone dla tej witryny": "On for this site",
  "Brak elementów do przywrócenia": "No elements to restore",
  "Brak elementów": "None",
  "Synchronizowanie…": "Syncing…",
  "Błąd synchronizacji": "Sync failed",
  "Brak dostępu": "No access",
  "Otwórz zwykłą stronę i spróbuj ponownie": "Open a regular page and try again",
  "Komunikaty anty-adblock": "Anti-adblock notices",
  "Ukryj element": "Hide element",
  "Wskaż go na stronie": "Pick it on the page",
  "Przywróć ukryte": "Restore hidden",
  "Wstrzymaj wszędzie": "Pause everywhere",
  "5 min": "5 min",
  "1 godz.": "1 hr",
  "Reguły są aktualne": "Rules are up to date",
  "Synchronizuj": "Sync",
  "Synchronizuj reguły": "Sync rules",
  "Ochrona tej witryny": "Protect this site",
};
const IS_POLISH = (navigator.language || "pl").toLowerCase().startsWith("pl");
const t = (text) => (IS_POLISH ? text : EN[text] ?? text);
const tPlural = (n) => (IS_POLISH ? `${n} ${n === 1 ? "element do przywrócenia" : "elementy do przywrócenia"}` : `${n} ${n === 1 ? "element" : "elements"} to restore`);
if (!IS_POLISH) {
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const value = node.nodeValue.trim();
    if (EN[value]) node.nodeValue = node.nodeValue.replace(value, EN[value]);
  }
  for (const attr of ["title", "aria-label"]) {
    document.querySelectorAll(`[${attr}]`).forEach((el) => { const v = el.getAttribute(attr); if (EN[v]) el.setAttribute(attr, EN[v]); });
  }
}

const api = globalThis.browser ?? globalThis.chrome;
let activeDomain = "";

const element = (selector) => document.querySelector(selector);

function syncDescription(timestamp) {
  const elapsed = Date.now() - Number(timestamp || 0);
  if (!timestamp || elapsed > 86_400_000) return t("Reguły wymagają synchronizacji");
  if (elapsed < 60_000) return t("Reguły zsynchronizowane przed chwilą");
  if (elapsed < 3_600_000) return IS_POLISH ? `Reguły zsynchronizowane ${Math.floor(elapsed / 60_000)} min temu` : `Rules synced ${Math.floor(elapsed / 60_000)} min ago`;
  return IS_POLISH ? `Reguły zsynchronizowane ${Math.floor(elapsed / 3_600_000)} godz. temu` : `Rules synced ${Math.floor(elapsed / 3_600_000)} hr ago`;
}

async function activeTab() {
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  return tab;
}

async function reloadActiveTab() {
  const tab = await activeTab();
  if (Number.isInteger(tab?.id)) await api.tabs.reload(tab.id);
}

async function loadState() {
  const tab = await activeTab();
  try { activeDomain = new URL(tab?.url).hostname.replace(/^www\./, ""); } catch (_) { activeDomain = ""; }
  const state = await api.storage.local.get({ allowlistedDomains: [], pauseUntil: 0, antiAdblockEnabled: true, antiAdblockDisabledDomains: [], customSelectorsByDomain: {}, lastRuleSync: 0 });
  const paused = Number(state.pauseUntil) > Date.now();
  const allowed = Boolean(activeDomain) && state.allowlistedDomains.includes(activeDomain);
  const enabled = !paused && !allowed;
  const hiddenElementCount = state.customSelectorsByDomain[activeDomain]?.length ?? 0;

  // Nazwa witryny jest nagłówkiem, a stan podpisem — bez powtarzania tej samej informacji.
  element("#site").textContent = activeDomain || t("Ta witryna");
  element("#status").textContent = paused ? t("Wstrzymana na wszystkich witrynach") : allowed ? t("Wyłączona dla tej witryny") : t("Ochrona aktywna");
  element("#power").classList.toggle("off", !enabled);
  element("#power").setAttribute("aria-checked", String(enabled));
  document.body.classList.toggle("protection-off", !enabled);

  const antiAdblockActive = state.antiAdblockEnabled && !state.antiAdblockDisabledDomains.includes(activeDomain);
  element("#anti-adblock").classList.toggle("active", antiAdblockActive);
  element("#anti-adblock-state").textContent = antiAdblockActive ? t("Włączone dla tej witryny") : t("Wyłączone dla tej witryny");
  element("#clear-picker").disabled = hiddenElementCount === 0;
  element("#hidden-elements-state").textContent = hiddenElementCount ? tPlural(hiddenElementCount) : t("Brak elementów do przywrócenia");
  element("#sync-status").textContent = syncDescription(state.lastRuleSync);
}

element("#power").addEventListener("click", async () => {
  if (!activeDomain) return;
  const { allowlistedDomains = [] } = await api.storage.local.get({ allowlistedDomains: [] });
  const domains = new Set(allowlistedDomains);
  if (domains.has(activeDomain)) domains.delete(activeDomain); else domains.add(activeDomain);
  // Wyjątek zapisuje serwis w tle: najpierw w aplikacji (Content Blocker i hosts), potem lokalnie.
  // Bezpośredni zapis do storage powodowałby wyścig z synchronizacją i cofnięcie zmiany.
  await api.runtime.sendMessage({ command: "allowlist-set", domains: [...domains].sort() });
  await reloadActiveTab();
  window.close();
});

for (const button of document.querySelectorAll("[data-minutes]")) {
  button.addEventListener("click", async () => {
    await api.storage.local.set({ pauseUntil: Date.now() + Number(button.dataset.minutes) * 60_000 });
    await api.runtime.sendMessage({ command: "sync" });
    window.close();
  });
}

element("#sync").addEventListener("click", async () => {
  const button = element("#sync");
  button.disabled = true;
  element("#sync-status").textContent = t("Synchronizowanie…");
  try { await api.runtime.sendMessage({ command: "sync" }); await loadState(); }
  catch (_) { element("#sync-status").textContent = t("Błąd synchronizacji"); }
  finally { button.disabled = false; }
});

element("#anti-adblock").addEventListener("click", async () => {
  if (!activeDomain) return;
  const state = await api.storage.local.get({ antiAdblockDisabledDomains: [] });
  const domains = new Set(state.antiAdblockDisabledDomains);
  if (domains.has(activeDomain)) domains.delete(activeDomain); else domains.add(activeDomain);
  await api.storage.local.set({ antiAdblockDisabledDomains: [...domains].sort() });
  await reloadActiveTab();
  window.close();
});

element("#picker").addEventListener("click", async () => {
  const tab = await activeTab();
  if (!Number.isInteger(tab?.id)) return;
  await api.scripting.executeScript({ target: { tabId: tab.id }, files: ["picker.js"] });
  window.close();
});

element("#clear-picker").addEventListener("click", async () => {
  if (!activeDomain) return;
  const stored = await api.storage.local.get({ customSelectorsByDomain: {} });
  delete stored.customSelectorsByDomain[activeDomain];
  await api.storage.local.set({ customSelectorsByDomain: stored.customSelectorsByDomain });
  await reloadActiveTab();
  window.close();
});

loadState().catch(() => {
  element("#site").textContent = t("Brak dostępu");
  element("#status").textContent = t("Otwórz zwykłą stronę i spróbuj ponownie");
});
