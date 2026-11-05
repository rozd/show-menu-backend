import Foundation
import Testing
import FirestoreAPI
@testable import ShowMenuBackend

@Suite("User aggregate and Node schema")
struct UserTests {

    private func makeUser(accounts: [String] = []) -> User {
        User(id: User.Id(rawValue: "u-1"), email: "a@example.com", accounts: accounts)
    }

    @Test("addAccount appends once and is idempotent")
    func addAccount_idempotent() {
        let user = makeUser()
        user.addAccount("account-1")
        user.addAccount("account-1")
        user.addAccount("account-2")
        #expect(user.accounts == ["account-1", "account-2"])
        #expect(user.pullEvents().map(\.kind) == [.userAccountAdded, .userAccountAdded])
    }

    @Test("a duplicate addAccount leaves updatedAt and events untouched")
    func addAccount_duplicateIsNoOp() {
        let created = Date(timeIntervalSince1970: 1_000)
        let user = User(id: User.Id(rawValue: "u-1"), accounts: ["account-1"], createdAt: created)
        user.addAccount("account-1", now: Date(timeIntervalSince1970: 2_000))
        #expect(user.updatedAt == created)
        #expect(user.pullEvents().isEmpty)
    }

    @Test("removeAccount removes once and is idempotent")
    func removeAccount_idempotent() {
        let user = makeUser(accounts: ["account-1", "account-2"])
        user.removeAccount("account-1")
        user.removeAccount("account-1")
        user.removeAccount("never-linked")
        #expect(user.accounts == ["account-2"])
        #expect(user.pullEvents().map(\.kind) == [.userAccountRemoved])
    }

    @Test("mapper round-trips every Node field, with millisecond Timestamps")
    func mapper_roundTrip() throws {
        let mapper = UserMapper()
        let created = Date(timeIntervalSince1970: 1_767_225_600.123)
        let updated = Date(timeIntervalSince1970: 1_767_225_700.456)
        let user = User(
            id: User.Id(rawValue: "u-1"), email: "a@example.com", name: "Alice",
            avatarURL: "https://x/y.png", accounts: ["account-1"], createdAt: created, updatedAt: updated
        )

        let model = mapper.toModel(entity: user)
        #expect(model.id == "u-1")
        #expect(model.email == "a@example.com")
        #expect(model.name == "Alice")
        #expect(model.avatarURL == "https://x/y.png")
        #expect(model.accounts == ["account-1"])
        #expect(model.disabled == nil)
        #expect(model.createdAt?.nanos == 123_000_000)
        #expect(model.updatedAt?.nanos == 456_000_000)

        let back = try mapper.toEntity(model: model)
        #expect(back.accounts == ["account-1"])
        #expect(back.createdAt.timeIntervalSince1970 == created.timeIntervalSince1970)
        #expect(back.updatedAt.timeIntervalSince1970 == updated.timeIntervalSince1970)
    }

    @Test("encodes Node's document shape: plain id, explicit nulls, no template extras")
    func model_encodesNodeShape() throws {
        let model = UserMapper().toModel(entity: User(id: User.Id(rawValue: "u-1"), email: "a@example.com"))
        let data = try FirestoreEncoder().encode(model)
        // `version` (additive) is absent until the repository establishes it; `disabled` only when true.
        #expect(Set(data.keys) == ["id", "email", "name", "avatarURL", "accounts", "createdAt", "updatedAt"])
        #expect(data["id"] as? String == "u-1")
        #expect(data["name"] is NSNull)
        #expect(data["avatarURL"] is NSNull)
        #expect((data["accounts"] as? [Any])?.isEmpty == true)
    }

    @Test("decodes a Node-written document (no version, no disabled)")
    func model_decodesNodeDocument() throws {
        let ts = Timestamp(seconds: 1_767_225_600, nanos: 123_000_000)
        let node: [String: Any] = [
            "id": "u-9", "email": "n@example.com", "name": NSNull(), "avatarURL": NSNull(),
            "accounts": ["account-7"], "createdAt": ts, "updatedAt": ts,
        ]
        let model = try FirestoreDecoder().decode(UserModel.self, from: node)
        let user = try UserMapper().toEntity(model: model)
        #expect(user.id.rawValue == "u-9")
        #expect(user.accounts == ["account-7"])
        #expect(user.version == .none)
        #expect(user.disabled == false)
        #expect(user.name == nil)
    }
}
