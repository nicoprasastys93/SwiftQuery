# SwiftQuery

Swift take on [TanStack Query](https://tanstack.com/query) (`useQuery`, `useInfiniteQuery`, `useMutation`) built on Combine.
No third-party dependencies: networking and persistent cache are injected.

| Type | Like | Purpose |
| --- | --- | --- |
| `Query<Item>` | `useQuery` | Single resource (`BaseResponse<Item>` by default), refetch, stale-while-revalidate |
| `InfiniteQuery<Item>` | `useInfiniteQuery` | Paged list (`BasePaginationResponse<Item>` by default), `fetchNextPage` |
| `Mutation<Item, Variables>` | `useMutation` | POST/PUT/PATCH/DELETE, no double submit |

Requires iOS 13+ / Swift 5.9+.

## Install

Swift Package Manager: add this repo, product `SwiftQuery`.

## Setup

Configure once at launch. Without this the defaults are `URLSession` + an in-memory cache.

```swift
QueryClient.shared.networking = AlamofireNetworking()   // see below
QueryClient.shared.cache = MMKVQueryCache()
```

### Alamofire adapter

```swift
import SwiftQuery
import Alamofire

struct AlamofireNetworking: QueryNetworking {
    private struct Cancellable: QueryCancellable {
        let request: DataRequest
        func cancel() { request.cancel() }
    }

    func perform(_ request: QueryRequest, completion: @escaping (QueryResponse) -> Void) -> QueryCancellable {
        let manager = APIManager.shared
        let method = HTTPMethod(rawValue: request.method.uppercased())
        let encoder: ParameterEncoder = method == .get ? .urlEncodedForm : .json
        let dataRequest = manager.sessionManager
            .request(request.url, method: method, parameters: request.parameters, encoder: encoder, headers: manager.header)
            .validate()
            .responseData { completion(QueryResponse(statusCode: $0.response?.statusCode, data: $0.data)) }
            .resume()
        return Cancellable(request: dataRequest)
    }
}
```

(`DataRequest.cancel()` returns `Self`, so it can't conform to `QueryCancellable` directly; wrap it.)

### MMKV adapter

```swift
struct MMKVQueryCache: QueryCache {
    func set(_ data: Data, forKey key: String) { MMKVManager.shared.set(data, forKey: key) }
    func data(forKey key: String) -> Data? { MMKVManager.shared.data(forKey: key) }
    func remove(forKey key: String) { MMKVManager.shared.remove(forKey: key) }
}
```

## Usage

```swift
func useEventQuery() -> InfiniteQuery<EventModel> {
    InfiniteQuery<EventModel>(
        firstPageURL: EventService.listFirstPageURL,
        parameters: EventService.listParameters(),
        cacheKey: EventService.listCacheKey()
    )
}

let query = useEventQuery()
query.statePublisher.sink { state in /* state.items, state.isFetching, ... */ }
query.fetch()
```

### Response shapes

By default `Query` / `Mutation` read `{ "type", "message", "data": {...} }` (`BaseResponse`) and `InfiniteQuery` reads Laravel pagination (`BasePaginationResponse`). Any other body is picked per instance with `envelope:`.

| # | Body | `envelope:` | `Query` | `InfiniteQuery` | `Mutation` |
|---|---|---|:-:|:-:|:-:|
| 1 | `{ "type", "message", "data": {...} }` | default (`BaseResponse<Item>`) | ✓ | | ✓ |
| 2 | `{ "type", "message", "data": [...] }` | default (`BaseResponse<[Item]>`) | ✓ | | ✓ |
| 3 | `{ "id": 1, ... }` (no wrapper) | `Bare<Item>.self` | ✓ | | ✓ |
| 4 | `[ {...}, {...} ]` (no wrapper) | `Bare<[Item]>.self` / `BareList<Item>.self` | ✓ | ✓ | ✓ |
| 5 | Laravel `{ "data": [...], "links", "meta" }` | default (`BasePaginationResponse<Item>`) | | ✓ | |
| 6 | Cursor `{ "results": [...], "next_cursor" }` | your own `QueryPageEnvelope` | | ✓ | |
| 7 | Page number `{ "data": [...], "page", "total_pages" }` | your own `QueryPageEnvelope` | | ✓ | |
| 8 | Other wrapper `{ "success", "payload": {...} }` | your own `QueryEnvelope` | ✓ | | ✓ |
| 9 | `204 No Content` / empty body | any | | | ✓ |
| 10 | Error body (non-2xx) | fixed: `{ "type", "message" }` | | | ✓ |

#### 1. Wrapped object (default)

```json
{ "type": "success", "message": "OK", "data": { "id": 1, "name": "Nico" } }
```

```swift
let query = Query<User>(url: { UserService.detailURL() })
let mutation = Mutation<User, UserParams>(url: { UserService.updateURL() }, method: "PUT")
// state.data: User
```

App subclasses of `BaseResponse` work as an envelope too, since they inherit the conformance:

```swift
class UserResponse: BaseResponse<User> {}
let query = Query<User>(url: { UserService.detailURL() }, envelope: UserResponse.self)
```

#### 2. Wrapped array, not paginated (default)

```json
{ "type": "success", "message": "OK", "data": [ { "id": 1 }, { "id": 2 } ] }
```

```swift
let query = Query<[Category]>(url: { CategoryService.listURL() })
// state.data: [Category]
```

#### 3. Bare object

```json
{ "id": 1, "name": "Nico" }
```

```swift
let query = Query<User>(url: { UserService.meURL() }, envelope: Bare<User>.self)
let mutation = Mutation<Profile, ProfileParams>(url: { ProfileService.updateURL() }, method: "PUT", envelope: Bare<Profile>.self)
```

#### 4. Bare array

```json
[ { "id": 1 }, { "id": 2 } ]
```

```swift
// Loaded once, as a value
let query = Query<[Category]>(url: { CategoryService.listURL() }, envelope: Bare<[Category]>.self)

// Same body in a list screen that already uses InfiniteQuery: one page, hasNextPage is always false
let list = InfiniteQuery<Category>(firstPageURL: { CategoryService.listURL() }, envelope: BareList<Category>.self)
```

#### 5. Laravel pagination (default)

```json
{
  "data": [ { "id": 1 } ],
  "links": { "first": "...", "last": "...", "prev": null, "next": "https://api.test/events?page=2" },
  "meta": { "current_page": 1, "last_page": 5, "per_page": 15, "total": 70 }
}
```

```swift
let query = InfiniteQuery<EventModel>(firstPageURL: EventService.listFirstPageURL)
// fetchNextPage() requests links.next; hasNextPage is false once it is null
```

#### 6. Cursor pagination

```json
{ "results": [ { "id": 1 } ], "next_cursor": "abc123" }
```

Say where the items are and how to build the next URL. `queryURL(_:setting:to:)` sets (or replaces) a query item on the URL the page was loaded from.

```swift
struct CursorPage<T: Decodable>: QueryPageEnvelope {
    let results: [T]
    let next_cursor: String?
    var items: [T] { results }
    func nextPageURL(currentURL: String) -> String? {
        next_cursor.map { queryURL(currentURL, setting: "cursor", to: $0) }
    }
}

let query = InfiniteQuery<Post>(firstPageURL: { PostService.feedURL() }, envelope: CursorPage<Post>.self)
// page 2: https://api.test/feed?cursor=abc123
```

#### 7. Page-number pagination

```json
{ "data": [ { "id": 1 } ], "page": 1, "total_pages": 5 }
```

```swift
struct NumberedPage<T: Decodable>: QueryPageEnvelope {
    let data: [T]
    let page: Int
    let total_pages: Int
    var items: [T] { data }
    func nextPageURL(currentURL: String) -> String? {
        page < total_pages ? queryURL(currentURL, setting: "page", to: "\(page + 1)") : nil
    }
}

let query = InfiniteQuery<Product>(firstPageURL: { ProductService.listURL() }, envelope: NumberedPage<Product>.self)
// page 2: https://api.test/products?page=2
```

#### 8. Other wrapper

```json
{ "success": true, "payload": { "id": 1 } }
```

Only `item` is required; any other field can be decoded alongside it.

```swift
struct Payload<T: Decodable>: QueryEnvelope {
    let success: Bool?
    let payload: T?
    var item: T? { payload }
}

let query = Query<User>(url: { UserService.meURL() }, envelope: Payload<User>.self)
let mutation = Mutation<Order, OrderParams>(url: { OrderService.createURL() }, envelope: Payload<Order>.self)
```

#### 9. No content

```
HTTP/1.1 204 No Content
```

Any 2xx is a success even when the body is empty or does not decode; `state.data` is then `nil`. Pick any `Item` (the default envelope is fine):

```swift
struct Empty: Decodable {}
let delete = Mutation<Empty, DeleteParams>(url: { AddressService.deleteURL(id) }, method: "DELETE")
// state.isSuccess == true, state.data == nil
```

#### 10. Error body

```json
{ "type": "validation", "message": "Email has already been taken" }
```

For a non-2xx response `Mutation` reads `type` and `message` from the body, whatever `envelope:` is:

```swift
// state.status == .error
// state.error?.statusCode == 422
// state.error?.type == "validation"
// state.error?.message == "Email has already been taken"
```

`Query` / `InfiniteQuery` only expose `state.statusCode` on failure; the error body is not decoded. Other error shapes are not supported yet.

`Mutation(envelope: false)` still compiles but is deprecated: use `envelope: Bare<Item>.self` (or omit `envelope:` for `true`).

### File upload (multipart/form-data)

Make the variables conform to `QueryMultipartEncodable` and pass `encoding: .multipart`:

```swift
extension ParamProfileUpdateModel: QueryMultipartEncodable {
    func multipartParts() -> [QueryMultipartPart] {
        [QueryMultipartPart(name: "name", value: name),
         QueryMultipartPart(name: "phone_number", value: phone_number),
         id_card_image.map { QueryMultipartPart(name: "id_card_image", data: $0, fileName: id_card_name, mimeType: "image/jpeg") }]
            .compactMap { $0 }
    }
}

let mutation = Mutation<ProfileModel, ParamProfileUpdateModel>(url: { ProfileService.updateURL() }, encoding: .multipart)
```

`QueryMultipartPart(name:value:)` returns `nil` for a `nil` value, so optional fields are skipped with `compactMap`.
Custom `QueryNetworking` implementations must handle `request.encoding == .multipart` by sending `request.multipartParts`.

Every instance also takes `client:` to use a custom `QueryClient` (handy in tests).

