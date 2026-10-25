//
//  Query.swift
//  SwiftQuery
//
//  Swift take on useQuery from @tanstack/react-query for a single resource
//  (response shaped like BaseResponse<Item>). Handles refetch,
//  stale-while-revalidate via QueryCache and request cancellation.
//

import Foundation
import Combine

public final class Query<Item: Decodable> {

    public enum Status {
        /// Nothing fetched yet
        case idle
        /// First load, no data to show
        case loading
        /// Has data (fresh or cached)
        case success
        /// Load failed and there is no data to show
        case error
    }

    public struct State {
        public var data: Item?
        public var status: Status = .idle
        /// HTTP status of the last response, `nil` when none was received or the body was undecodable
        public var statusCode: Int?
        /// Any request in flight (first load or refetch)
        public var isFetching = false
        public var isRefetching = false
        /// Data currently shown comes from the cache and a network request is still pending
        public var isPlaceholderData = false
    }

    // MARK: - Public
    @Published public private(set) var state = State()
    public var statePublisher: AnyPublisher<State, Never> { return $state.eraseToAnyPublisher() }

    // MARK: - Private
    private let client: QueryClient
    private let url: () -> String?
    private let parameters: AnyEncodable?
    private let cacheKey: String?
    private var request: QueryCancellable?
    /// Invalidates in-flight responses after refetch / reset / cancel
    private var generation = 0

    /// - Parameters:
    ///   - url: Endpoint URL, evaluated on every fetch / refetch.
    ///   - parameters: Query parameters.
    ///   - cacheKey: When set, the response is persisted in the cache and shown instantly on the next `fetch()`.
    ///   - client: Networking and cache provider.
    public init(url: @escaping () -> String?, parameters: Encodable? = nil, cacheKey: String? = nil, client: QueryClient = .shared) {
        self.client = client
        self.url = url
        self.parameters = parameters.map(AnyEncodable.init)
        self.cacheKey = cacheKey.map { "query.\($0)" }
    }
    deinit {
        request?.cancel()
    }

    // MARK: - Actions
    /// Initial load. Does nothing if data is already loaded (use `refetch` to reload).
    public func fetch() {
        guard state.status == .idle || state.status == .error else { return }
        var newState = state
        if let cached = cachedItem() {
            newState.data = cached
            newState.status = .success
            newState.isPlaceholderData = true
        } else {
            newState.status = .loading
        }
        load(from: newState)
    }

    /// Reload while keeping the current data visible (pull to refresh).
    public func refetch() {
        load(from: state)
    }

    public func cancel() {
        generation += 1
        request?.cancel()
        request = nil
        var newState = state
        newState.isFetching = false
        newState.isRefetching = false
        state = newState
    }

    /// Cancel and drop all data (also the cache entry when `clearCache` is true, e.g. on logout).
    public func reset(clearCache: Bool = false) {
        generation += 1
        request?.cancel()
        request = nil
        state = State()
        if clearCache, let cacheKey = cacheKey {
            client.cache.remove(forKey: cacheKey)
        }
    }
}
// MARK: - Loading
// Every public action publishes `state` exactly once, so subscribers never see half-updated states.
private extension Query {
    func load(from base: State) {
        var newState = base
        guard let url = url(), url != "" else {
            newState.isFetching = false
            state = newState
            return
        }

        generation += 1
        let current = generation
        request?.cancel()

        newState.isFetching = true
        newState.isRefetching = newState.status == .success && !newState.isPlaceholderData
        state = newState

        request = client.networking.perform(QueryRequest(url: url, method: "GET", parameters: parameters)) { [weak self] response in
            guard let self = self, current == self.generation else { return }
            self.request = nil

            var newState = self.state
            newState.isFetching = false
            newState.isRefetching = false

            if let code = response.statusCode, (200..<300).contains(code) {
                if let data = response.data, let item = try? JSONDecoder().decode(BaseResponse<Item>.self, from: data).data {
                    if let cacheKey = self.cacheKey {
                        self.client.cache.set(data, forKey: cacheKey)
                    }
                    newState.data = item
                    newState.status = .success
                    newState.statusCode = code
                    newState.isPlaceholderData = false
                } else {
                    self.fail(nil, in: &newState)
                }
            } else {
                self.fail(response.statusCode, in: &newState)
            }
            self.state = newState
        }
    }

    /// Keeps existing data on failure; only flips to `.error` when there is nothing to show
    func fail(_ code: Int?, in newState: inout State) {
        newState.statusCode = code
        newState.isPlaceholderData = false
        if newState.data == nil {
            newState.status = .error
        }
    }

    func cachedItem() -> Item? {
        guard let cacheKey = cacheKey, let data = client.cache.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(BaseResponse<Item>.self, from: data).data
    }
}
