//
//  InfiniteQuery.swift
//  SwiftQuery
//
//  Swift take on useInfiniteQuery from @tanstack/react-query.
//  Handles paged fetching (first / next), refetch, in-memory pages,
//  stale-while-revalidate via QueryCache and request cancellation.
//

import Foundation
import Combine

public final class InfiniteQuery<Item: Decodable> {

    public enum Status {
        /// Nothing fetched yet
        case idle
        /// First load, no data to show
        case loading
        /// Has data (fresh or cached)
        case success
        /// First load failed and there is no data to show
        case error
    }

    public struct State {
        public var pages: [[Item]] = []
        public var status: Status = .idle
        /// HTTP status of the last response, `nil` when none was received or the body was undecodable
        public var statusCode: Int?
        /// Any request in flight (first, refetch or next page)
        public var isFetching = false
        public var isFetchingNextPage = false
        public var isRefetching = false
        public var hasNextPage = false
        /// Data currently shown comes from the cache and a network request is still pending
        public var isPlaceholderData = false

        /// Flattened pages, like `data.pages.flatMap` in react-query
        public var items: [Item] { return pages.flatMap { $0 } }
        public var isEmpty: Bool { return status == .success && items.isEmpty }
    }

    // MARK: - Public
    @Published public private(set) var state = State()
    public var statePublisher: AnyPublisher<State, Never> { return $state.eraseToAnyPublisher() }

    // MARK: - Private
    private let client: QueryClient
    private let firstPageURL: () -> String?
    private let parameters: AnyEncodable?
    private let cacheKey: String?
    private var nextURL: String?
    private var request: QueryCancellable?
    /// Invalidates in-flight responses after refetch / reset / cancel
    private var generation = 0

    /// - Parameters:
    ///   - firstPageURL: URL of the first page, evaluated on every fetch / refetch.
    ///   - parameters: Query parameters sent with every page.
    ///   - cacheKey: When set, the first page response is persisted in the cache and shown instantly on the next `fetch()`.
    ///   - client: Networking and cache provider.
    public init(firstPageURL: @escaping () -> String?, parameters: Encodable? = nil, cacheKey: String? = nil, client: QueryClient = .shared) {
        self.client = client
        self.firstPageURL = firstPageURL
        self.parameters = parameters.map(AnyEncodable.init)
        self.cacheKey = cacheKey.map { "infinite_query.\($0)" }
    }
    deinit {
        request?.cancel()
    }

    // MARK: - Actions
    /// Initial load. Does nothing if data is already loaded (use `refetch` to reload).
    public func fetch() {
        guard state.status == .idle || state.status == .error else { return }
        var newState = state
        if let cached = cachedFirstPage() {
            apply(cached, appending: false, placeholder: true, to: &newState)
        } else {
            newState.status = .loading
        }
        load(firstPage: true, from: newState)
    }

    /// Reload from page one, keeping the current data visible meanwhile (pull to refresh).
    public func refetch() {
        load(firstPage: true, from: state)
    }

    /// Load the following page (FlatList.onEndReached).
    public func fetchNextPage() {
        guard state.hasNextPage, !state.isFetching else { return }
        load(firstPage: false, from: state)
    }

    public func cancel() {
        generation += 1
        request?.cancel()
        request = nil
        var newState = state
        newState.isFetching = false
        newState.isFetchingNextPage = false
        newState.isRefetching = false
        state = newState
    }

    /// Cancel and drop all data (also the cache entry when `clearCache` is true, e.g. on logout).
    public func reset(clearCache: Bool = false) {
        generation += 1
        request?.cancel()
        request = nil
        nextURL = nil
        state = State()
        if clearCache, let cacheKey = cacheKey {
            client.cache.remove(forKey: cacheKey)
        }
    }
}
// MARK: - Loading
// Every public action publishes `state` exactly once, so subscribers never see half-updated states.
private extension InfiniteQuery {
    func load(firstPage: Bool, from base: State) {
        var newState = base
        let url = firstPage ? firstPageURL() : nextURL
        guard let url = url, url != "" else {
            newState.isFetching = false
            newState.hasNextPage = false
            state = newState
            return
        }

        generation += 1
        let current = generation
        request?.cancel()

        newState.isFetching = true
        newState.isFetchingNextPage = !firstPage
        newState.isRefetching = firstPage && newState.status == .success && !newState.isPlaceholderData
        state = newState

        request = client.networking.perform(QueryRequest(url: url, method: "GET", parameters: parameters)) { [weak self] response in
            guard let self = self, current == self.generation else { return }
            self.request = nil

            var newState = self.state
            newState.isFetching = false
            newState.isFetchingNextPage = false
            newState.isRefetching = false

            if let code = response.statusCode, (200..<300).contains(code) {
                guard let data = response.data, let page = try? JSONDecoder().decode(BasePaginationResponse<Item>.self, from: data) else {
                    self.fail(nil, in: &newState)
                    self.state = newState
                    return
                }
                if firstPage, let cacheKey = self.cacheKey {
                    self.client.cache.set(data, forKey: cacheKey)
                }
                self.apply(page, appending: !firstPage, placeholder: false, to: &newState)
                newState.statusCode = code
            } else {
                self.fail(response.statusCode, in: &newState)
            }
            self.state = newState
        }
    }

    func apply(_ page: BasePaginationResponse<Item>, appending: Bool, placeholder: Bool, to newState: inout State) {
        let items = page.data ?? []
        if appending {
            newState.pages.append(items)
        } else {
            newState.pages = [items]
        }
        nextURL = page.links?.next
        newState.hasNextPage = (nextURL ?? "") != ""
        newState.status = .success
        newState.statusCode = 200
        newState.isPlaceholderData = placeholder
    }

    /// Keeps existing data on failure; only flips to `.error` when there is nothing to show
    func fail(_ code: Int?, in newState: inout State) {
        newState.statusCode = code
        newState.isPlaceholderData = false
        if newState.pages.isEmpty {
            newState.status = .error
        }
    }

    func cachedFirstPage() -> BasePaginationResponse<Item>? {
        guard let cacheKey = cacheKey, let data = client.cache.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(BasePaginationResponse<Item>.self, from: data)
    }
}
