//
//  QueryClient.swift
//  SwiftQuery
//
//  Injection point for networking and caching, like QueryClient in react-query.
//  Configure `QueryClient.shared` once at app launch.
//

import Foundation

public struct QueryRequest {
    public var url: String
    public var method: String
    public var parameters: AnyEncodable?

    public init(url: String, method: String, parameters: AnyEncodable? = nil) {
        self.url = url
        self.method = method
        self.parameters = parameters
    }
}

public struct QueryResponse {
    /// `nil` when no HTTP response was received (offline, timeout, ...)
    public var statusCode: Int?
    public var data: Data?

    public init(statusCode: Int?, data: Data?) {
        self.statusCode = statusCode
        self.data = data
    }
}

public protocol QueryCancellable {
    func cancel()
}

/// Performs the HTTP request. Implement it on top of Alamofire or any other stack.
/// Call `completion` exactly once (on the main thread), unless the request was cancelled.
public protocol QueryNetworking {
    func perform(_ request: QueryRequest, completion: @escaping (QueryResponse) -> Void) -> QueryCancellable
}

/// Persistent storage for stale-while-revalidate (MMKV, UserDefaults, files, ...).
public protocol QueryCache {
    func set(_ data: Data, forKey key: String)
    func data(forKey key: String) -> Data?
    func remove(forKey key: String)
}

public final class QueryClient {
    public static let shared = QueryClient()

    public var networking: QueryNetworking
    public var cache: QueryCache

    public init(networking: QueryNetworking = URLSessionNetworking(), cache: QueryCache = InMemoryQueryCache()) {
        self.networking = networking
        self.cache = cache
    }
}

/// Non-persistent cache, the default.
public final class InMemoryQueryCache: QueryCache {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func set(_ data: Data, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = data
    }
    public func data(forKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }
    public func remove(forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = nil
    }
}
