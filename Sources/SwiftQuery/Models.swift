//
//  Models.swift
//  SwiftQuery
//
//  Response envelopes used by Query, InfiniteQuery and Mutation.
//  Other response shapes plug in through QueryEnvelope / QueryPageEnvelope.
//

import Foundation

/// `{ "type": ..., "message": ..., "data": ... }`
/// Open so app models can subclass it (`class FooModel: BaseResponse<Bar>`).
open class BaseResponse<T: Decodable>: Decodable {
    public var type: String?
    public var message: String?
    public var data: T?

    private enum CodingKeys: CodingKey {
        case type, message, data
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        data = try container.decodeIfPresent(T.self, forKey: .data)
    }
}

/// Laravel-style paginated response: `{ "data": [...], "links": {...}, "meta": {...} }`
/// Open so app models can subclass it (`class FooListModel: BasePaginationResponse<Bar>`).
open class BasePaginationResponse<T: Decodable>: Decodable {
    public var data: [T]?
    public var links: Links?
    public var meta: Meta?

    private enum CodingKeys: CodingKey {
        case data, links, meta
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decodeIfPresent([T].self, forKey: .data)
        links = try container.decodeIfPresent(Links.self, forKey: .links)
        meta = try container.decodeIfPresent(Meta.self, forKey: .meta)
    }
}

public struct Links: Decodable {
    public var first: String?
    public var last: String?
    public var next: String?
    public var prev: String?
}

public struct Meta: Decodable {
    public var current_page: Int?
    public var from: Int?
    public var last_page: Int?
    public var links: [Links]?
    public var path: String?
    public var per_page: Int?
    public var to: Int?
    public var total: Int?
}

// MARK: - Envelopes
// Tell Query / InfiniteQuery / Mutation where the payload sits in a response body.

/// Wraps a single resource. `item` is what `Query` / `Mutation` expose as `state.data`.
///
///     struct Payload<T: Decodable>: QueryEnvelope {   // { "success": true, "payload": {...} }
///         let payload: T?
///         var item: T? { payload }
///     }
public protocol QueryEnvelope: Decodable {
    associatedtype Item
    var item: Item? { get }
}

/// Wraps one page of a list, used by `InfiniteQuery`.
///
///     struct CursorPage<T: Decodable>: QueryPageEnvelope {   // { "results": [...], "next_cursor": "abc" }
///         let results: [T]
///         let next_cursor: String?
///         var items: [T] { results }
///         func nextPageURL(currentURL: String) -> String? {
///             next_cursor.map { queryURL(currentURL, setting: "cursor", to: $0) }
///         }
///     }
public protocol QueryPageEnvelope: Decodable {
    associatedtype Item
    var items: [Item] { get }
    /// URL of the next page, `nil` on the last page.
    /// `currentURL` is the URL this page was loaded from, to build cursor / page-number URLs with `queryURL(_:setting:to:)`.
    func nextPageURL(currentURL: String) -> String?
}

/// `{ "type", "message", "data": {...} }` — the default for `Query` and `Mutation`.
extension BaseResponse: QueryEnvelope {
    public var item: T? { return data }
}

/// Laravel pagination — the default for `InfiniteQuery`.
extension BasePaginationResponse: QueryPageEnvelope {
    public var items: [T] { return data ?? [] }
    public func nextPageURL(currentURL: String) -> String? { return links?.next }
}

/// The body is the item itself, with no wrapper: `{ "id": 1 }` or `[...]`.
public struct Bare<T: Decodable>: QueryEnvelope {
    public let item: T?
    public init(from decoder: Decoder) throws {
        item = try T(from: decoder)
    }
}

/// The body is a plain JSON array `[...]`, loaded as a single page.
public struct BareList<T: Decodable>: QueryPageEnvelope {
    public let items: [T]
    public init(from decoder: Decoder) throws {
        items = try [T](from: decoder)
    }
    public func nextPageURL(currentURL: String) -> String? { return nil }
}

/// Returns `url` with the query item `name=value` set, replacing an existing one
/// (`queryURL("https://x/list?page=1", setting: "page", to: "2")` → `https://x/list?page=2`).
public func queryURL(_ url: String, setting name: String, to value: String) -> String {
    guard var components = URLComponents(string: url) else { return url }
    var items = (components.queryItems ?? []).filter { $0.name != name }
    items.append(URLQueryItem(name: name, value: value))
    components.queryItems = items
    return components.string ?? url
}

/// Type erasure so an `Encodable` existential can be stored and passed as a generic parameter.
public struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void
    public init(_ value: Encodable) {
        encodeFunc = value.encode
    }
    public func encode(to encoder: Encoder) throws {
        try encodeFunc(encoder)
    }
}
