//
//  StoreKitPaymentManager.swift
//  Vision_clother
//
//  StoreKit 2 consumable credit top-ups (docs/timeline.md, 2026-07-17). The
//  app-root-owned owner of the whole purchase lifecycle: product fetch,
//  purchase, server verification (`Services/IAPVerificationService.swift` →
//  `backend/functions/src/routes/iapVerify.ts`), and the background
//  redelivery paths. Constructed once in `Vision_clotherApp.init()` and
//  retained for the app's lifetime, same posture as `UsageTracker`.
//
//  The load-bearing contract — when `Transaction.finish()` is called:
//  ONLY after the backend confirms the ledger outcome (`granted: true`,
//  including idempotent `alreadyProcessed` replays, or `granted: false,
//  reason: "revoked"`). Anything else leaves the transaction unfinished, so
//  StoreKit durably redelivers it — via `Transaction.unfinished` at launch
//  and `Transaction.updates` live (the two are complementary: `updates` does
//  NOT replay transactions that were already unfinished before the listener
//  started). The backend's `processedTransactions/{transactionId}` ledger
//  makes redelivery idempotent, so "paid but the network died before the
//  server confirmed" self-heals with no double credit.
//
//  Poison-pill throttle: a permanently-rejected transaction (e.g. a catalog
//  bug server-side) must not hammer `/iap/verify` on every scenePhase
//  cycle. `attemptedTransactionIDs` caps server submissions at one per
//  transaction per app session; a fresh launch retries naturally.
//  Deliberate exception: a skip for missing/anonymous auth does NOT enter
//  the set, so a purchase can still redeem later in the same session once
//  the user links an account.
//
//  Redaction: never log the JWS — transaction ids and product ids only.
//

import Foundation
import Observation
import StoreKit

@MainActor
@Observable
final class StoreKitPaymentManager {
    enum ProductsState {
        case idle
        case loading
        case loaded([Product])
        case failed
    }

    enum PurchaseOutcome: Equatable {
        case granted
        case pending
        case cancelled
        case failed(String)
    }

    private(set) var productsState: ProductsState = .idle
    private(set) var isPurchasing = false

    /// Factory closure (not a captured instance) so every verification call
    /// re-resolves through `ServiceFactory`'s auth gate — the same
    /// stale-snapshot dodge the `AuthGated*` wrappers exist for, without a
    /// dedicated wrapper type for this one-call service.
    private let verificationService: () -> IAPVerificationService
    /// Wired to `usageTracker.refreshUsage()` at the composition root
    /// (`Vision_clotherApp.init()`) — this type never touches `UsageTracker`
    /// directly.
    private let onCreditsGranted: @MainActor () async -> Void

    private var updatesTask: Task<Void, Never>?
    private var attemptedTransactionIDs: Set<UInt64> = []

    init(
        verificationService: @escaping () -> IAPVerificationService,
        onCreditsGranted: @escaping @MainActor () async -> Void
    ) {
        self.verificationService = verificationService
        self.onCreditsGranted = onCreditsGranted
    }

