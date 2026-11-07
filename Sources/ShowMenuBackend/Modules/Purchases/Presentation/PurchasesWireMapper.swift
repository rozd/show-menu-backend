import ShowMenuContracts

/// Purchases' mapping from the generated wire request to the command payload.
enum PurchasesWireMapper {

    static func payload(_ body: Components.Schemas.PurchaseRequest) -> PurchaseSubscriptionCommand.Payload {
        let price = body.price.price
        return .init(
            planId: body.planId,
            price: .init(
                price: .init(
                    currencyName: price.currencyName,
                    currencySymbol: price.currencySymbol,
                    currencyBase: price.currencyBase,
                    currencyDigits: price.currencyDigits,
                    amount: price.amount
                ),
                duration: body.price.duration.rawValue
            )
        )
    }
}
