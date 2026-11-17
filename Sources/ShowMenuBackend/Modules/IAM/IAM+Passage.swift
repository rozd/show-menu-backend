//
//  IAM+Passage.swift
//  ShowMenuBackend
//
//  Bridges Passage's account lifecycle into the IAM module.
//

import Passage
import Vapor

/// Translates Passage account lifecycle into the IAM module's integration
/// events — the same events an external identity provider's webhook would
/// produce (see `UserCreatedIntegrationEvent`), so Passage stays replaceable
/// by an out-of-process IdP with zero changes to the IAM module itself.
///
/// In overlay mode the event is a **downstream contract, not the provisioning
/// mechanism**: registration already created the row in the shared `users`
/// table (`PassageUserRecord.passageMakeUser`, atomically with its identifier),
/// so `UserCreatedIntegrationEventHandler`'s onboard early-returns idempotently
/// and the event exists for any other consumer that cares that a user appeared.
struct IAMProvisioningHooks: Passage.Hooks.Account {

    let channel: any IntegrationEventChannel

    /// Post-registration observer. Runs after Passage commits the account, so
    /// a crash in between can lose the event — tolerable in overlay mode, since
    /// the user row itself was created transactionally by the store and only
    /// the notification is best-effort.
    func didRegister(user: any Passage::User, on request: Request) async {
        guard let userId = user.identifierString else {
            request.logger.error("Passage registered a user without an id; skipping IAM onboarding")
            return
        }
        await channel.publish(
            UserCreatedIntegrationEvent(
                userId: userId,
                email: user.email,
                displayName: nil,
                correlationId: RequestContext.traceId
            )
        )
    }
}
