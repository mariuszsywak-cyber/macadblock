const api = globalThis.browser ?? globalThis.chrome;
let activeDomain = "";

async function loadState() {
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  try { activeDomain = new URL(tab.url).hostname.replace(/^www\./, ""); } catch (_) { activeDomain = ""; }
  const state = await api.storage.local.get({ blockedAds: 0, blockedTrackers: 0, savedBytes: 0, allowlistedDomains: [], pauseUntil: 0, antiAdblockEnabled: true, antiAdblockDisabledDomains: [] });
  const paused = Number(state.pauseUntil) > Date.now();
  const allowed = activeDomain && state.allowlistedDomains.includes(activeDomain);
  const enabled = !paused && !allowed;
  document.querySelector("#ads").textContent = Number(state.blockedAds).toLocaleString("pl-PL");
  document.querySelector("#trackers").textContent = Number(state.blockedTrackers).toLocaleString("pl-PL");
  document.querySelector("#data").textContent = `${(Number(state.savedBytes) / 1024).toFixed(0)} KB`;
  document.querySelector("#site").textContent = paused ? "Ochrona jest czasowo wstrzymana" : allowed ? `${activeDomain} znajduje się na liście dozwolonych` : `${activeDomain || "Ta witryna"} jest chroniona`;
  document.querySelector("#status").textContent = enabled ? "Ochrona aktywna" : "Ochrona wyłączona";
  document.querySelector("#power").classList.toggle("off", !enabled);
  document.querySelector("#power span").textContent = enabled ? "✓" : "×";
  const antiAdblockActive = state.antiAdblockEnabled && !state.antiAdblockDisabledDomains.includes(activeDomain);
  const antiAdblockButton = document.querySelector("#anti-adblock");
  antiAdblockButton.textContent = `Anti‑Adblock: ${antiAdblockActive ? "włączony" : "wyłączony"}`;
  antiAdblockButton.classList.toggle("active", antiAdblockActive);
}

document.querySelector("#power").addEventListener("click", async () => {
  if (!activeDomain) return;
  const { allowlistedDomains = [] } = await api.storage.local.get({ allowlistedDomains: [] });
  const domains = new Set(allowlistedDomains);
  if (domains.has(activeDomain)) domains.delete(activeDomain); else domains.add(activeDomain);
  await api.storage.local.set({ allowlistedDomains: [...domains].sort(), pauseUntil: 0 });
  await api.runtime.sendMessage({ command: "sync" });
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  await api.tabs.reload(tab.id);
  window.close();
});

for (const button of document.querySelectorAll("[data-minutes]")) {
  button.addEventListener("click", async () => {
    const pauseUntil = Date.now() + Number(button.dataset.minutes) * 60_000;
    await api.storage.local.set({ pauseUntil });
    await api.runtime.sendMessage({ command: "sync" });
    window.close();
  });
}

document.querySelector("#settings").addEventListener("click", () => api.runtime.openOptionsPage?.());
document.querySelector("#sync").addEventListener("click", async () => { await api.runtime.sendMessage({ command: "sync" }); window.close(); });
document.querySelector("#anti-adblock").addEventListener("click", async () => {
  if (!activeDomain) return;
  const state = await api.storage.local.get({ antiAdblockDisabledDomains: [] });
  const domains = new Set(state.antiAdblockDisabledDomains);
  if (domains.has(activeDomain)) domains.delete(activeDomain); else domains.add(activeDomain);
  await api.storage.local.set({ antiAdblockDisabledDomains: [...domains].sort() });
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  await api.tabs.reload(tab.id);
  window.close();
});
document.querySelector("#picker").addEventListener("click", async () => {
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  await api.scripting.executeScript({ target: { tabId: tab.id }, files: ["picker.js"] });
  window.close();
});
document.querySelector("#clear-picker").addEventListener("click", async () => {
  if (!activeDomain) return;
  const stored = await api.storage.local.get({ customSelectorsByDomain: {} });
  delete stored.customSelectorsByDomain[activeDomain];
  await api.storage.local.set({ customSelectorsByDomain: stored.customSelectorsByDomain });
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  await api.tabs.reload(tab.id);
  window.close();
});

loadState();
