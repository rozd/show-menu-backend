import Foundation
import FirestoreAPI

struct InvoiceMapper: Mapper, Sendable {
    typealias Entity = Invoice
    typealias Model = InvoiceModel
    typealias DTO = InvoiceDTO

    init() {}

    func toModel(entity: Invoice) -> InvoiceModel {
        InvoiceModel(
            id: entity.id.rawValue,
            createdAt: Timestamp(exact: entity.createdAt),
            updatedAt: Timestamp(exact: entity.updatedAt),
            orderId: entity.orderId.rawValue,
            accountId: entity.accountId,
            customerId: entity.customerId.rawValue,
            transactionId: entity.transactionId,
            status: entity.status,
            issueDate: Timestamp(exact: entity.issueDate),
            dueDate: entity.dueDate.map { Timestamp(exact: $0) },
            orderDate: Timestamp(exact: entity.orderDate),
            customer: entity.customer,
            shipmentMethod: entity.shipment.method,
            shipmentAddress: entity.shipment.address,
            lineItems: entity.lineItems,
            discounts: entity.discounts,
            version: entity.version.versionInt
        )
    }

    func toEntity(model: InvoiceModel) throws -> Invoice {
        Invoice(
            id: Invoice.Id(rawValue: model.id),
            orderId: Order.Id(rawValue: model.orderId),
            accountId: model.accountId,
            customerId: User.Id(rawValue: model.customerId),
            transactionId: model.transactionId,
            status: model.status,
            lineItems: model.lineItems,
            discounts: model.discounts,
            orderDate: model.orderDate.asDate,
            issueDate: model.issueDate.asDate,
            dueDate: model.dueDate?.asDate,
            customer: model.customer,
            shipment: ShipmentInfo(method: model.shipmentMethod, address: model.shipmentAddress),
            version: Version(versionInt: model.version),
            createdAt: model.createdAt.asDate,
            updatedAt: model.updatedAt.asDate
        )
    }

    func toDTO(entity: Invoice) -> InvoiceDTO {
        InvoiceDTO(
            id: entity.id.rawValue,
            orderId: entity.orderId.rawValue,
            accountId: entity.accountId,
            customerId: entity.customerId.rawValue,
            status: entity.status.rawValue,
            transactionId: entity.transactionId,
            createdAt: FeatureMapper.iso(entity.createdAt),
            updatedAt: FeatureMapper.iso(entity.updatedAt)
        )
    }

    func toDTO(model: InvoiceModel) -> InvoiceDTO {
        InvoiceDTO(
            id: model.id,
            orderId: model.orderId,
            accountId: model.accountId,
            customerId: model.customerId,
            status: model.status.rawValue,
            transactionId: model.transactionId,
            createdAt: FeatureMapper.iso(model.createdAt.asDate),
            updatedAt: FeatureMapper.iso(model.updatedAt.asDate)
        )
    }
}
