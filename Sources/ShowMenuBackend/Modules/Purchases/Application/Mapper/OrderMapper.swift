import Foundation
import FirestoreAPI

struct OrderMapper: Mapper, Sendable {
    typealias Entity = Order
    typealias Model = OrderModel
    typealias DTO = OrderDTO

    init() {}

    func toModel(entity: Order) -> OrderModel {
        OrderModel(
            id: entity.id.rawValue,
            createdAt: Timestamp(exact: entity.createdAt),
            updatedAt: Timestamp(exact: entity.updatedAt),
            accountId: entity.accountId,
            customerId: entity.customerId.rawValue,
            lineItems: entity.lineItems,
            discounts: entity.discounts,
            shipment: entity.shipment,
            customer: entity.customer,
            status: entity.status,
            userInfo: entity.userData,
            invoiceId: entity.invoiceId?.rawValue,
            version: entity.version.versionInt
        )
    }

    func toEntity(model: OrderModel) throws -> Order {
        Order(
            id: Order.Id(rawValue: model.id),
            accountId: model.accountId,
            customerId: User.Id(rawValue: model.customerId),
            lineItems: model.lineItems,
            discounts: model.discounts,
            shipment: model.shipment,
            customer: model.customer,
            userData: model.userInfo,
            status: model.status,
            invoiceId: model.invoiceId.map { Invoice.Id(rawValue: $0) },
            version: Version(versionInt: model.version),
            createdAt: model.createdAt.asDate,
            updatedAt: model.updatedAt.asDate
        )
    }

    func toDTO(entity: Order) -> OrderDTO {
        OrderDTO(
            id: entity.id.rawValue,
            accountId: entity.accountId,
            customerId: entity.customerId.rawValue,
            status: entity.status.rawValue,
            invoiceId: entity.invoiceId?.rawValue,
            createdAt: FeatureMapper.iso(entity.createdAt),
            updatedAt: FeatureMapper.iso(entity.updatedAt)
        )
    }

    func toDTO(model: OrderModel) -> OrderDTO {
        OrderDTO(
            id: model.id,
            accountId: model.accountId,
            customerId: model.customerId,
            status: model.status.rawValue,
            invoiceId: model.invoiceId,
            createdAt: FeatureMapper.iso(model.createdAt.asDate),
            updatedAt: FeatureMapper.iso(model.updatedAt.asDate)
        )
    }
}
