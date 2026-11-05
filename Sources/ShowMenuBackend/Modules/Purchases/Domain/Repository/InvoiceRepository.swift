import Foundation

protocol InvoiceRepository: Repository where Entity == Invoice, Model == InvoiceModel, DTO == InvoiceDTO {
}
