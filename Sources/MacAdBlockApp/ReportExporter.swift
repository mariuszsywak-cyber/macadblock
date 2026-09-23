import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Eksport statystyk ochrony jako CSV (surowe dane) albo PDF (czytelny raport jednej strony).
enum ReportExporter {
    @MainActor
    static func csv(model: AppModel) -> String {
        var lines = ["Data;Zablokowane (DNS)"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        for entry in model.dailyBlocks {
            lines.append("\(formatter.string(from: entry.day));\(entry.count)")
        }
        lines.append("")
        lines.append("Domena;Liczba blokad;Ostatnia blokada")
        for entry in model.topBlockedDomains {
            lines.append("\(entry.domain);\(entry.count);\(formatter.string(from: entry.lastDate))")
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    static func pdfData(model: AppModel) -> Data {
        let hosting = NSHostingView(rootView: ReportPDFPage(model: model))
        let size = NSSize(width: 612, height: 792)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        return hosting.dataWithPDF(inside: hosting.bounds)
    }

    @MainActor
    static func save(csv: Bool, model: AppModel) {
        let panel = NSSavePanel()
        let stamp = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        panel.allowedContentTypes = [csv ? .commaSeparatedText : .pdf]
        panel.nameFieldStringValue = "MacAdBlock-raport-\(stamp).\(csv ? "csv" : "pdf")"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if csv {
                try? Self.csv(model: model).write(to: url, atomically: true, encoding: .utf8)
            } else {
                try? Self.pdfData(model: model).write(to: url)
            }
        }
    }
}

private struct ReportPDFPage: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MacAdBlock — raport ochrony").font(.title.bold())
            Text(Date().formatted(date: .long, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            Divider()
            Group {
                row(L("Wszystkie reguły"), model.statistics.networkRuleCount + model.statistics.cosmeticRuleCount + model.statistics.hostDomainCount)
                row(L("Domeny hosts"), model.statistics.hostDomainCount)
                row(L("Aktywne źródła"), model.statistics.sourceCount)
                row(L("Pominięte bezpiecznie"), model.statistics.unsupportedRuleCount)
            }
            Divider()
            Text(L("Blokady DNS — ostatnie dni")).font(.headline)
            ForEach(model.dailyBlocks.suffix(30)) { entry in
                HStack {
                    Text(entry.day, style: .date).font(.caption)
                    Spacer()
                    Text("\(entry.count)").font(.caption.monospacedDigit())
                }
            }
            if !model.topBlockedDomains.isEmpty {
                Divider()
                Text(L("Najczęściej blokowane domeny")).font(.headline)
                ForEach(model.topBlockedDomains) { entry in
                    HStack {
                        Text(entry.domain).font(.caption)
                        Spacer()
                        Text("\(entry.count)×").font(.caption.monospacedDigit())
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(36)
        .frame(width: 612, height: 792, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(Color.black)
    }

    private func row(_ title: String, _ value: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.formatted()).monospacedDigit()
        }
        .font(.callout)
    }
}
