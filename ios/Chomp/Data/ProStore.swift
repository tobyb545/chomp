import Foundation
import Observation
import RevenueCat

/// Chomp Pro via RevenueCat. Pro never affects capturing or defending streets;
/// it only unlocks clubs, stats, cosmetics and imports/exports. The whole map is free.
@MainActor
@Observable
final class ProStore {
    static let entitlement = "pro"

    enum Feature: String, CaseIterable, Identifiable {
        case clubs, stats, customColours, trails, replayExport
        var id: String { rawValue }
        var title: String {
            switch self {
            case .clubs: "Clubs & club battles"
            case .stats: "Detailed stats & heatmaps"
            case .customColours: "Any colour you like"
            case .trails: "Custom run trails"
            case .replayExport: "Export run replays"
            }
        }
        var symbol: String {
            switch self {
            case .clubs: "person.3.fill"
            case .stats: "chart.xyaxis.line"
            case .customColours: "paintpalette.fill"
            case .trails: "scribble.variable"
            case .replayExport: "film.stack"
            }
        }
    }

    private(set) var isPro = false
    private(set) var packages: [Package] = []
    private(set) var isConfigured = false
    /// A purchase or restore that failed, in words the user can act on.
    var lastError: String?
    /// The App Store prices couldn't be loaded (offline, or the products aren't set up yet).
    private(set) var pricesUnavailable = false
    /// RevenueCat's own explanation, shown only in debug builds.
    private(set) var pricesErrorDetail: String?
    /// Debug-only override so every screen can be checked without a sandbox purchase.
    var debugOverride = false { didSet { refreshDerived() } }
    private var purchasedPro = false
    /// Free Pro earned through invites (granted by the server, not the App Store).
    var invitePro: Date? { didSet { refreshDerived() } }
    var invitePremiumActive: Bool { (invitePro ?? .distantPast) > .now }

    init() {
        let key = (Bundle.main.infoDictionary?["RevenueCatAPIKey"] as? String) ?? ""
        guard !key.isEmpty else { return }
        Purchases.logLevel = .warn
        Purchases.configure(withAPIKey: key)
        isConfigured = true
    }

    private func refreshDerived() {
        #if DEBUG
        isPro = purchasedPro || invitePremiumActive || debugOverride
        #else
        isPro = purchasedPro || invitePremiumActive
        #endif
    }

    func identify(userID: String) async {
        guard isConfigured else { return }
        _ = try? await Purchases.shared.logIn(userID)
        await refresh()
    }

    func refresh() async {
        guard isConfigured else { refreshDerived(); return }
        pricesUnavailable = false
        pricesErrorDetail = nil
        if let info = try? await Purchases.shared.customerInfo() {
            purchasedPro = info.entitlements[Self.entitlement]?.isActive == true
        }
        do {
            let offerings = try await Purchases.shared.offerings()
            packages = offerings.current?.availablePackages ?? []
            if packages.isEmpty { pricesUnavailable = true; pricesErrorDetail = "No current offering, or it has no packages." }
        } catch {
            pricesUnavailable = true
            pricesErrorDetail = error.localizedDescription
        }
        refreshDerived()
    }

    func purchase(_ package: Package) async {
        lastError = nil
        do {
            let result = try await Purchases.shared.purchase(package: package)
            if !result.userCancelled {
                purchasedPro = result.customerInfo.entitlements[Self.entitlement]?.isActive == true
            }
        } catch {
            lastError = error.localizedDescription
        }
        refreshDerived()
    }

    func restore() async {
        guard isConfigured else { return }
        lastError = nil
        do {
            let info = try await Purchases.shared.restorePurchases()
            purchasedPro = info.entitlements[Self.entitlement]?.isActive == true
        } catch {
            lastError = error.localizedDescription
        }
        refreshDerived()
    }
}
