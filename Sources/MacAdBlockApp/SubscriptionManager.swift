import Foundation
import StoreKit
import SwiftUI

/// Subskrypcja miesięczna (StoreKit 2) z 14-dniowym okresem próbnym liczonym od pierwszego uruchomienia.
/// Blokada działa tylko w buildach Release: kompilacje Debug z Xcode nigdy nie odcinają ochrony, bo bez płatnego
/// konta Apple Developer produkt nie istnieje w App Store i nie dałoby się go kupić.
@MainActor
final class SubscriptionManager: ObservableObject {
    static let productID = "com.italiano88.macadblock.monthly"
    static let trialDays = 14

#if DEBUG
    static let enforcementEnabled = false
#else
    static let enforcementEnabled = true
#endif

    enum State: Equatable {
        case trial(daysLeft: Int)
        case subscribed
        case expired
    }

    @Published private(set) var state: State = .trial(daysLeft: SubscriptionManager.trialDays)
    @Published private(set) var product: Product?
    @Published private(set) var isBusy = false
    @Published var message: String?

    /// Wywoływane, gdy stan zmienia się na `.expired` — model wyłącza wtedy ochronę.
    var onExpired: (() -> Void)?

    private let defaults = UserDefaults.standard
    private var updatesTask: Task<Void, Never>?
    private var isSubscribed = false

    init() {
        if defaults.object(forKey: "trialStartDate") == nil {
            defaults.set(Date(), forKey: "trialStartDate")
        }
        recomputeState()
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result {
                    await transaction.finish()
                }
                await self.refresh()
            }
        }
        Task { await refresh() }
    }

    deinit { updatesTask?.cancel() }

    /// Czy ochrona może działać: zawsze w Debug, w Release — w okresie próbnym lub z aktywną subskrypcją.
    var isEntitled: Bool { !Self.enforcementEnabled || state != .expired }

    var priceText: String { product?.displayPrice ?? "10 zł" }

    var statusText: String {
        switch state {
        case .subscribed: L("Subskrypcja aktywna")
        case .trial(let days): L("Okres próbny: pozostało \(days) dni")
        case .expired: L("Okres próbny się zakończył")
        }
    }

    func refresh() async {
        do {
            let products = try await Product.products(for: [Self.productID])
            product = products.first
        } catch {
            product = nil
        }

        var active = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.productID,
                  transaction.revocationDate == nil,
                  (transaction.expirationDate ?? .distantFuture) > Date() else { continue }
            active = true
        }
        isSubscribed = active
        recomputeState()
    }

    func purchase() async {
        guard let product else {
            message = L("Subskrypcja jest chwilowo niedostępna. Sprawdź połączenie z internetem i spróbuj ponownie.")
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                switch result {
                case .verified(let transaction):
                    await transaction.finish()
                    message = L("Dziękujemy! Subskrypcja jest aktywna.")
                    await refresh()
                case .unverified:
                    message = L("Nie udało się zweryfikować zakupu.")
                }
            case .pending:
                message = L("Zakup czeka na zatwierdzenie.")
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func restore() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await AppStore.sync()
            await refresh()
            message = isSubscribed ? L("Przywrócono subskrypcję.") : L("Nie znaleziono aktywnej subskrypcji.")
        } catch {
            message = error.localizedDescription
        }
    }

    private func recomputeState() {
        let previous = state
        if isSubscribed {
            state = .subscribed
        } else {
            let start = defaults.object(forKey: "trialStartDate") as? Date ?? Date()
            let elapsed = Calendar.current.dateComponents([.day], from: start, to: Date()).day ?? 0
            let left = Self.trialDays - elapsed
            state = left > 0 ? .trial(daysLeft: left) : .expired
        }
        if state == .expired, previous != .expired { onExpired?() }
    }
}

struct SubscriptionView: View {
    @EnvironmentObject private var subscription: SubscriptionManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(SentinelTheme.control)
            Text("MacAdBlock Premium").font(.title.bold())
            Text(subscription.statusText).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Label(L("Blokowanie reklam i trackerów w Safari"), systemImage: "safari")
                Label(L("Ochrona systemowa przez /etc/hosts i DNS"), systemImage: "network.badge.shield.half.filled")
                Label(L("Dziennik blokad, pauza i wyjątki"), systemImage: "list.bullet.rectangle")
                Label(L("Automatyczne aktualizacje list filtrów"), systemImage: "arrow.triangle.2.circlepath")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if subscription.state == .subscribed {
                Text(L("Dziękujemy za wsparcie!")).font(.headline)
            } else {
                Button {
                    Task { await subscription.purchase() }
                } label: {
                    Text(L("Subskrybuj za \(subscription.priceText) / miesiąc")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(subscription.isBusy)
            }

            HStack {
                Button(L("Przywróć zakupy")) { Task { await subscription.restore() } }
                Spacer()
                Button(L("Zamknij")) { dismiss() }
            }
            .buttonStyle(.link)

            if let message = subscription.message {
                Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Text(L("Subskrypcja odnawia się co miesiąc, dopóki jej nie anulujesz w ustawieniach konta Apple."))
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(width: 420)
    }
}
