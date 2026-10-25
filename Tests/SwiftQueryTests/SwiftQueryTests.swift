import XCTest
@testable import SwiftQuery

private struct Todo: Decodable, Equatable { var id: Int }
private struct Payload: Encodable { var name: String }

private final class MockNetworking: QueryNetworking {
    var responses: [QueryResponse] = []
    private(set) var requests: [QueryRequest] = []

    final class Token: QueryCancellable { func cancel() {} }

    func perform(_ request: QueryRequest, completion: @escaping (QueryResponse) -> Void) -> QueryCancellable {
        requests.append(request)
        completion(responses.removeFirst())
        return Token()
    }
}

private func json(_ s: String) -> Data { Data(s.utf8) }

final class SwiftQueryTests: XCTestCase {
    fileprivate func client(_ net: MockNetworking) -> QueryClient {
        QueryClient(networking: net, cache: InMemoryQueryCache())
    }

    func testQuerySuccessAndCache() {
        let net = MockNetworking()
        let client = client(net)
        net.responses = [QueryResponse(statusCode: 200, data: json(#"{"data":{"id":1}}"#))]
        let q = Query<Todo>(url: { "https://x.test/a" }, cacheKey: "todo", client: client)
        q.fetch()
        XCTAssertEqual(q.state.data, Todo(id: 1))
        XCTAssertEqual(q.state.status, .success)

        // New instance shows cached data as placeholder; the failing network keeps it.
        net.responses = [QueryResponse(statusCode: 500, data: nil)]
        let q2 = Query<Todo>(url: { "https://x.test/a" }, cacheKey: "todo", client: client)
        q2.fetch()
        XCTAssertEqual(q2.state.data, Todo(id: 1))
        XCTAssertEqual(q2.state.statusCode, 500)
        XCTAssertEqual(q2.state.status, .success)
    }

    func testQueryErrorWithoutData() {
        let net = MockNetworking()
        net.responses = [QueryResponse(statusCode: nil, data: nil)]
        let q = Query<Todo>(url: { "https://x.test/a" }, client: client(net))
        q.fetch()
        XCTAssertEqual(q.state.status, .error)
    }

    func testInfiniteQueryPaging() {
        let net = MockNetworking()
        net.responses = [
            QueryResponse(statusCode: 200, data: json(#"{"data":[{"id":1}],"links":{"next":"https://x.test/p2"}}"#)),
            QueryResponse(statusCode: 200, data: json(#"{"data":[{"id":2}],"links":{"next":null}}"#))
        ]
        let q = InfiniteQuery<Todo>(firstPageURL: { "https://x.test/p1" }, client: client(net))
        q.fetch()
        XCTAssertTrue(q.state.hasNextPage)
        q.fetchNextPage()
        XCTAssertEqual(q.state.items, [Todo(id: 1), Todo(id: 2)])
        XCTAssertFalse(q.state.hasNextPage)
        XCTAssertEqual(net.requests.last?.url, "https://x.test/p2")
    }

    func testMutationSuccessAndError() {
        let net = MockNetworking()
        net.responses = [
            QueryResponse(statusCode: 201, data: json(#"{"data":{"id":9}}"#)),
            QueryResponse(statusCode: 422, data: json(#"{"type":"validation","message":"bad"}"#))
        ]
        let m = Mutation<Todo, Payload>(url: { "https://x.test/m" }, client: client(net))
        m.mutate(Payload(name: "a"))
        XCTAssertTrue(m.state.isSuccess)
        XCTAssertEqual(m.state.data, Todo(id: 9))
        m.mutate(Payload(name: "b"))
        XCTAssertEqual(m.state.error?.statusCode, 422)
        XCTAssertEqual(m.state.error?.message, "bad")
    }

    func testQueryItemsFlattening() {
        struct P: Encodable { var page: Int; var q: String; var tags: [String]; var active: Bool }
        let items = URLSessionNetworking.queryItems(from: P(page: 2, q: "a b", tags: ["x", "y"], active: true))
        let dict = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(dict["page"], "2")
        XCTAssertEqual(dict["tags[1]"], "y")
        XCTAssertEqual(dict["active"], "true")
    }
}
