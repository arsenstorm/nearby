import Foundation
import StoreKit

/// What the Worker will mint TURN credentials for, and the Apple-signed JWS that proves it (PRD R2–R5).
enum RelayEntitlement: Equatable, Sendable {
    case freeDirectOnly
    case subscriber(expires: Date?)
    case beta

    typealias Proof = (state: RelayEntitlement, jws: String?)

    static let productID = "com.arsenstorm.nearby.plus.monthly"

    /// StoreKit can take a minute or more to answer (it goes to the App Store), which is longer than
    /// the relay renewal lead, so the last answer is served at once and refreshed behind it.
    private static let cache = Cache()

    static func current() async -> Proof {
        await cache.current()
    }

    private actor Cache {
        private var proof: Proof? = Cache.stored()
        private var refreshing = false

        func current() async -> Proof {
            if let proof {
                refresh()
                return proof
            }
            proof = await fetch()
            store(proof!)
            return proof!
        }

        private func refresh() {
            guard !refreshing else { return }
            refreshing = true
            Task {
                let fresh = await fetch()
                proof = fresh
                store(fresh)
                refreshing = false
            }
        }

        // The JWS is this device's own Apple-signed receipt; keeping it lets the first relay after a
        // launch go out before StoreKit has answered.
        private static let key = "relay.entitlement"

        private static func stored() -> Proof? {
            guard let saved = UserDefaults.standard.dictionary(forKey: key),
                  let kind = saved["kind"] as? String
            else { return nil }
            switch kind {
            case "subscriber": return (.subscriber(expires: saved["expires"] as? Date), saved["jws"] as? String)
            case "beta": return (.beta, saved["jws"] as? String)
            default: return (.freeDirectOnly, nil)
            }
        }

        private func store(_ proof: Proof) {
            var saved: [String: Any] = ["jws": proof.jws as Any]
            switch proof.state {
            case .subscriber(let expires):
                saved["kind"] = "subscriber"
                saved["expires"] = expires as Any
            case .beta: saved["kind"] = "beta"
            case .freeDirectOnly: saved["kind"] = "free"
            }
            UserDefaults.standard.set(saved, forKey: Self.key)
        }
    }

    private static func fetch() async -> Proof {
        if let subscriber = await subscription() { return subscriber }
        if let beta = await betaBuild() { return beta }
        return (.freeDirectOnly, nil)
    }

    private static func subscription() async -> Proof? {
        for await result in Transaction.currentEntitlements(for: productID) {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil,
                  transaction.expirationDate.map({ $0 > Date() }) ?? true
            else { continue }
            return (.subscriber(expires: transaction.expirationDate), result.jwsRepresentation)
        }
        return nil
    }

    /// A sandbox or Xcode receipt is what a TestFlight or dev build carries instead of a purchase.
    private static func betaBuild() async -> Proof? {
        guard let result = try? await AppTransaction.shared,
              case .verified(let app) = result,
              app.environment == .sandbox || app.environment == .xcode
        else { return nil }
        return (.beta, result.jwsRepresentation)
    }
}
