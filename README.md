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

Every type exposes its state as `state` (`@Published`) and `statePublisher`: subscribe, then call an action.
URLs are closures, evaluated on every request. The defaults read `BaseResponse` / `BasePaginationResponse`; for other bodies see [Response shapes](#response-shapes).
Every instance also takes `client:` to use a custom `QueryClient` (handy in tests).

### `Query<Item>`

Like `useQuery`: one resource, loaded with `fetch()` and reloaded with `refetch()`.

```swift
Query<Item>(
    url: () -> String?,          // endpoint, evaluated on every fetch / refetch
    parameters: Encodable? = nil,
    cacheKey: String? = nil,     // persist the response, show it instantly on the next fetch()
    envelope: ... = BaseResponse<Item>.self,
    client: QueryClient = .shared
)
```

| Action | Does |
| --- | --- |
| `fetch()` | Initial load. No-op if data is already loaded or loading. With `cacheKey`, the cached value is shown first (`isPlaceholderData`) while the network request runs |
| `refetch()` | Reload, keeping the current data visible (pull to refresh) |
| `cancel()` | Cancel the in-flight request, keep the data |
| `reset(clearCache: Bool = false)` | Cancel and drop all data, and the cache entry when `clearCache` is true (e.g. logout) |

| `state.` | Type | Meaning |
| --- | --- | --- |
| `data` | `Item?` | Last loaded value |
| `status` | `.idle` / `.loading` / `.success` / `.error` | `.loading` = first load with nothing to show; `.error` = failed with nothing to show |
| `statusCode` | `Int?` | HTTP status of the last response |
| `isFetching` | `Bool` | Any request in flight |
| `isRefetching` | `Bool` | Reloading while showing loaded data |
| `isPlaceholderData` | `Bool` | `data` comes from the cache, network still pending |

A failed refetch keeps the existing `data` (status stays `.success`), so the screen does not blank out.

```swift
final class ProfileViewController: UIViewController {
    private let query = Query<User>(url: { UserService.detailURL() }, cacheKey: "profile")
    private var cancellables = Set<AnyCancellable>()

    override func viewDidLoad() {
        super.viewDidLoad()
        query.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.spinner.isHidden = state.status != .loading
                self?.refreshControl.isRefreshing = state.isRefetching
                self?.errorView.isHidden = state.status != .error
                if let user = state.data { self?.render(user) }
            }
            .store(in: &cancellables)
        query.fetch()
    }

    @objc private func didPullToRefresh() { query.refetch() }
}
```

### `InfiniteQuery<Item>`

Like `useInfiniteQuery`: a paged list. Pages are kept in memory and appended by `fetchNextPage()`.

```swift
InfiniteQuery<Item>(
    firstPageURL: () -> String?, // evaluated on every fetch / refetch; later pages come from the response
    parameters: Encodable? = nil, // sent with every page
    cacheKey: String? = nil,      // persist the first page, show it instantly on the next fetch()
    envelope: ... = BasePaginationResponse<Item>.self,
    client: QueryClient = .shared
)
```

| Action | Does |
| --- | --- |
| `fetch()` | Initial load of page one. No-op if already loaded or loading |
| `refetch()` | Reload from page one, keeping the current items visible (pull to refresh) |
| `fetchNextPage()` | Load the following page. No-op when `!hasNextPage` or a request is in flight |
| `cancel()` | Cancel the in-flight request, keep the pages |
| `reset(clearCache: Bool = false)` | Cancel and drop all pages, and the cache entry when `clearCache` is true |

| `state.` | Type | Meaning |
| --- | --- | --- |
| `items` | `[Item]` | All pages flattened |
| `pages` | `[[Item]]` | Items per page |
| `isEmpty` | `Bool` | Loaded successfully with no items |
| `status` | `.idle` / `.loading` / `.success` / `.error` | Same as `Query` |
| `statusCode` | `Int?` | HTTP status of the last response |
| `hasNextPage` | `Bool` | The last page pointed to a next one |
| `isFetching` | `Bool` | Any request in flight |
| `isFetchingNextPage` | `Bool` | Loading a following page (footer spinner) |
| `isRefetching` | `Bool` | Reloading page one while showing items |
| `isPlaceholderData` | `Bool` | Items come from the cache, network still pending |

```swift
func useEventQuery() -> InfiniteQuery<EventModel> {
    InfiniteQuery<EventModel>(
        firstPageURL: EventService.listFirstPageURL,
        parameters: EventService.listParameters(),
        cacheKey: EventService.listCacheKey()
    )
}

final class EventListViewController: UITableViewController {
    private let query = useEventQuery()
    private var cancellables = Set<AnyCancellable>()

    override func viewDidLoad() {
        super.viewDidLoad()
        query.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.tableView.reloadData()
                self?.refreshControl?.isRefreshing = state.isRefetching
                self?.footerSpinner.isHidden = !state.isFetchingNextPage
                self?.emptyView.isHidden = !state.isEmpty
            }
            .store(in: &cancellables)
        query.fetch()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        query.state.items.count
    }

    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if indexPath.row == query.state.items.count - 1 { query.fetchNextPage() }
    }
}
```

### `Mutation<Item, Variables>`

Like `useMutation`: POST / PUT / PATCH / DELETE. Nothing runs until `mutate(_:)`.

```swift
Mutation<Item, Variables>(
    url: () -> String?,               // evaluated on every mutate
    method: String = "POST",
    envelope: ... = BaseResponse<Item>.self,  // or decode: { ... } for a raw body
    encoding: QueryBodyEncoding = .json,      // or .multipart
    client: QueryClient = .shared
)
```

| Action | Does |
| --- | --- |
| `mutate(_ variables: Variables)` | Send the request with `variables` as the body. Ignored while a previous call is pending (no double submit) |
| `reset()` | Cancel any in-flight request and go back to `.idle` |

| `state.` | Type | Meaning |
| --- | --- | --- |
| `data` | `Item?` | Decoded success body (`nil` for an empty body) |
| `error` | `MutationError?` | `statusCode`, `type`, `message` of a non-2xx response |
| `status` | `.idle` / `.pending` / `.success` / `.error` | |
| `isPending` / `isSuccess` / `isError` | `Bool` | Shorthands for `status` |

```swift
final class EditProfileViewController: UIViewController {
    private let mutation = Mutation<User, UserParams>(url: { UserService.updateURL() }, method: "PUT")
    private var cancellables = Set<AnyCancellable>()

    override func viewDidLoad() {
        super.viewDidLoad()
        mutation.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.saveButton.isEnabled = !state.isPending
                if state.isSuccess { self?.navigationController?.popViewController(animated: true) }
                if state.isError { self?.showAlert(state.error?.message ?? "Something went wrong") }
            }
            .store(in: &cancellables)
    }

    @objc private func didTapSave() {
        mutation.mutate(UserParams(name: nameField.text ?? "", email: emailField.text ?? ""))
    }
}
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
| 11 | Raw body / file (xlsx, pdf, image, ...) | `decode: { $0 }` instead of `envelope:` | | | ✓ |

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

#### 11. Raw body / file

For a body that is not JSON, such as a downloaded file, pass `decode:` instead of `envelope:`. With `Item == Data` the bytes come back as they are, so any file type works; the app picks the file name when it saves it:

```swift
let download = Mutation<Data, ParamExportModel>(url: { ExportService.url() }, method: "GET", decode: { $0 })
// state.status == .success → state.data is the file
try download.state.data?.write(to: documents.appendingPathComponent("Report.xlsx"))
```

The whole body is kept in memory and there is no download progress. Error bodies are still read as in 10.

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

