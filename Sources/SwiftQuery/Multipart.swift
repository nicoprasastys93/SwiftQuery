//
//  Multipart.swift
//  SwiftQuery
//
//  multipart/form-data support for mutations (file uploads).
//

import Foundation

public enum QueryBodyEncoding {
    /// JSON body (query string for GET)
    case json
    /// multipart/form-data, requires `Variables: QueryMultipartEncodable`
    case multipart
}

public struct QueryMultipartPart {
    public var name: String
    public var data: Data
    public var fileName: String?
    public var mimeType: String?

    public init(name: String, data: Data, fileName: String? = nil, mimeType: String? = nil) {
        self.name = name
        self.data = data
        self.fileName = fileName
        self.mimeType = mimeType
    }

    /// Text field, UTF-8 encoded.
    public init?(name: String, value: String?) {
        guard let data = value?.data(using: .utf8) else { return nil }
        self.init(name: name, data: data)
    }
}

/// Implemented by mutation variables that are sent as multipart/form-data.
public protocol QueryMultipartEncodable {
    func multipartParts() -> [QueryMultipartPart]
}

extension Array where Element == QueryMultipartPart {
    /// Encodes the parts as a multipart/form-data body.
    func multipartBody(boundary: String) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        for part in self {
            append("--\(boundary)\r\n")
            var disposition = "Content-Disposition: form-data; name=\"\(part.name)\""
            if let fileName = part.fileName { disposition += "; filename=\"\(fileName)\"" }
            append(disposition + "\r\n")
            if let mimeType = part.mimeType { append("Content-Type: \(mimeType)\r\n") }
            append("\r\n")
            body.append(part.data)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        return body
    }
}
