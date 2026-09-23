import AppKit
import SwiftUI

struct FilterSourcesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var kind: SourceKind = .all
    @State private var category: SourceCategoryChoice = .all
    @State private var activeOnly = false
    @State private var recommendedOnly = false

    private let accent = SentinelTheme.control

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Listy ochrony")).font(.largeTitle.bold())
                        Text(L("\(model.enabledSourceIDs.count) z \(model.sources.count) źródeł jest aktywnych")).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Kreator"), systemImage: "wand.and.stars") { model.showOnboarding = true }.buttonStyle(.bordered)
                    Button(L("Aktualizuj"), systemImage: "arrow.clockwise") { model.updateFilters() }
                        .buttonStyle(.borderedProminent).tint(accent).disabled(model.isUpdating)
                }

                HStack(spacing: 12) {
                    TextField(L("Szukaj listy, kraju lub kategorii"), text: $query).textFieldStyle(.roundedBorder)
                    Picker(L("Rodzaj"), selection: $kind) {
                        ForEach(SourceKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(width: 290).tint(accent)
                }

                HStack(spacing: 10) {
                    Picker(L("Kategoria"), selection: $category) {
                        ForEach(SourceCategoryChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 190, alignment: .leading)

                    Toggle(L("Tylko aktywne"), isOn: $activeOnly)
                        .toggleStyle(.checkbox)
                        .tint(accent)
                    Toggle(L("Tylko polecane"), isOn: $recommendedOnly)
                        .toggleStyle(.checkbox)
                        .tint(accent)
                    Spacer()
                    if hasFilters {
                        Button(L("Wyczyść filtry"), systemImage: "xmark.circle") {
                            query = ""
                            kind = .all
                            category = .all
                            activeOnly = false
                            recommendedOnly = false
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(accent)
                    }
                }

                HStack(spacing: 10) {
                    summaryCard("Safari", filteredSources.filter { $0.format == .adblock }.count, "safari")
                    summaryCard("Hosts", filteredSources.filter { $0.format != .adblock }.count, "network")
                    summaryCard(L("Szacowane wpisy"), filteredSources.reduce(0) { $0 + $1.estimatedRuleCount }, "list.number")
                }

                if groupedCountries.isEmpty {
                    ContentUnavailableView(L("Brak pasujących list"), systemImage: "line.3.horizontal.decrease.circle", description: Text(L("Zmień wyszukiwanie lub wyczyść filtry.")))
                        .frame(maxWidth: .infinity, minHeight: 260)
                        .glassCard()
                } else {
                    ForEach(groupedCountries, id: \.name) { country in
                        DisclosureGroup {
                            VStack(spacing: 0) {
                                HStack {
                                    Text(L("Zarządzaj grupą")).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button(allEnabled(country.sources) ? L("Wyłącz wszystkie") : L("Włącz wszystkie")) {
                                        set(country.sources, enabled: !allEnabled(country.sources))
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(accent)
                                }
                                .padding(.horizontal, 4)
                                .padding(.bottom, 6)

                            ForEach(country.sources) { source in
                                sourceRow(source)
                                if source.id != country.sources.last?.id { Divider().opacity(0.35).padding(.leading, 54) }
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        HStack(spacing: 12) {
                            Text(flag(for: country.code)).font(.title2)
                            VStack(alignment: .leading) {
                                Text(country.name).font(.headline)
                                Text(L("\(country.sources.count) źródeł")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(country.sources.filter { model.enabledSourceIDs.contains($0.id) }.count) aktywnych")
                                .font(.caption.weight(.semibold)).foregroundStyle(accent)
                        }
                    }
                    .padding(16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .overlay { RoundedRectangle(cornerRadius: 18).stroke(accent.opacity(0.16)) }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(L("Listy ochrony"))
    }

    private var filteredSources: [FilterSource] {
        model.sources.filter { source in
            let kindMatches = kind == .all || (kind == .safari ? source.format == .adblock : source.format != .adblock)
            let categoryMatches = category.category == nil || source.category == category.category
            let activeMatches = !activeOnly || model.enabledSourceIDs.contains(source.id)
            let recommendedMatches = !recommendedOnly || source.enabledByDefault
            let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let queryMatches = normalized.isEmpty || [source.name, source.countryName, source.category.displayName].contains { $0.lowercased().contains(normalized) }
            return kindMatches && categoryMatches && activeMatches && recommendedMatches && queryMatches
        }
    }

    private var hasFilters: Bool {
        !query.isEmpty || kind != .all || category != .all || activeOnly || recommendedOnly
    }

    private var groupedCountries: [(name: String, code: String, sources: [FilterSource])] {
        Dictionary(grouping: filteredSources, by: \FilterSource.countryName)
            .map { name, entries in (name, entries.first?.countryCode ?? "INT", entries.sorted { $0.name < $1.name }) }
            .sorted { lhs, rhs in
                if lhs.code == "INT" && rhs.code != "INT" { return true }
                if rhs.code == "INT" && lhs.code != "INT" { return false }
                return lhs.name < rhs.name
            }
    }

    private func summaryCard(_ title: String, _ value: Int, _ icon: String) -> some View {
        HStack { Image(systemName: icon).foregroundStyle(accent); Text(title); Spacer(); Text(value.formatted()).font(.headline.monospacedDigit()) }
            .padding(14).frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.13)) }
    }

    private func sourceRow(_ source: FilterSource) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon(for: source.category)).font(.title3).frame(width: 30).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(source.name).font(.headline)
                    if model.isSourceStale(source) {
                        Label(staleBadgeText(for: source), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .labelStyle(.titleAndIcon)
                            .help(L("Ta lista nie zaktualizowała się poprawnie od dłuższego czasu."))
                    }
                }
                Text(L("\(source.category.displayName) · około \(source.estimatedRuleCount.formatted()) wpisów")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Link(destination: source.homepage) { Image(systemName: "arrow.up.right.square").foregroundStyle(accent) }
            Toggle("", isOn: Binding(get: { model.enabledSourceIDs.contains(source.id) }, set: { model.setSource(source, enabled: $0) }))
                .labelsHidden().tint(accent)
        }
        .padding(.vertical, 9)
    }

    private func staleBadgeText(for source: FilterSource) -> String {
        guard let days = model.daysSinceLastSuccess(for: source) else { return L("Nigdy nie zaktualizowana") }
        return L("Nieaktualna od \(days) dni")
    }

    private func allEnabled(_ sources: [FilterSource]) -> Bool {
        !sources.isEmpty && sources.allSatisfy { model.enabledSourceIDs.contains($0.id) }
    }

    private func set(_ sources: [FilterSource], enabled: Bool) {
        for source in sources { model.setSource(source, enabled: enabled) }
    }

    private func flag(for code: String) -> String {
        guard code.count == 2 else { return "🌐" }
        return code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map(String.init).joined()
    }

    private func icon(for category: FilterCategory) -> String {
        switch category {
        case .ads: "rectangle.slash"
        case .privacy: "eye.slash"
        case .annoyances: "rectangle.3.group.bubble.left"
        case .social: "person.2.slash"
        case .regional: "globe.europe.africa"
        case .security: "exclamationmark.shield"
        case .malware: "ant"
        case .content: "hand.raised"
        }
    }
}

private enum SourceCategoryChoice: String, CaseIterable, Identifiable {
    case all, ads, privacy, annoyances, social, regional, security, malware, content
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: L("Wszystkie kategorie")
        case .ads: L("Reklamy")
        case .privacy: L("Prywatność")
        case .annoyances: L("Irytujące elementy")
        case .social: L("Media społecznościowe")
        case .regional: L("Regionalne")
        case .security: L("Bezpieczeństwo")
        case .malware: "Malware"
        case .content: L("Treści i serwisy")
        }
    }
    var category: FilterCategory? {
        switch self {
        case .all: nil
        case .ads: .ads
        case .privacy: .privacy
        case .annoyances: .annoyances
        case .social: .social
        case .regional: .regional
        case .security: .security
        case .malware: .malware
        case .content: .content
        }
    }
}

private enum SourceKind: String, CaseIterable, Identifiable {
    case all, safari, hosts
    var id: String { rawValue }
    var title: String { switch self { case .all: L("Wszystkie"); case .safari: "Safari"; case .hosts: "Hosts" } }
}

/// Okno „Własne reguły i wyjątki”: wyjątki wspólne dla Safari, hosts i DNS, własne reguły filtrujące,
/// listy dodane z adresu URL, limit reguł Content Blockera oraz kopia konfiguracji.
struct UserRulesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var newDomain = ""
    @State private var diagnosisQuery = ""
    @State private var draftRules = ""
    @State private var didLoadRules = false
    @State private var sourceName = ""
    @State private var sourceAddress = ""
    @State private var sourceFormat: FilterFormat = .adblock
    @State private var sourceCategory: FilterCategory = .ads

    private let accent = SentinelTheme.control
    private let budgets = [40_000, 60_000, 100_000, 150_000]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                diagnosticsSection
                blockLogSection
                allowlistSection
                customRulesSection
                customSourcesSection
                limitSection
            }
            .padding(24)
        }
        .frame(minWidth: 620, minHeight: 640)
        .onAppear {
            model.refreshBlockedLog()
            guard !didLoadRules else { return }
            draftRules = model.userSettings.customRules
            didLoadRules = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Diagnostyka i własne reguły")).font(.largeTitle.bold())
            Text(L("Wyjątki działają we wszystkich warstwach: w Safari, w sekcji hosts i w DNS proxy."))
                .foregroundStyle(.secondary)
        }
    }

    private var blockLogSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Ostatnio zablokowane w DNS")).font(.headline)
                Spacer()
                Button(L("Odśwież"), systemImage: "arrow.clockwise") { model.refreshBlockedLog() }
                    .buttonStyle(.bordered)
                Button(L("Wyczyść"), systemImage: "trash") { model.clearBlockedLog() }
                    .buttonStyle(.bordered)
                    .disabled(model.blockedLog.isEmpty)
            }
            Text(L("Domeny, których zapytania odrzucił DNS proxy. Kliknij domenę, żeby sprawdzić, która lista ją blokuje, albo dodaj ją do wyjątków."))
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.blockedLog.isEmpty {
                Text(L("Brak wpisów. Dziennik wypełnia się, gdy działa filtrowanie DNS (Ustawienia → DNS)."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.blockedLog.prefix(40)) { entry in
                        HStack(spacing: 10) {
                            Button {
                                diagnosisQuery = entry.domain
                                model.diagnoseDomain(entry.domain)
                            } label: {
                                Text(entry.domain).lineLimit(1).truncationMode(.middle)
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Text(entry.lastDate, style: .relative).font(.caption).foregroundStyle(.secondary)
                            Text("\(entry.count)×").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Button(L("Zezwól")) { model.allowDomain(entry.domain) }
                                .buttonStyle(.borderless)
                                .foregroundStyle(accent)
                        }
                        .padding(.vertical, 5)
                        Divider().opacity(0.5)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Dlaczego strona nie działa")).font(.headline)
            Text(L("Sprawdza pobrane listy i wygenerowane pliki: która lista dotyczy domeny, czy jest w sekcji hosts i ile reguł ukrywania ją obejmuje."))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField(L("np. sklep.example.com"), text: $diagnosisQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.diagnoseDomain(diagnosisQuery) }
                Button(L("Sprawdź"), systemImage: "stethoscope") { model.diagnoseDomain(diagnosisQuery) }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .disabled(model.isDiagnosing || diagnosisQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                if model.isDiagnosing { ProgressView().controlSize(.small) }
            }

            if let diagnosis = model.diagnosis {
                diagnosisResult(diagnosis)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    @ViewBuilder
    private func diagnosisResult(_ diagnosis: DomainDiagnosis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                Text(diagnosis.domain).font(.headline)
                Spacer()
                if diagnosis.isAllowlisted {
                    Button(L("Usuń wyjątek"), systemImage: "shield.slash") { model.disallowDomain(diagnosis.domain) }
                        .buttonStyle(.bordered)
                } else {
                    Button(L("Dodaj wyjątek"), systemImage: "checkmark.shield") { model.allowDomain(diagnosis.domain) }
                        .buttonStyle(.bordered)
                }
                Button(L("Zgłoś jako zepsutą"), systemImage: "exclamationmark.bubble") { model.reportBrokenSite(diagnosis.domain) }
                    .buttonStyle(.bordered)
                Button(L("Wyczyść"), systemImage: "xmark") { model.clearDiagnosis() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            if diagnosis.isAllowlisted {
                Label(L("Domena jest na liście wyjątków — ochrona jej nie dotyczy."), systemImage: "checkmark.shield")
                    .foregroundStyle(accent)
            } else if !diagnosis.isTouchedByProtection {
                Label(L("Żadna włączona reguła nie dotyczy tej domeny. Problem leży poza MacAdBlock."), systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }

            diagnosisRow(L("Sekcja hosts"), diagnosis.blockedByHosts ? L("Domena jest blokowana na poziomie systemu") : L("Brak wpisu"))
            diagnosisRow(L("Reguły ukrywania"), diagnosis.cosmeticRuleCount == 0 ? L("Brak") : "\(diagnosis.cosmeticRuleCount)")
            if !diagnosis.scriptletNames.isEmpty {
                diagnosisRow(L("Scriptlety"), diagnosis.scriptletNames.joined(separator: ", "))
            }
            diagnosisRow(
                L("Listy z regułą"),
                diagnosis.matchingSources.isEmpty
                    ? L("Żadna z \(diagnosis.scannedSourceCount) sprawdzonych list")
                    : diagnosis.matchingSources.joined(separator: ", ")
            )

            if !diagnosis.sampleRules.isEmpty {
                Text(L("Przykładowe reguły")).font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(diagnosis.sampleRules, id: \.self) { rule in
                            Text(rule).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func diagnosisRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }

    private var allowlistSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Strony bez blokowania")).font(.headline)
            HStack(spacing: 10) {
                TextField(L("np. mojbank.pl"), text: $newDomain)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addDomain)
                Button(L("Dodaj"), systemImage: "plus") { addDomain() }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if model.userSettings.normalizedAllowlist.isEmpty {
                Text(L("Lista jest pusta. Wyjątki dodane w popupie Safari pojawią się tutaj automatycznie."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.userSettings.normalizedAllowlist, id: \.self) { domain in
                    HStack {
                        Image(systemName: "checkmark.shield").foregroundStyle(accent)
                        Text(domain)
                        Spacer()
                        Button(L("Usuń"), systemImage: "trash") { model.disallowDomain(domain) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    Divider()
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var customRulesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Własne reguły")).font(.headline)
                Spacer()
                Button(L("Importuj z pliku…"), systemImage: "square.and.arrow.down") { importRulesFromFile() }
                    .buttonStyle(.bordered)
                Button(L("Zapisz")) { model.setCustomRules(draftRules) }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .disabled(draftRules == model.userSettings.customRules)
            }
            Text(L("Składnia Adblock Plus, jedna reguła w wierszu. Elementy wskazane pickerem w Safari dopisują się tutaj same."))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $draftRules)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 150)
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func importRulesFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let imported = try? String(contentsOf: url, encoding: .utf8) else { return }
        let trimmed = imported.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draftRules = draftRules.isEmpty ? trimmed : draftRules + "\n" + trimmed
    }

    private var customSourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Własne listy")).font(.headline)
            HStack(spacing: 10) {
                TextField(L("Nazwa"), text: $sourceName).textFieldStyle(.roundedBorder).frame(width: 150)
                TextField("https://…", text: $sourceAddress).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 10) {
                Picker("Format", selection: $sourceFormat) {
                    Text("Adblock").tag(FilterFormat.adblock)
                    Text("Hosts").tag(FilterFormat.hosts)
                    Text(L("Lista domen")).tag(FilterFormat.domains)
                }
                .frame(width: 200)
                Picker(L("Kategoria"), selection: $sourceCategory) {
                    ForEach([FilterCategory.ads, .privacy, .annoyances, .social, .regional, .security, .malware, .content], id: \.rawValue) {
                        Text($0.displayName).tag($0)
                    }
                }
                .frame(width: 260)
                Spacer()
                Button(L("Dodaj listę"), systemImage: "plus.circle") {
                    model.addCustomSource(name: sourceName, address: sourceAddress, format: sourceFormat, category: sourceCategory)
                    if model.lastError == nil {
                        sourceName = ""
                        sourceAddress = ""
                    }
                }
                .buttonStyle(.bordered)
                .disabled(sourceName.isEmpty || sourceAddress.isEmpty)
            }

            ForEach(model.userSettings.customSources) { source in
                HStack {
                    Image(systemName: "link").foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.name)
                        Text(source.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button(L("Usuń"), systemImage: "trash") { model.removeCustomSource(source) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                Divider()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var limitSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Limit reguł Safari")).font(.headline)
            Picker(L("Limit reguł Content Blockera"), selection: Binding(
                get: { model.contentBlockerRuleBudget },
                set: { model.setContentBlockerRuleBudget($0) }
            )) {
                ForEach(budgets, id: \.self) { Text($0.formatted()).tag($0) }
            }
            .pickerStyle(.segmented)
            .tint(accent)
            Text(L("Safari odrzuca całą listę po przekroczeniu limitu. Gdy tak się stanie, MacAdBlock sam zmniejsza limit i kompiluje reguły ponownie."))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button(L("Eksportuj konfigurację"), systemImage: "square.and.arrow.up") { model.exportConfiguration() }
                    .buttonStyle(.bordered)
                Button(L("Wczytaj konfigurację"), systemImage: "square.and.arrow.down") { model.importConfiguration() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func addDomain() {
        let domain = newDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !domain.isEmpty else { return }
        model.allowDomain(domain)
        newDomain = ""
    }
}
