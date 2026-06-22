import Foundation

/// A resilience wrapper: retries a wrapped `LLMClient` on transient failures (network
/// blips, rate limits, 5xx) with backoff before giving up. Compose it around any client:
///
/// ```swift
/// let client = RetryingClient(wrapping: DeepSeekClient(config: cfg), maxAttempts: 4)
/// ```
///
/// The `backoff` closure is injectable so tests run instantly (pass `{ _ in }`); the
/// default sleeps with linear backoff (0.5s, 1s, 1.5s, …).
public struct RetryingClient: LLMClient {
    public let wrapped: LLMClient
    public let maxAttempts: Int
    /// Called between attempts with the attempt number just failed (1-based). Default:
    /// linear backoff. Override (e.g. `{ _ in }`) to disable the delay.
    public let backoff: @Sendable (Int) async -> Void
    /// Decides whether a thrown error is worth retrying. Default: retry everything.
    public let isRetryable: @Sendable (Error) -> Bool

    public init(wrapping: LLMClient,
                maxAttempts: Int = 3,
                isRetryable: @escaping @Sendable (Error) -> Bool = { _ in true },
                backoff: @escaping @Sendable (Int) async -> Void = { attempt in
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                }) {
        self.wrapped = wrapping
        self.maxAttempts = max(1, maxAttempts)
        self.isRetryable = isRetryable
        self.backoff = backoff
    }

    public func complete(messages: [ChatMessage], tools: [[String: Any]]) async throws -> Completion {
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                return try await wrapped.complete(messages: messages, tools: tools)
            } catch {
                lastError = error
                // Don't retry a non-retryable error, or after the final attempt.
                guard isRetryable(error), attempt < maxAttempts else { break }
                await backoff(attempt)
            }
        }
        throw lastError ?? RetryError.exhausted
    }

    public enum RetryError: Error { case exhausted }
}
