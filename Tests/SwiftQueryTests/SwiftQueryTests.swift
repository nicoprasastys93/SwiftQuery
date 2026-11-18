import XCTest
@testable import SwiftQuery

private struct Todo: Decodable, Equatable { var id: Int }
private struct Payload: Encodable { var name: String }
private final class TodoResponse: BaseResponse<Todo> {}

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

    @available(*, deprecated)
    func testMutationWithoutEnvelopeLegacyBool() {
        let net = MockNetworking()
        net.responses = [QueryResponse(statusCode: 200, data: json(#"{"id":5}"#))]
        let m = Mutation<Todo, Payload>(url: { "https://x.test/m" }, envelope: false, client: client(net))
        m.mutate(Payload(name: "a"))
        XCTAssertTrue(m.state.isSuccess)
        XCTAssertEqual(m.state.data, Todo(id: 5))
    }

    func testMutationRawData() {
        let net = MockNetworking()
        let file = Data([0x50, 0x4B, 0x03, 0x04, 0xFF, 0x00])   // not JSON (xlsx/zip header)
        net.responses = [
            QueryResponse(statusCode: 200, data: file),
            QueryResponse(statusCode: 404, data: json(#"{"type":"not_found","message":"gone"}"#))
        ]
        let m = Mutation<Data, Payload>(url: { "https://x.test/f" }, method: "GET", client: client(net), decode: { $0 })
        m.mutate(Payload(name: "a"))
        XCTAssertTrue(m.state.isSuccess)
        XCTAssertEqual(m.state.data, file)
        XCTAssertEqual(net.requests.last?.method, "GET")
        m.mutate(Payload(name: "b"))
        XCTAssertTrue(m.state.isError)
        XCTAssertEqual(m.state.error?.message, "gone")
    }

    func testMutationMultipart() {
        struct Upload: Encodable, QueryMultipartEncodable {
            var name: String
            func multipartParts() -> [QueryMultipartPart] {
                [QueryMultipartPart(name: "name", value: name)!,
                 QueryMultipartPart(name: "photo", data: Data([1, 2]), fileName: "a.jpg", mimeType: "image/jpeg")]
            }
        }
        let net = MockNetworking()
        net.responses = [QueryResponse(statusCode: 200, data: json(#"{"id":7}"#))]
        let m = Mutation<Todo, Upload>(url: { "https://x.test/u" }, method: "POST", envelope: Bare<Todo>.self, encoding: .multipart, client: client(net))
        m.mutate(Upload(name: "n"))
        XCTAssertTrue(m.state.isSuccess)
        let sent = net.requests.last
        XCTAssertEqual(sent?.encoding, .multipart)
        XCTAssertNil(sent?.parameters)
        XCTAssertEqual(sent?.multipartParts.map(\.name), ["name", "photo"])
        XCTAssertEqual(sent?.multipartParts.last?.fileName, "a.jpg")
    }

    func testMutationBareEnvelope() {
        let net = MockNetworking()
        net.responses = [QueryResponse(statusCode: 200, data: json(#"{"id":6}"#))]
        let m = Mutation<Todo, Payload>(url: { "https://x.test/m" }, envelope: Bare<Todo>.self, client: client(net))
        m.mutate(Payload(name: "a"))
        XCTAssertEqual(m.state.data, Todo(id: 6))
    }

    func testQueryBareEnvelopeAndCache() {
        let net = MockNetworking()
        let client = client(net)
        net.responses = [QueryResponse(statusCode: 200, data: json(#"[{"id":1},{"id":2}]"#))]
        let q = Query<[Todo]>(url: { "https://x.test/a" }, cacheKey: "list", envelope: Bare<[Todo]>.self, client: client)
        q.fetch()
        XCTAssertEqual(q.state.data, [Todo(id: 1), Todo(id: 2)])

        net.responses = [QueryResponse(statusCode: 500, data: nil)]
        let q2 = Query<[Todo]>(url: { "https://x.test/a" }, cacheKey: "list", envelope: Bare<[Todo]>.self, client: client)
        q2.fetch()
        XCTAssertEqual(q2.state.data?.count, 2)
    }

    func testQueryCustomEnvelope() {
        struct Wrapped<T: Decodable>: QueryEnvelope {
            let payload: T?
            var item: T? { payload }
        }
        let net = MockNetworking()
        net.responses = [QueryResponse(statusCode: 200, data: json(#"{"success":true,"payload":{"id":3}}"#))]
        let q = Query<Todo>(url: { "https://x.test/a" }, envelope: Wrapped<Todo>.self, client: client(net))
        q.fetch()
        XCTAssertEqual(q.state.data, Todo(id: 3))
    }

    func testInfiniteQueryCursorEnvelope() {
        struct CursorPage<T: Decodable>: QueryPageEnvelope {
            let results: [T]
            let next_cursor: String?
            var items: [T] { results }
            func nextPageURL(currentURL: String) -> String? {
                next_cursor.map { queryURL(currentURL, setting: "cursor", to: $0) }
            }
        }
        let net = MockNetworking()
        net.responses = [
            QueryResponse(statusCode: 200, data: json(#"{"results":[{"id":1}],"next_cursor":"abc"}"#)),
            QueryResponse(statusCode: 200, data: json(#"{"results":[{"id":2}],"next_cursor":null}"#))
        ]
        let q = InfiniteQuery<Todo>(firstPageURL: { "https://x.test/list?cursor=start&q=a" }, envelope: CursorPage<Todo>.self, client: client(net))
        q.fetch()
        XCTAssertTrue(q.state.hasNextPage)
        q.fetchNextPage()
        XCTAssertEqual(net.requests.last?.url, "https://x.test/list?q=a&cursor=abc")
        XCTAssertEqual(q.state.items, [Todo(id: 1), Todo(id: 2)])
        XCTAssertFalse(q.state.hasNextPage)
    }

    func testInfiniteQueryBareList() {
        let net = MockNetworking()
        net.responses = [QueryResponse(statusCode: 200, data: json(#"[{"id":1},{"id":2}]"#))]
        let q = InfiniteQuery<Todo>(firstPageURL: { "https://x.test/all" }, envelope: BareList<Todo>.self, client: client(net))
        q.fetch()
        XCTAssertEqual(q.state.items.count, 2)
        XCTAssertFalse(q.state.hasNextPage)
    }

    func testQueryWithBaseResponseSubclass() {
        let net = MockNetworking()
        net.responses = [QueryResponse(statusCode: 200, data: json(#"{"type":"success","data":{"id":4}}"#))]
        let q = Query<Todo>(url: { "https://x.test/a" }, envelope: TodoResponse.self, client: client(net))
        q.fetch()
        XCTAssertEqual(q.state.data, Todo(id: 4))
    }

    func testInfiniteQueryPageNumberEnvelope() {
        struct NumberedPage<T: Decodable>: QueryPageEnvelope {
            let data: [T]
            let page: Int
            let total_pages: Int
            var items: [T] { data }
            func nextPageURL(currentURL: String) -> String? {
                page < total_pages ? queryURL(currentURL, setting: "page", to: "\(page + 1)") : nil
            }
        }
        let net = MockNetworking()
        net.responses = [
            QueryResponse(statusCode: 200, data: json(#"{"data":[{"id":1}],"page":1,"total_pages":2}"#)),
            QueryResponse(statusCode: 200, data: json(#"{"data":[{"id":2}],"page":2,"total_pages":2}"#))
        ]
        let q = InfiniteQuery<Todo>(firstPageURL: { "https://x.test/products" }, envelope: NumberedPage<Todo>.self, client: client(net))
        q.fetch()
        q.fetchNextPage()
        XCTAssertEqual(net.requests.last?.url, "https://x.test/products?page=2")
        XCTAssertEqual(q.state.items, [Todo(id: 1), Todo(id: 2)])
        XCTAssertFalse(q.state.hasNextPage)
    }

    func testMutationNoContent() {
        struct Empty: Decodable {}
        let net = MockNetworking()
        net.responses = [QueryResponse(statusCode: 204, data: Data())]
        let m = Mutation<Empty, Payload>(url: { "https://x.test/d" }, method: "DELETE", client: client(net))
        m.mutate(Payload(name: "a"))
        XCTAssertTrue(m.state.isSuccess)
        XCTAssertNil(m.state.data)
    }

    func testMultipartBody() {
        let parts = [QueryMultipartPart(name: "a", value: "1")!,
                     QueryMultipartPart(name: "f", data: Data("X".utf8), fileName: "x.txt", mimeType: "text/plain")]
        let body = String(decoding: parts.multipartBody(boundary: "B"), as: UTF8.self)
        XCTAssertEqual(body, "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--B\r\nContent-Disposition: form-data; name=\"f\"; filename=\"x.txt\"\r\nContent-Type: text/plain\r\n\r\nX\r\n--B--\r\n")
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
