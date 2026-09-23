import Charts
import SwiftUI

struct StatisticsView: View {
    @EnvironmentObject private var model: AppModel
    private let accent = SentinelTheme.control

    private var values: [(String, Int)] {
        [(L("Sieciowe"), model.statistics.networkRuleCount), (L("Kosmetyczne"), model.statistics.cosmeticRuleCount), ("Safari", model.statistics.contentBlockerRuleCount), (L("Web Extension"), model.statistics.webExtensionRuleCount), ("Hosts", model.statistics.hostDomainCount)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Aktywność ochrony")).font(.largeTitle.bold())
                        Text(L("Podsumowanie skompilowanych reguł i źródeł")).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Wyczyść"), systemImage: "trash") { model.clearStatistics() }.buttonStyle(.bordered)
                }

                HStack(spacing: 12) {
                    metric(L("Wszystkie reguły"), totalRules, "shield.checkered")
                    metric(L("Domeny hosts"), model.statistics.hostDomainCount, "network")
                    metric(L("Aktywne źródła"), model.statistics.sourceCount, "line.3.horizontal.decrease.circle")
                    metric(L("Pominięte bezpiecznie"), model.statistics.unsupportedRuleCount, "exclamationmark.triangle")
                }

                blockActivitySection

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label(L("Rozkład ochrony"), systemImage: "chart.bar.fill").font(.title2.bold()).foregroundStyle(accent)
                        Spacer()
                        if let date = model.statistics.lastUpdated { Text(date, style: .relative).font(.caption).foregroundStyle(.secondary) }
                    }
                    Chart(values, id: \.0) { item in
                        BarMark(x: .value("Typ", item.0), y: .value(L("Liczba"), item.1))
                            .foregroundStyle(LinearGradient(colors: [Color(red: 0.22, green: 0.90, blue: 0.57), Color(red: 0.06, green: 0.58, blue: 0.35)], startPoint: .top, endPoint: .bottom))
                            .cornerRadius(7)
                    }
                    .chartYAxis { AxisMarks(position: .leading) }
                    .frame(height: 300)

                    HStack {
                        Label(L("Cache: \(model.statistics.cacheHits)"), systemImage: "internaldrive")
                        Spacer()
                        Text(L("Pominięte reguły nie są zgodne z bezpiecznymi API Safari."))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                .overlay { RoundedRectangle(cornerRadius: 20).stroke(accent.opacity(0.16)) }
            }
            .padding(28).frame(maxWidth: 1050).frame(maxWidth: .infinity)
        }
    }

    private var recentDays: [DailyBlockCount] {
        Array(model.dailyBlocks.suffix(range))
    }

    private var topDomains: [BlockedLogEntry] {
        model.topBlockedDomains
    }

    @State private var range = 7

    private var blockActivitySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(L("Zablokowane żądania DNS"), systemImage: "chart.xyaxis.line").font(.title2.bold()).foregroundStyle(accent)
                Spacer()
                Picker("", selection: $range) {
                    Text(L("7 dni")).tag(7)
                    Text(L("30 dni")).tag(30)
                }
                .pickerStyle(.segmented).frame(width: 150).labelsHidden()
            }
            if recentDays.allSatisfy({ $0.count == 0 }) {
                Text(L("Brak danych. Liczby pojawią się, gdy filtrowanie DNS zablokuje pierwsze żądania."))
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
            } else {
                Text(L("Razem: \(recentDays.reduce(0) { $0 + $1.count }.formatted())")).font(.caption).foregroundStyle(.secondary)
                Text(estimatedSavingsDescription).font(.caption).foregroundStyle(.secondary)
                Chart(recentDays) { item in
                    BarMark(x: .value(L("Dzień"), item.day, unit: .day), y: .value(L("Liczba"), item.count))
                        .foregroundStyle(accent.gradient)
                        .cornerRadius(5)
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 200)

                if !topDomains.isEmpty {
                    Text(L("Najczęściej blokowane domeny")).font(.headline).padding(.top, 4)
                    ForEach(topDomains) { entry in
                        HStack {
                            Text(entry.domain).font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(entry.count.formatted()).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(accent.opacity(0.16)) }
        .onAppear { model.refreshBlockedLog() }
    }

    private var totalRules: Int {
        model.statistics.networkRuleCount + model.statistics.cosmeticRuleCount + model.statistics.hostDomainCount
    }

    /// Bardzo zgrubne oszacowanie rzędu wielkości, nie pomiar: Safari nie raportuje do aplikacji, ile
    /// faktycznie zablokował (ograniczenie platformy — content blockery działają wewnątrz przeglądarki,
    /// bez kanału zwrotnego), więc liczymy tylko z realnych zdarzeń DNS/hosts w wybranym oknie i mnożymy
    /// przez orientacyjną średnią wielkość zablokowanego żądania (piksel śledzący, skrypt, beacon).
    private static let averageBlockedRequestBytes = 35_000.0

    private var estimatedSavingsDescription: String {
        let total = recentDays.reduce(0) { $0 + $1.count }
        guard total > 0 else { return "" }
        let megabytes = Double(total) * Self.averageBlockedRequestBytes / 1_000_000
        return L("Szacunkowo zaoszczędzone dane: ok. \(String(format: "%.1f", megabytes)) MB (tylko blokady DNS/hosts — Safari nie raportuje własnych blokad do aplikacji)")
    }

    private func metric(_ title: String, _ value: Int, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.title2).foregroundStyle(accent)
            Text(value.formatted()).font(.title2.bold().monospacedDigit()).contentTransition(.numericText())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 17))
        .overlay { RoundedRectangle(cornerRadius: 17).stroke(accent.opacity(0.14)) }
    }
}