    /// Call once at app start. Spawns the lifetime `Transaction.updates`
    /// listener (Ask to Buy approvals, interrupted purchases completing,
    /// cross-device redeliveries) and replays any transactions left
    /// unfinished by a previous session.
    func start() {
        guard updatesTask == nil else { return }
        AppLog.info(.payments, "StoreKitPaymentManager.start: listening for transaction updates")
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                _ = await self?.handle(update)
            }
        }
        Task { await self.replayUnfinished() }
    }

    /// Also called on every scenePhase `.active` — cheap when there's
    /// nothing pending, and `attemptedTransactionIDs` keeps repeated cycles
    /// from re-hitting the server for the same stuck transaction.
    func replayUnfinished() async {
        for await verification in Transaction.unfinished {
            _ = await handle(verification)
        }
    }

    func loadProducts() async {
        if case .loading = productsState { return }
        productsState = .loading
        do {
            let products = try await Product.products(for: CreditCatalog.allProductIDs)
            guard !products.isEmpty else {
                // Empty (not thrown) is StoreKit's shape for "no .storekit
                // config selected / no App Store Connect products" — surface
                // it as a failure, never a silently blank store.
                AppLog.error(.payments, "loadProducts: no products returned for \(CreditCatalog.allProductIDs.count) requested ids")
                productsState = .failed
                return
            }
            // StoreKit returns products in no guaranteed order — present
            // them in catalog order.
            let order = Dictionary(uniqueKeysWithValues: CreditCatalog.allProductIDs.enumerated().map { ($1, $0) })
            let sorted = products.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
            AppLog.info(.payments, "loadProducts: loaded \(sorted.count) products")
            productsState = .loaded(sorted)
        } catch {
            AppLog.error(.payments, "loadProducts: failed — \(String(describing: error))")
            productsState = .failed
        }
    }

    func purchase(_ product: Product) async -> PurchaseOutcome {
        guard !isPurchasing else { return .failed("Another purchase is already in progress.") }
        isPurchasing = true
        defer { isPurchasing = false }

        AppLog.notice(.payments, "purchase: starting \(product.id)")
        let result: Product.PurchaseResult
        do {
            result = try await product.purchase()
        } catch {
            AppLog.error(.payments, "purchase: \(product.id) threw — \(String(describing: error))")
            return .failed("The purchase couldn't be started. Try again.")
        }

        switch result {
        case .userCancelled:
            AppLog.info(.payments, "purchase: \(product.id) cancelled by user")
            return .cancelled
        case .pending:
            // Ask to Buy — the approved transaction arrives later via
            // Transaction.updates; nothing to persist here.
            AppLog.notice(.payments, "purchase: \(product.id) pending approval")
            return .pending
        case .success(let verification):
            return await handle(verification)
        @unknown default:
            AppLog.error(.payments, "purchase: \(product.id) unknown result case")
            return .failed("Unknown purchase result. If you were charged, credits will arrive automatically.")
        }
    }

    // MARK: - Verification pipeline

    /// The single funnel every transaction goes through, whichever door it
    /// arrived by (fresh purchase, updates listener, unfinished replay).
    private func handle(_ verification: VerificationResult<Transaction>) async -> PurchaseOutcome {
        let transaction: Transaction
        switch verification {
        case .verified(let t):
            transaction = t
        case .unverified(let t, let error):
            // Local verification failing is logged but NOT fatal — the
            // backend's signature check is the authority, and swallowing the
            // transaction here would strand a possibly-real purchase.
            AppLog.notice(.payments, "handle: transaction \(t.id) locally unverified (\(String(describing: error))) — deferring to server")
            transaction = t
        }

        // Only consumable credit packs belong to this pipeline.
        guard CreditCatalog.pack(forProductID: transaction.productID) != nil else {
            AppLog.error(.payments, "handle: transaction \(transaction.id) has unknown product \(transaction.productID) — finishing to clear the queue")
            await transaction.finish()
            return .failed("Unknown product.")
        }

        guard AuthService.shared.isSignedIn, !AuthService.shared.isAnonymous else {
            // Leave unfinished AND out of the throttle set: redeemable later
            // this same session, the moment a linked session exists.
            AppLog.notice(.payments, "handle: transaction \(transaction.id) deferred — no linked account session")
            return .failed("Sign in to redeem your purchase. It will be credited automatically.")
        }

        guard !attemptedTransactionIDs.contains(transaction.id) else {
            AppLog.info(.payments, "handle: transaction \(transaction.id) already attempted this session — skipping")
            return .failed("This purchase is still being processed. It will be retried on next launch.")
        }
        attemptedTransactionIDs.insert(transaction.id)

        let grant: IAPGrantResult
        do {
            grant = try await verificationService().verify(jws: verification.jwsRepresentation)
        } catch let error as IAPVerificationError {
            switch error {
            case .notSignedIn:
                // Auth evaporated between the guard above and the call —
                // treat like the anonymous case: retryable this session.
                attemptedTransactionIDs.remove(transaction.id)
                AppLog.notice(.payments, "handle: transaction \(transaction.id) deferred — session lost mid-flight")
            case .network, .serverUnavailable:
                AppLog.error(.payments, "handle: transaction \(transaction.id) verification unreachable — left unfinished for redelivery")
            case .rejected(let code):
                // Do NOT finish: a server-side catalog/config bug must not
                // eat a real purchase. The throttle bounds retries to one
                // per session; a fixed backend deploy makes the next launch's
                // replay succeed.
                AppLog.error(.payments, "handle: transaction \(transaction.id) rejected (\(code)) — left unfinished, throttled")
            }
            return .failed(error.errorDescription ?? "Verification failed. It will be retried automatically.")
        } catch {
            AppLog.error(.payments, "handle: transaction \(transaction.id) unexpected error — \(String(describing: error))")
            return .failed("Verification failed. It will be retried automatically.")
        }

        if grant.granted {
            await transaction.finish()
            AppLog.notice(.payments, "handle: transaction \(transaction.id) granted (alreadyProcessed=\(grant.alreadyProcessed ?? false)) — finished")
            await onCreditsGranted()
            return .granted
        }

        if grant.reason == "revoked" {
            // Refunded purchase, ledgered server-side with no grant —
            // finishing is correct; there is nothing left to redeem.
            await transaction.finish()
            AppLog.notice(.payments, "handle: transaction \(transaction.id) revoked — finished without grant")
            return .failed("This purchase was refunded, so no credits were added.")
        }

        AppLog.error(.payments, "handle: transaction \(transaction.id) not granted (reason=\(grant.reason ?? "none")) — left unfinished")
        return .failed("Verification didn't complete. It will be retried automatically.")
    }
}
