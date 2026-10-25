# SwiftQuery

Swift take on [TanStack Query](https://tanstack.com/query) (`useQuery`, `useInfiniteQuery`, `useMutation`) built on Combine.
No third-party dependencies: networking and persistent cache are injected.

| Type | Like | Purpose |
| --- | --- | --- |
| `Query<Item>` | `useQuery` | Single resource (`BaseResponse<Item>`), refetch, stale-while-revalidate |
| `InfiniteQuery<Item>` | `useInfiniteQuery` | Paged list (`BasePaginationResponse<Item>`), `fetchNextPage` |
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

Every instance also takes `client:` to use a custom `QueryClient` (handy in tests).

## Migrating from loyalty_ios

- Delete `Query.swift`, `InfiniteQuery.swift`, `Mutation.swift` and `AnyEncodable`; keep `EventQuery.swift`, `OrderQuery.swift`, ... (just add `import SwiftQuery`).
- `state.statusCode` and `MutationError.statusCode` are now `Int?` (`nil` = no response / undecodable body) instead of `APIStatusCode`.
- `Mutation(method:)` takes a `String` (`"POST"`, `"PUT"`, ...) instead of Alamofire's `HTTPMethod`.
- `BaseResponse` / `BasePaginationResponse` (open classes, so `class FooModel: BaseResponse<Bar>` keeps working), `Links` and `Meta` now live in the library. Remove the app's versions and add `import SwiftQuery` to files that use them.
- Success is any 2xx (previously only `200`).
