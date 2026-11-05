import Foundation
import Testing
import Vapor
@testable import ShowMenuBackend

@Suite("ETag <-> Version")
struct ETagVaporTests {

    @Test("renders a quoted entity tag; .none renders nil")
    func render() {
        #expect(Version(3).etag == "\"3\"")
        #expect(Version.none.etag == nil)
        #expect(Version(rawValue: "").etag == nil)
    }

    @Test("parses quoted, weak, and whitespace-padded tags")
    func parse() {
        #expect(Version(etag: "\"3\"") == Version(3))
        #expect(Version(etag: "W/\"3\"") == Version(3))
        #expect(Version(etag: "  \"42\"  ") == Version(42))
        #expect(Version(etag: "\"\"") == Version.none)
    }

    @Test("round-trips through the entity-tag form")
    func roundTrip() throws {
        let v = Version(7)
        let etag = try #require(v.etag)
        #expect(Version(etag: etag) == v)
    }

    @Test("If-Match: '*' imposes no version precondition")
    func ifMatchWildcard() async throws {
        let app = try await Application.make(.testing)

        let starReq = Request(application: app, method: .PUT, url: "/api/v1/plans/features/feature-1",
                              headers: ["If-Match": "*"], on: app.eventLoopGroup.any())
        #expect(starReq.ifMatch == nil)

        let versionReq = Request(application: app, method: .PUT, url: "/api/v1/plans/features/feature-1",
                                 headers: ["If-Match": "\"5\""], on: app.eventLoopGroup.any())
        #expect(versionReq.ifMatch == Version(5))

        let noneReq = Request(application: app, method: .PUT, url: "/api/v1/plans/features/feature-1",
                              on: app.eventLoopGroup.any())
        #expect(noneReq.ifMatch == nil)

        try await app.asyncShutdown()
    }
}
