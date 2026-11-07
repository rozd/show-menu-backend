import Foundation
import Logging
import ShowMenuContracts
import Testing
import FirestoreAPI
@testable import ShowMenuBackend

@Suite("User controller (wire)")
struct UserControllerTests {

    private func makeController(_ ds: InMemoryDataSource<UserModel>) -> UserController {
        let logger = Logger(label: "test", factory: { _ in CapturingLogHandler() })
        return UserController(
            getUserQueryHandler: .init(dataSourceFactory: { _, _ in ds }, transaction: .stub, mapper: UserMapper(), logger: logger),
            findUserQueryHandler: .init(dataSourceFactory: { _, _ in ds }, transaction: .stub, mapper: UserMapper(), logger: logger),
            logger: logger
        )
    }

    @Test("getUser for an unknown id throws, rendered as the not_found envelope")
    func getUserNotFound() async throws {
        let controller = makeController(InMemoryDataSource<UserModel>(id: { $0.id }))
        do {
            _ = try await controller.getUser(.init(path: .init(userId: "missing")))
            Issue.record("expected not found")
        } catch {
            let mapping = HTTPErrorMapping.map(error)
            #expect(mapping.status == .notFound)
            #expect(mapping.code == "not_found")
        }
    }

    @Test("getUser maps the user, omitting absent optionals and parsing dates")
    func getUser() async throws {
        let ds = InMemoryDataSource<UserModel>(id: { $0.id })
        let created = Date(timeIntervalSince1970: 1_736_935_200.5)
        await ds.seed(UserModel(
            id: "u1", email: "a@example.com", name: nil, accounts: ["acc-1"],
            createdAt: Timestamp(exact: created), updatedAt: nil
        ))
        let controller = makeController(ds)

        guard case let .ok(ok) = try await controller.getUser(.init(path: .init(userId: "u1"))),
              case let .json(user) = ok.body else {
            Issue.record("Expected 200 JSON")
            return
        }
        #expect(user.id == "u1" && user.email == "a@example.com" && user.name == nil)
        #expect(user.accounts == ["acc-1"])
        #expect(user.createdAt == created)
        #expect(user.updatedAt == nil)
    }

    @Test("findUsers needs at least one filter (400), and answers a bare array")
    func findUsers() async throws {
        let ds = InMemoryDataSource<UserModel>(id: { $0.id })
        await ds.seed(UserModel(id: "u1", email: "a@example.com", name: "Ann", accounts: []))
        let controller = makeController(ds)

        do {
            _ = try await controller.findUsers(.init())
            Issue.record("expected 400")
        } catch {
            #expect(HTTPErrorMapping.map(error).status == .badRequest)
        }

        guard case let .ok(ok) = try await controller.findUsers(.init(query: .init(email: "a@example.com"))),
              case let .json(users) = ok.body else {
            Issue.record("Expected 200 JSON")
            return
        }
        #expect(users.map(\.id) == ["u1"])
    }
}
