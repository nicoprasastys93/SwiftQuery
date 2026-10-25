//
//  Mutation.swift
//  SwiftQuery
//
//  Swift take on useMutation from @tanstack/react-query
//  (response shaped like BaseResponse<Item>). Nothing runs until `mutate(_:)` is called.
//

import Foundation
import Combine

/// Failure details taken from the response body (`type` / `message`) of a non-2xx response.
public struct MutationError {
    /// `nil` when no HTTP response was received
    public var statusCode: Int?
    public var type: String?
    public var message: String?
}

public final class Mutation<Item: Decodable, Variables: Encodable> {

    public enum Status {
        /// Not called yet (or reset)
        case idle
        /// Request in flight
        case pending
        /// 2xx response
        case success
        /// Non-2xx response, see `error`
        case error
    }

    public struct State {
        public var data: Item?
        public var error: MutationError?
        public var status: Status = .idle

        public var isPending: Bool { return status == .pending }
        public var isSuccess: Bool { return status == .success }
        public var isError: Bool { return status == .error }
    }

    // MARK: - Public
    @Published public private(set) var state = State()
    public var statePublisher: AnyPublisher<State, Never> { return $state.eraseToAnyPublisher() }

    // MARK: - Private
    private let client: QueryClient
    private let url: () -> String?
    private let method: String
    private var request: QueryCancellable?
    /// Invalidates an in-flight response after reset
    private var generation = 0

    /// - Parameters:
    ///   - url: Endpoint URL, evaluated on every `mutate`.
    ///   - method: HTTP method, POST by default.
    ///   - client: Networking provider.
    public init(url: @escaping () -> String?, method: String = "POST", client: QueryClient = .shared) {
        self.client = client
        self.url = url
        self.method = method
    }
    deinit {
        request?.cancel()
    }

    // MARK: - Actions
    /// Send the request. Ignored while a previous call is still pending (no double submit).
    public func mutate(_ variables: Variables) {
        guard !state.isPending else { return }
        guard let url = url(), url != "" else { return }

        generation += 1
        let current = generation

        state = State(data: nil, error: nil, status: .pending)

        request = client.networking.perform(QueryRequest(url: url, method: method, parameters: AnyEncodable(variables))) { [weak self] response in
            guard let self = self, current == self.generation else { return }
            self.request = nil

            let isSuccess = (200..<300).contains(response.statusCode ?? 0)
            let body = response.data

            if isSuccess {
                let item = body.flatMap { try? JSONDecoder().decode(BaseResponse<Item>.self, from: $0).data }
                self.state = State(data: item, error: nil, status: .success)
            } else {
                let info = body.flatMap { try? JSONDecoder().decode(ErrorBody.self, from: $0) }
                let error = MutationError(statusCode: response.statusCode, type: info?.type, message: info?.message)
                self.state = State(data: nil, error: error, status: .error)
            }
        }
    }

    /// Cancel any in-flight request and go back to `.idle`.
    public func reset() {
        generation += 1
        request?.cancel()
        request = nil
        state = State()
    }
}
private struct ErrorBody: Decodable {
    var type: String?
    var message: String?
}
