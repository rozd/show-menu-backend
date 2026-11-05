import Foundation
import FirestoreAPI

struct SubscriptionMapper: Mapper, Sendable {
    typealias Entity = Subscription
    typealias Model = SubscriptionModel
    typealias DTO = SubscriptionDTO

    init() {}

    func toModel(entity: Subscription) -> SubscriptionModel {
        SubscriptionModel(
            id: entity.id.rawValue,
            createdAt: Timestamp(exact: entity.createdAt),
            updatedAt: Timestamp(exact: entity.updatedAt),
            planId: entity.planId,
            orderId: entity.orderId,
            accountId: entity.accountId,
            status: entity.status,
            startedAt: Timestamp(exact: entity.startedAt),
            expiresAt: Timestamp(exact: entity.expiresAt),
            suspensionReason: entity.suspensionReason,
            cancellationReason: entity.cancellationReason,
            lastPaymentRef: entity.lastPaymentRef,
            version: entity.version.versionInt
        )
    }

    func toEntity(model: SubscriptionModel) throws -> Subscription {
        Subscription(
            id: Subscription.Id(rawValue: model.id),
            planId: model.planId,
            orderId: model.orderId,
            accountId: model.accountId,
            status: model.status,
            startedAt: model.startedAt.asDate,
            expiresAt: model.expiresAt.asDate,
            suspensionReason: model.suspensionReason,
            cancellationReason: model.cancellationReason,
            lastPaymentRef: model.lastPaymentRef,
            version: Version(versionInt: model.version),
            createdAt: model.createdAt.asDate,
            updatedAt: model.updatedAt.asDate
        )
    }

    func toDTO(entity: Subscription) -> SubscriptionDTO {
        SubscriptionDTO(
            id: entity.id.rawValue, accountId: entity.accountId, planId: entity.planId, orderId: entity.orderId,
            status: entity.status.rawValue, startedAt: FeatureMapper.iso(entity.startedAt),
            expiresAt: FeatureMapper.iso(entity.expiresAt)
        )
    }

    func toDTO(model: SubscriptionModel) -> SubscriptionDTO {
        SubscriptionDTO(
            id: model.id, accountId: model.accountId, planId: model.planId, orderId: model.orderId,
            status: model.status.rawValue, startedAt: FeatureMapper.iso(model.startedAt.asDate),
            expiresAt: FeatureMapper.iso(model.expiresAt.asDate)
        )
    }
}
