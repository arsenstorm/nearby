import Foundation
import StoreKit

/// What the Worker will mint TURN credentials for, and the Apple-signed JWS that proves it (PRD R2–R5).
enum RelayEntitlement: Equatable, Sendable {
    case freeDirectOnly
    case subscriber(expires: Date?)
    case beta

    typealias Proof = (state: RelayEntitlement, jws: String?)

    static let productID = "com.arsenstorm.nearby.plus.monthly"

    static func current() async -> Proof {
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
