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
        case clubs, stats, customColours, trails, stravaImport, replayExport
        var id: String { rawValue }
        var title: String {
            switch self {
            case .clubs: "Clubs & club battles"
            case .stats: "Detailed stats & heatmaps"
            case .customColours: "Any colour you like"
            case .trails: "Custom run trails"
            case .stravaImport: "Strava history import"
            case .replayExport: "Export run replays"
            }
        }
        var symbol: String {
            switch self {
            case .clubs: "person.3.fill"
            case .stats: "chart.xyaxis.line"
            case .customColours: "paintpalette.fill"
            case .trails: "scribble.variable"
            case .stravaImport: "arrow.down.circle"
            case .replayExport: "film.stack"
            }
        }
    }

    private(set) var isPro = false
    private(set) var packages: [Package] = []
    private(set) var isConfigured = false
    var lastError: String?
    /// Debug-only override so every screen can be checked without a sandbox purchase.
    var debugOverride = false { didSet { refreshDerived() } }
    private var purchasedPro = false

    init() {
        let key = (Bundle.main.infoDictionary?["RevenueCatAPIKey"] as? String) ?? ""
        guard !key.isEmpty else { return }
        Purchases.logLevel = .warn
        Purchases.configure(withAPIKey: key)
        isConfigured = true
    }

    private func refreshDerived() {
        #if DEBUG
        isPro = purchasedPro || debugOverride
        #else
        isPro = purchasedPro
        #endif
    }

    func identify(userID: String) async {
        guard isConfigured else { return }
        _ = try? await Purchases.shared.logIn(userID)
        await refresh()
    }

    func refresh() async {
        guard isConfigured else { refreshDerived(); return }
        do {
            let info = try await Purchases.shared.customerInfo()
            purchasedPro = info.entitlements[Self.entitlement]?.isActive == true
            let offerings = try await Purchases.shared.offerings()
            packages = offerings.current?.availablePackages ?? []
        } catch {
            lastError = error.localizedDescription
        }
        refreshDerived()
    }

    func purchase(_ package: Package) async {
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
        do {
            let info = try await Purchases.shared.restorePurchases()
            purchasedPro = info.entitlements[Self.entitlement]?.isActive == true
        } catch {
            lastError = error.localizedDescription
        }
        refreshDerived()
    }
}
