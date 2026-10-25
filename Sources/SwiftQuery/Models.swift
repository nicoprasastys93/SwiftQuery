//
//  Models.swift
//  SwiftQuery
//
//  Response envelopes used by Query, InfiniteQuery and Mutation.
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
