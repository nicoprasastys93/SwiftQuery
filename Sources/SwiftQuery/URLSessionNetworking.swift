//
//  URLSessionNetworking.swift
//  SwiftQuery
//
//  Default QueryNetworking built on URLSession.
//

import Foundation

extension URLSessionTask: QueryCancellable {}

public final class URLSessionNetworking: QueryNetworking {
    private let session: URLSession
    private let headers: () -> [String: String]

    /// - Parameter headers: Evaluated on every request (e.g. to read the current auth token).
    public init(session: URLSession = .shared, headers: @escaping () -> [String: String] = { [:] }) {
        self.session = session
        self.headers = headers
    }

    public func perform(_ request: QueryRequest, completion: @escaping (QueryResponse) -> Void) -> QueryCancellable {
        guard var components = URLComponents(string: request.url) else {
            DispatchQueue.main.async { completion(QueryResponse(statusCode: nil, data: nil)) }
            return NoopCancellable()
        }
        let isQueryMethod = request.method.uppercased() == "GET"
        if isQueryMethod, let parameters = request.parameters {
            let items = Self.queryItems(from: parameters)
            if !items.isEmpty {
                components.queryItems = (components.queryItems ?? []) + items
            }
        }
        guard let url = components.url else {
            DispatchQueue.main.async { completion(QueryResponse(statusCode: nil, data: nil)) }
            return NoopCancellable()
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.uppercased()
        headers().forEach { urlRequest.setValue($1, forHTTPHeaderField: $0) }
        if !isQueryMethod, let parameters = request.parameters {
            urlRequest.httpBody = try? JSONEncoder().encode(parameters)
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let task = session.dataTask(with: urlRequest) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode
            DispatchQueue.main.async { completion(QueryResponse(statusCode: status, data: data)) }
        }
        task.resume()
        return task
    }

    /// Flattens an `Encodable` into `key` / `parent[child]` / `list[0]` query items.
    static func queryItems(from value: Encodable) -> [URLQueryItem] {
        guard let data = try? JSONEncoder().encode(AnyEncodable(value)),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            return []
        }
        var items: [URLQueryItem] = []
        func append(_ value: Any, key: String) {
            switch value {
            case let dict as [String: Any]:
                dict.sorted { $0.key < $1.key }.forEach { append($0.value, key: "\(key)[\($0.key)]") }
            case let array as [Any]:
                array.enumerated().forEach { append($0.element, key: "\(key)[\($0.offset)]") }
            case is NSNull:
                break
            case let number as NSNumber:
                // JSONSerialization bridges Bool to NSNumber; keep it as true/false
                let isBool = CFGetTypeID(number) == CFBooleanGetTypeID()
                items.append(URLQueryItem(name: key, value: isBool ? (number.boolValue ? "true" : "false") : number.stringValue))
            default:
                items.append(URLQueryItem(name: key, value: "\(value)"))
            }
        }
        object.sorted { $0.key < $1.key }.forEach { append($0.value, key: $0.key) }
        return items
    }
}

private struct NoopCancellable: QueryCancellable {
    func cancel() {}
}
