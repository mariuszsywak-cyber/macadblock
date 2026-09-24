import ServiceManagement
import SwiftUI

struct HostsView: View {
    @EnvironmentObject private var model: AppModel
    private let accent = SentinelTheme.control

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Ochrona całego Maca")).font(.largeTitle.bold())
                    Text(L("Blokuje znane domeny reklamowe i śledzące także poza Safari.")).foregroundStyle(.secondary)
                }

                setupGuide

                HStack(spacing: 14) {
                    statusCard("Helper", model.helperOperational ? L("Działa") : statusText, "gearshape.2.fill", model.helperOperational)
                    statusCard("Sekcja hosts", hostsStatusText, "checkmark.shield.fill", model.hostsAreCurrent)
                    statusCard(L("Domeny"), model.statistics.hostDomainCount.formatted(), "network", model.statistics.hostDomainCount > 0)
                }

                healthSummary

                VStack(alignment: .leading, spacing: 16) {
                    Label(L("Uprzywilejowany helper"), systemImage: "lock.shield.fill").font(.title2.bold()).foregroundStyle(accent)
                    Text(L("Helper modyfikuje wyłącznie oznaczoną sekcję MacAdBlock, wykonuje backup i zapisuje plik atomowo.")).foregroundStyle(.secondary)
                    if let message = model.helperMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
                    HStack {
                        Button(model.helperStatus == .enabled ? L("Napraw helper") : L("Skonfiguruj helper")) {
                            if model.helperStatus == .enabled {
                                model.repairHostsHelper()
                            } else {
                                model.prepareHostsHelper(openApprovalSettings: true)
                            }
                        }
                        .buttonStyle(.borderedProminent).tint(accent)
                        Button(L("Rzeczy logowania")) { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.bordered)
                    }
                }
                .glassSection(accent)

                VStack(alignment: .leading, spacing: 16) {
                    Label(L("Zarządzana sekcja /etc/hosts"), systemImage: "doc.text.magnifyingglass").font(.title2.bold()).foregroundStyle(accent)
                    Toggle(L("Odświeżaj automatycznie razem z listami"), isOn: $model.automaticallyApplyHosts).tint(accent)
                    Picker(L("Limit domen w /etc/hosts"), selection: $model.hostsDomainLimit) {
                        Text(L("Wszystkie")).tag(0)
                        Text("100 000").tag(100_000)
                        Text("200 000").tag(200_000)
                        Text("400 000").tag(400_000)
                    }
                    .pickerStyle(.menu)
                    Text(L("Mniejszy plik hosts przyspiesza rozwiązywanie nazw. Zmiana obowiązuje po ponownym kliknięciu „Zastosuj”."))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(L("Zastosuj \(model.hostsDomainsToApply.formatted()) domen")) { model.applyHosts() }
                            .buttonStyle(.borderedProminent).tint(accent)
                            .disabled(!model.canManageHosts || model.statistics.hostDomainCount == 0)
                        Button(L("Usuń sekcję MacAdBlock"), role: .destructive) { model.removeHosts() }
                            .buttonStyle(.bordered).disabled(!model.canManageHosts || !model.hostsEnabled)
                        Button(L("Odśwież DNS"), systemImage: "arrow.triangle.2.circlepath") { model.flushDNSCache() }
                            .buttonStyle(.bordered)
                            .help(L("Czyści pamięć podręczną DNS, żeby zmiany w hosts zadziałały od razu."))
                    }
                }
                .glassSection(accent)
            }
            .padding(28).frame(maxWidth: 960).frame(maxWidth: .infinity)
        }
        .navigationTitle(L("Ochrona systemowa"))
        .onAppear { model.prepareHostsHelper() }
    }

    private func statusCard(_ title: String, _ value: String, _ icon: String, _ active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Image(systemName: icon).foregroundStyle(active ? accent : .orange); Spacer(); Circle().fill(active ? accent : .orange).frame(width: 7, height: 7) }
            Text(value).font(.title3.bold()).lineLimit(1)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 17))
        .overlay { RoundedRectangle(cornerRadius: 17).stroke((active ? accent : .orange).opacity(0.17)) }
    }

    private var healthSummary: some View {
        VStack(spacing: 12) {
            healthRow(
                "Helper",
                model.helperOperational ? L("Działa poprawnie") : L("Nie odpowiada"),
                helperDetailText,
                "gearshape.2.fill",
                model.helperOperational
            )
            Divider()
            healthRow(
                "/etc/hosts",
                hostsStatusText,
                hostsDetailText,
                "doc.text.magnifyingglass",
                model.hostsAreCurrent
            )
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 17))
        .overlay { RoundedRectangle(cornerRadius: 17).stroke(accent.opacity(0.16)) }
    }

    private func healthRow(_ title: String, _ status: String, _ detail: String, _ icon: String, _ active: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: active ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(active ? accent : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title): \(status)").font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: icon).foregroundStyle(active ? accent : .secondary)
        }
    }

    private var setupGuide: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill((model.canManageHosts ? accent : .orange).opacity(0.14))
                Image(systemName: model.canManageHosts ? "checkmark" : "exclamationmark")
                    .font(.headline.bold())
                    .foregroundStyle(model.canManageHosts ? accent : .orange)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.canManageHosts ? L("Gotowe do użycia") : L("Wymagany jeden krok"))
                    .font(.headline)
                Text(model.canManageHosts ? L("Możesz zastosować listę domen poniżej.") : setupHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !model.canManageHosts {
                Button(L("Skonfiguruj")) { model.prepareHostsHelper(openApprovalSettings: true) }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke((model.canManageHosts ? accent : .orange).opacity(0.2)) }
    }

    private var setupHint: String {
        switch model.helperStatus {
        case .requiresApproval: L("Zatwierdź MacAdBlock w Rzeczach logowania macOS.")
        case .enabled: L("Uruchom aplikację z folderu Aplikacje.")
        default: L("Zainstaluj i aktywuj bezpieczny helper systemowy.")
        }
    }

    private var statusText: String {
        switch model.helperStatus {
        case .enabled: L("Gotowy")
        case .requiresApproval: L("Wymaga zgody")
        case .notRegistered: L("Konfiguracja")
        case .notFound: L("Niedostępny")
        @unknown default: L("Nieznany")
        }
    }

    private var hostsStatusText: String {
        if model.hostsAreCurrent { return L("Aktualne") }
        if model.hostsEnabled { return L("Nieaktualne") }
        return L("Nieaktywne")
    }

    private var hostsDetailText: String {
        if model.hostsAreCurrent {
            return L("W /etc/hosts działa komplet \(model.installedHostDomainCount.formatted()) domen z najnowszej listy.")
        }
        if model.hostsEnabled {
            // Cel to `hostsDomainsToApply` (uwzględnia bieżący limit), nie surowa liczba wszystkich
            // dostępnych domen — inaczej przy ustawionym limicie tekst mylnie sugerowałby, że brakuje
            // domen do „pełnej” listy, choć limit został zastosowany dokładnie tak, jak wybrano.
            // Zainstalowana liczba może być zarówno mniejsza (limit podniesiony albo lista urosła),
            // jak i większa niż cel (limit właśnie obniżony) — każdy przypadek ma osobny, jasny opis,
            // żeby „jest X z Y” nigdy nie brzmiało odwrotnie do tego, co się faktycznie dzieje.
            let installed = model.installedHostDomainCount
            let target = model.hostsDomainsToApply
            if installed > target {
                return L("W /etc/hosts jest \(installed.formatted()) domen, ale nowy limit to \(target.formatted()). Zastosuj, aby zmniejszyć listę.")
            }
            return L("W /etc/hosts jest \(installed.formatted()) z \(target.formatted()) domen. Zastosuj najnowszą listę.")
        }
        if model.statistics.hostDomainCount > 0 {
            return L("Lista ma \(model.statistics.hostDomainCount.formatted()) domen, ale sekcja MacAdBlock nie jest aktywna.")
        }
        return L("Najpierw zaktualizuj listy filtrów.")
    }

    private var helperDetailText: String {
        guard model.helperOperational else {
            return L("Test uruchomienia helpera nie powiódł się. Użyj przycisku Napraw helper.")
        }
        return model.helperUsesAuthorizationFallback
            ? L("Tryb lokalny jest gotowy; macOS poprosi o hasło administratora przy zmianach.")
            : L("Połączenie XPC z uprzywilejowanym helperem odpowiada poprawnie.")
    }
}

private extension View {
    func glassSection(_ accent: Color) -> some View {
        padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).stroke(accent.opacity(0.16)) }
    }
}
