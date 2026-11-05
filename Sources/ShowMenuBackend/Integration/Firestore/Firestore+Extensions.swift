import Foundation
import FirestoreAPI

// MARK: - DocumentID

extension DocumentID: @unchecked @retroactive Sendable where Value: Sendable {}

// MARK: - GeoPoint

extension GeoPoint: @unchecked @retroactive Sendable {}

// MARK: - Timestamp and Date

extension Timestamp {

    init?(_ date: Date?) {
        guard let date = date else { return nil }
        self.init(date)
    }
}

extension Date {

    init?(_ timestamp: Timestamp?) {
        guard let timestamp = timestamp else { return nil }
        self.init(timestamp: timestamp)
    }
}
