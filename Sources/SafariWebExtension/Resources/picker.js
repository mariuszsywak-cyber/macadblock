(() => {
  if (globalThis.__macAdBlockPickerActive) return;
  globalThis.__macAdBlockPickerActive = true;
  let selected;
  const polish = (navigator.language || "pl").toLowerCase().startsWith("pl");
  const pickerText = polish
    ? { banner: "MacAdBlock: kliknij element, aby go ukryć · Esc anuluje", confirm: (selector) => `Ukryć element „${selector}” na tej witrynie?` }
    : { banner: "MacAdBlock: click an element to hide it · Esc cancels", confirm: (selector) => `Hide the element “${selector}” on this site?` };
  const banner = document.createElement("div");
  banner.textContent = pickerText.banner;
  Object.assign(banner.style, { position: "fixed", top: "14px", left: "50%", transform: "translateX(-50%)", zIndex: "2147483647", padding: "10px 16px", borderRadius: "10px", color: "white", background: "#09251dcc", font: "600 13px -apple-system", boxShadow: "0 6px 24px #0006" });
  document.documentElement.appendChild(banner);

  const selectorFor = (element) => {
    if (element.id) return `#${CSS.escape(element.id)}`;
    const classes = [...element.classList].slice(0, 3).map((name) => `.${CSS.escape(name)}`).join("");
    return `${element.localName}${classes}`;
  };
  const move = (event) => {
    if (selected) selected.style.outline = "";
    selected = event.target;
    selected.style.outline = "2px solid #ff3b30";
  };
  const finish = async (event) => {
    event.preventDefault();
    event.stopPropagation();
    const selector = selectorFor(event.target);
    event.target.style.outline = "";
    document.removeEventListener("mouseover", move, true);
    document.removeEventListener("click", finish, true);
    document.removeEventListener("keydown", cancel, true);
    banner.remove();
    globalThis.__macAdBlockPickerActive = false;
    if (!confirm(pickerText.confirm(selector))) return;
    const api = globalThis.browser ?? globalThis.chrome;
    const domain = location.hostname.replace(/^www\./, "");
    const stored = await api.storage.local.get({ customSelectorsByDomain: {} });
    const current = stored.customSelectorsByDomain[domain] ?? [];
    await api.storage.local.set({ customSelectorsByDomain: { ...stored.customSelectorsByDomain, [domain]: [...new Set([...current, selector])] } });
    // Kopia w aplikacji: selektor staje się własną regułą, więc przetrwa ponowną instalację rozszerzenia
    // i jest widoczny w oknie „Własne reguły i wyjątki”.
    try { await api.runtime.sendMessage({ command: "custom-rule", rule: `${domain}##${selector}` }); } catch (_) {}
  };
  const cancel = (event) => {
    if (event.key !== "Escape") return;
    if (selected) selected.style.outline = "";
    banner.remove();
    document.removeEventListener("mouseover", move, true);
    document.removeEventListener("click", finish, true);
    document.removeEventListener("keydown", cancel, true);
    globalThis.__macAdBlockPickerActive = false;
  };
  document.addEventListener("mouseover", move, true);
  document.addEventListener("click", finish, true);
  document.addEventListener("keydown", cancel, true);
})();
