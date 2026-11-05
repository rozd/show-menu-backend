import Foundation
import Testing
import Logging
import FirestoreAPI
@testable import ShowMenuBackend

@Suite("Feature Use Cases")
struct FeatureUseCaseTests {
    let mapper = FeatureMapper()

    private func makeLogger() -> Logger {
        Logger(label: "test", factory: { _ in CapturingLogHandler() })
    }

    private func makeSUT() -> (
        ds: InMemoryDataSource<FeatureModel>,
        collector: InMemoryDomainEventCollector,
        context: StubUnitOfWorkContext
    ) {
        let ds = InMemoryDataSource<FeatureModel>(id: { $0.id })
        let collector = InMemoryDomainEventCollector()
        let ctx = StubUnitOfWorkContext(transaction: "stub", collector: collector)
        return (ds, collector, ctx)
    }

    private func makeRepoFactory(
        ds: InMemoryDataSource<FeatureModel>
    ) -> RepositoryFactory<any FeatureRepository> {
        let mapper = self.mapper
        return { ctx in
            FirestoreFeatureRepository(
                mapper: mapper,
                dataSourceFactory: { _, _ in ds },
                context: ctx
            )
        }
    }

    private func makeCreate(
        _ ds: InMemoryDataSource<FeatureModel>,
        _ ctx: StubUnitOfWorkContext
    ) -> CreateFeatureUseCase {
        CreateFeatureUseCase(context: ctx, repositoryFactory: makeRepoFactory(ds: ds), mapper: mapper, logger: makeLogger())
    }

    private func makeUpdate(
        _ ds: InMemoryDataSource<FeatureModel>,
        _ ctx: StubUnitOfWorkContext
    ) -> UpdateFeatureUseCase {
        UpdateFeatureUseCase(context: ctx, repositoryFactory: makeRepoFactory(ds: ds), mapper: mapper, logger: makeLogger())
    }

    // MARK: - Create

    @Test("create happy path: prefixed id, DTO, one model, lifecycle + semantic events")
    func create_happyPath() async throws {
        let (ds, collector, ctx) = makeSUT()

        let dto = try await makeCreate(ds, ctx).execute(params: .init(
            category: "ai",
            name: ["en": "AI Menu Generator", "uk": "Генератор меню ШІ"],
            description: ["en": "Desc"]
        ))

        #expect(dto.id.hasPrefix("feature-"))
        #expect(dto.category == "ai")
        #expect(dto.name["en"] == "AI Menu Generator")
        #expect(dto.description == ["en": "Desc"])
        #expect(dto.createdAt == dto.updatedAt)

        let inserted = await ds.insertedModels
        #expect(inserted.count == 1)
        #expect(inserted.first?.id == dto.id)

        let kinds = try await collector.drain().map { try #require($0 as? FeatureEvent).kind }
        #expect(kinds.contains(.featureAdded))
        #expect(kinds.contains(.created))
        #expect(kinds.count == 2)
    }

    @Test("create without description succeeds and omits it from the DTO JSON")
    func create_nilDescription() async throws {
        let (ds, _, ctx) = makeSUT()
        let dto = try await makeCreate(ds, ctx).execute(params: .init(
            category: "technicalSupport", name: ["en": "Support"], description: nil
        ))
        #expect(dto.description == nil)
        let json = try String(decoding: JSONEncoder().encode(dto), as: UTF8.self)
        #expect(!json.contains("description"))
    }

    @Test("create validation failures throw Feature.Error / LocalizedString.Error and persist nothing",
          arguments: [
            (nil as String?, ["en": "x"] as [String: String]?, Feature.Error.categoryRequired),
            ("bogus", ["en": "x"], Feature.Error.invalidCategory("bogus")),
            ("ai", nil, Feature.Error.nameRequired),
            ("ai", ["en": "  "], Feature.Error.blankName),
          ])
    func create_validation(category: String?, name: [String: String]?, expected: Feature.Error) async throws {
        let (ds, _, ctx) = makeSUT()
        await #expect(throws: expected) {
            try await makeCreate(ds, ctx).execute(params: .init(category: category, name: name, description: nil))
        }
        #expect(await ds.insertedModels.isEmpty)
    }

    @Test("create with empty name map or blank description is rejected")
    func create_emptyMaps() async {
        let (ds, _, ctx) = makeSUT()
        await #expect(throws: LocalizedString.Error.empty) {
            try await makeCreate(ds, ctx).execute(params: .init(category: "ai", name: [:], description: nil))
        }
        await #expect(throws: Feature.Error.blankDescription) {
            try await makeCreate(ds, ctx).execute(params: .init(category: "ai", name: ["en": "x"], description: ["en": ""]))
        }
    }

    // MARK: - Update

    private func seed(_ ds: InMemoryDataSource<FeatureModel>) async throws -> Feature {
        let feature = try Feature.create(
            category: .ai,
            name: LocalizedString(["en": "Old"]),
            description: LocalizedString(["en": "Old desc"]),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        await ds.seed(mapper.toModel(entity: feature))
        return feature
    }

    @Test("update is partial: absent fields are kept, updatedAt moves, events recorded")
    func update_partial() async throws {
        let (ds, collector, ctx) = makeSUT()
        let feature = try await seed(ds)

        let dto = try await makeUpdate(ds, ctx).execute(params: .init(
            featureId: feature.id, category: nil, name: ["en": "New"], description: nil
        ))

        #expect(dto.name == ["en": "New"])
        #expect(dto.category == "ai")
        #expect(dto.description == ["en": "Old desc"])
        #expect(dto.createdAt != dto.updatedAt)

        let kinds = try await collector.drain().map { try #require($0 as? FeatureEvent).kind }
        #expect(kinds.contains(.featureModified))
        #expect(kinds.contains(.updated))
    }

    @Test("update can change category and description")
    func update_categoryAndDescription() async throws {
        let (ds, _, ctx) = makeSUT()
        let feature = try await seed(ds)
        let dto = try await makeUpdate(ds, ctx).execute(params: .init(
            featureId: feature.id, category: "technicalSupport", name: nil, description: ["uk": "Опис"]
        ))
        #expect(dto.category == "technicalSupport")
        #expect(dto.description == ["uk": "Опис"])
    }

    @Test("update of an unknown feature throws ApplicationError.notFound")
    func update_notFound() async {
        let (ds, _, ctx) = makeSUT()
        await #expect(throws: ApplicationError.self) {
            try await makeUpdate(ds, ctx).execute(params: .init(
                featureId: Feature.Id(rawValue: "feature-missing"), category: nil, name: nil, description: nil
            ))
        }
    }

    @Test("update with an invalid category throws and persists nothing")
    func update_invalidCategory() async throws {
        let (ds, _, ctx) = makeSUT()
        let feature = try await seed(ds)
        await #expect(throws: Feature.Error.invalidCategory("nope")) {
            try await makeUpdate(ds, ctx).execute(params: .init(
                featureId: feature.id, category: "nope", name: nil, description: nil
            ))
        }
        #expect(await ds.updatedModels.isEmpty)
    }
}
