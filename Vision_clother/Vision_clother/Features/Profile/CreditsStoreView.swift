//
//  CreditsStoreView.swift
//  Vision_clother
//
//  The consumable credit store (StoreKit top-ups), presented as a sheet from
//  `AccountSectionView`'s linked-account content only — guests can't
//  purchase (credits hang off the Firebase uid; a guest uid is disposable),
//  and the backend 403s them as the backstop.
//
//  Same view+view-model-in-one-file shape as `AccountSectionView`. The view
//  model forwards to the app-root `StoreKitPaymentManager` passed per call
//  (mirroring `AccountSectionViewModel.signOut(syncCoordinator:)`'s
//  pattern) — views never call the manager directly.
//

import StoreKit
import SwiftUI

@MainActor
@Observable
final class CreditsStoreViewModel {
    enum PurchaseFeedback: Equatable {
        case none
        case granted
        case pending
        case failed(String)
    }

    private(set) var feedback: PurchaseFeedback = .none
    /// Which product row shows the in-flight spinner — distinct from the
    /// manager's global `isPurchasing` so only the tapped row dims.
    private(set) var purchasingProductID: String?

    func purchase(_ product: Product, using manager: StoreKitPaymentManager) async {
        guard purchasingProductID == nil else { return }
        feedback = .none
        purchasingProductID = product.id
        defer { purchasingProductID = nil }

        switch await manager.purchase(product) {
        case .granted:
            feedback = .granted
        case .pending:
            feedback = .pending
        case .cancelled:
            feedback = .none
        case .failed(let message):
            feedback = .failed(message)
        }
    }
}

struct CreditsStoreView: View {
    @Environment(StoreKitPaymentManager.self) private var paymentManager
    @Environment(UsageTracker.self) private var usageTracker
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = CreditsStoreViewModel()

    var body: some View {
        NavigationStack {
            List {
                balancesContent

                switch paymentManager.productsState {
                case .idle, .loading:
                    HStack {
                        ProgressView()
                        Text("Loading store…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .failed:
                    storeUnavailableContent
                case .loaded(let products):
                    packSection(
                        title: "Recommendations",
                        footer: "Used when your monthly free recommendations run out. Purchased credits never expire.",
                        creditType: .recommendation,
                        products: products
                    )
                    packSection(
                        title: "Try-On Renders",
                        footer: "Used when your monthly free try-ons run out. Purchased credits never expire.",
                        creditType: .tryOn,
                        products: products
                    )
                }

                feedbackContent
            }
            .navigationTitle("Buy Credits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await paymentManager.loadProducts() }
        }
    }

    /// Current purchased balances, straight from the shared `UsageTracker`
    /// read-model (`purchased*Balance` on `users/{uid}/meta/usage`) — the
    /// same source `AccountSectionView`'s readout uses, so a fresh grant
    /// shows up here the moment `refreshUsage()` lands.
    private var balancesContent: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(usageTracker.purchasedRecommendationsRemaining) purchased recommendations remaining")
                Text("\(usageTracker.purchasedCombinationsRemaining) purchased try-ons remaining")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// StoreKit returning nothing (no `.storekit` config selected in the
    /// scheme, no App Store Connect products yet, or a transient store
    /// outage) — always an explicit state with a retry, never a blank store.
    @ViewBuilder
    private var storeUnavailableContent: some View {
        Text("The store is unavailable right now.")
            .font(.caption)
            .foregroundStyle(.secondary)
        Button {
            Task { await paymentManager.loadProducts() }
        } label: {
            Label("Retry", systemImage: "arrow.clockwise")
        }
    }

    private func packSection(title: String, footer: String, creditType: CreditType, products: [Product]) -> some View {
        Section {
            ForEach(products.filter { CreditCatalog.pack(forProductID: $0.id)?.creditType == creditType }, id: \.id) { product in
                packRow(for: product)
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }

    private func packRow(for product: Product) -> some View {
        Button {
            Task { await viewModel.purchase(product, using: paymentManager) }
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(product.displayName.isEmpty ? product.id : product.displayName)
                    if let pack = CreditCatalog.pack(forProductID: product.id) {
                        Text("\(pack.amount) credits")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if viewModel.purchasingProductID == product.id {
                    ProgressView()
                } else {
                    Text(product.displayPrice)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(viewModel.purchasingProductID != nil || paymentManager.isPurchasing)
    }

    @ViewBuilder
    private var feedbackContent: some View {
        switch viewModel.feedback {
        case .none:
            EmptyView()
        case .granted:
            Label("Credits added to your account.", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .pending:
            Label("Waiting for approval — credits will arrive automatically once approved.", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
