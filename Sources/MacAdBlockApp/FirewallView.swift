import SwiftUI

struct FirewallView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var firewall: FirewallController
    private let accent = SentinelTheme.control

    @State private var draft = FirewallRule()
    @State private var draftError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Firewall")).font(.largeTitle.bold())
                    Text(L("Blokuj połączenia po adresie, porcie i protokole. Reguły działają w całym systemie (pf).")).foregroundStyle(.secondary)
                }

                if let deadline = firewall.confirmationDeadline { confirmationBanner(deadline) }
                if firewall.hasUnappliedChanges { unappliedBanner }
                if let error = firewall.errorMessage { messageBanner(error, icon: "exclamationmark.triangle.fill", tint: .orange) }

                mainSection
                rulesSection
                nativeSection
                perAppSection
            }
            .padding(28).frame(maxWidth: 960).frame(maxWidth: .infinity)
        }
        .navigationTitle(L("Firewall"))
        .onAppear {
            firewall.refreshNativeStatus()
            Task { await firewall.refreshStatus() }
        }
    }

    // MARK: - Sekcje

    private var mainSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(L("Firewall MacAdBlock"), systemImage: "flame.fill").font(.title2.bold()).foregroundStyle(accent)
                Spacer()
                Toggle("", isOn: Binding(get: { firewall.config.enabled }, set: { firewall.setEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch).tint(accent)
                    .disabled(firewall.isBusy)
            }
            HStack(spacing: 8) {
                Circle().fill(firewall.config.enabled ? accent : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
                Text(firewall.statusText).font(.callout).foregroundStyle(.secondary)
                if firewall.isBusy { ProgressView().controlSize(.small) }
            }
            Divider()
            Toggle(isOn: $firewall.config.blockInbound) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Blokuj połączenia przychodzące")).font(.body.weight(.medium))
                    Text(L("Odrzuca nowe połączenia z sieci do Twojego Maca. Odpowiedzi na Twoje własne połączenia przechodzą. Może przeszkadzać w AirDrop i udostępnianiu.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .tint(accent)
            Toggle(isOn: $firewall.config.lockdown) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Tryb blokady")).font(.body.weight(.medium))
                    Text(L("Ruch wychodzący tylko na DNS, DHCP, NTP oraz HTTP i HTTPS. Reszta (np. poczta, SSH, gry) jest blokowana.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .tint(accent)
            Text(L("Reguły przestają działać po restarcie Maca; MacAdBlock przywraca je przy starcie aplikacji."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .card(accent)
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L("Reguły"), systemImage: "list.bullet.rectangle").font(.title2.bold()).foregroundStyle(accent)

            if firewall.config.rules.isEmpty {
                Text(L("Brak reguł. Dodaj pierwszą poniżej.")).font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(firewall.config.rules) { rule in
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(get: { rule.enabled }, set: { _ in firewall.toggleRule(rule) }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(title(for: rule)).font(.callout.weight(.medium))
                                if !rule.note.isEmpty { Text(rule.note).font(.caption).foregroundStyle(.secondary) }
                            }
                            .opacity(rule.enabled ? 1 : 0.5)
                            Spacer()
                            Button { firewall.removeRule(rule) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help(L("Usuń regułę"))
                        }
                        .padding(.vertical, 7)
                        Divider()
                    }
                }
            }

            addRuleForm
        }
        .card(accent)
    }

    private var addRuleForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Nowa reguła")).font(.headline)
            HStack {
                Picker("", selection: $draft.action) {
                    Text(L("Blokuj")).tag(FirewallRule.Action.block)
                    Text(L("Zezwól")).tag(FirewallRule.Action.allow)
                }
                .labelsHidden().frame(width: 100)
                Picker("", selection: $draft.direction) {
                    Text(L("Wychodzące")).tag(FirewallRule.Direction.outbound)
                    Text(L("Przychodzące")).tag(FirewallRule.Direction.inbound)
                }
                .labelsHidden().frame(width: 130)
                Picker("", selection: $draft.proto) {
                    Text(L("Dowolny protokół")).tag(FirewallRule.Proto.any)
                    Text("TCP").tag(FirewallRule.Proto.tcp)
                    Text("UDP").tag(FirewallRule.Proto.udp)
                }
                .labelsHidden().frame(width: 150)
            }
            HStack {
                TextField(L("Adres, blok CIDR lub domena (puste = dowolny)"), text: $draft.remote)
                    .textFieldStyle(.roundedBorder)
                TextField(L("Port, np. 443"), text: $draft.port)
                    .textFieldStyle(.roundedBorder).frame(width: 120)
            }
            HStack {
                TextField(L("Notatka (opcjonalnie)"), text: $draft.note).textFieldStyle(.roundedBorder)
                Button(L("Dodaj regułę"), systemImage: "plus") {
                    draftError = firewall.addRule(draft)
                    if draftError == nil { draft = FirewallRule(action: draft.action, direction: draft.direction, proto: draft.proto) }
                }
                .buttonStyle(.borderedProminent).tint(accent)
            }
            if let draftError { Text(draftError).font(.caption).foregroundStyle(.orange) }
            Text(L("Dla ruchu przychodzącego adres to źródło, a port to port na Twoim Macu. Zezwolenia mają pierwszeństwo przed blokadami."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var nativeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L("Firewall macOS"), systemImage: "checkmark.shield").font(.title2.bold()).foregroundStyle(accent)
            Text(L("Wbudowany firewall systemu filtruje połączenia przychodzące dla poszczególnych aplikacji. Zmiana wymaga uprawnień administratora."))
                .font(.callout).foregroundStyle(.secondary)
            Toggle(L("Włącz firewall macOS"), isOn: Binding(
                get: { firewall.nativeEnabled ?? false },
                set: { firewall.setNative(enabled: $0, stealth: firewall.nativeStealth ?? false) }
            ))
            .tint(accent).disabled(firewall.isBusy || firewall.nativeEnabled == nil)
            Toggle(L("Tryb ukrycia (nie odpowiadaj na ping i skanowanie)"), isOn: Binding(
                get: { firewall.nativeStealth ?? false },
                set: { firewall.setNative(enabled: firewall.nativeEnabled ?? false, stealth: $0) }
            ))
            .tint(accent).disabled(firewall.isBusy || firewall.nativeEnabled == nil)
            if firewall.nativeEnabled == nil {
                Text(L("Nie udało się odczytać stanu firewalla macOS.")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .card(accent)
    }

    private var perAppSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("Reguły dla aplikacji"), systemImage: "app.badge.checkmark").font(.title2.bold()).foregroundStyle(.secondary)
            Text(L("Pytanie „Czy zezwolić tej aplikacji na połączenie?” wymaga rozszerzenia sieciowego Content Filter, które Apple udostępnia tylko płatnemu kontu Developer. Na koncie Personal Team ta funkcja nie jest dostępna."))
                .font(.callout).foregroundStyle(.secondary)
        }
        .card(accent)
        .opacity(0.75)
    }

    // MARK: - Banery

    private func confirmationBanner(_ deadline: Date) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "timer").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(L("Zachowaj ustawienia? Firewall wyłączy się za \(max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))) s."))
                        .font(.callout.weight(.semibold))
                }
                Text(L("Jeśli po zmianie stracisz dostęp do sieci, nic nie rób — MacAdBlock sam cofnie firewall.")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("Zachowaj")) { firewall.confirmSettings() }.buttonStyle(.borderedProminent).tint(accent)
        }
        .card(.orange)
    }

    private var unappliedBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(L("Zmiany nie zostały jeszcze zastosowane.")).font(.callout.weight(.semibold))
            Spacer()
            Button(L("Zastosuj zmiany")) { firewall.applyChanges() }
                .buttonStyle(.borderedProminent).tint(accent).disabled(firewall.isBusy)
        }
        .card(.orange)
    }

    private func messageBanner(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .card(tint)
    }

    // MARK: - Opis reguły

    private func title(for rule: FirewallRule) -> String {
        let action = rule.action == .block ? L("Blokuj") : L("Zezwól")
        let direction = rule.direction == .outbound ? L("wychodzące") : L("przychodzące")
        let proto: String = switch rule.proto {
        case .any: rule.port.isEmpty ? L("dowolny protokół") : "TCP/UDP"
        case .tcp: "TCP"
        case .udp: "UDP"
        }
        let remote = rule.remote.isEmpty ? L("dowolny adres") : rule.remote
        let port = rule.port.isEmpty ? "" : ":\(rule.port)"
        return "\(action) · \(direction) · \(proto) · \(remote)\(port)"
    }
}

private extension View {
    func card(_ accent: Color) -> some View {
        padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).stroke(accent.opacity(0.16)) }
    }
}
