import Foundation

struct FeatureNotFoundError: Error {
    let featureId: Feature.Id
}
