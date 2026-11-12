#if DEBUG
import Foundation

/// Keeps slow photo imports from landing after the inputs they were for are
/// gone. Starting an import of a kind, or resetting, cancels and invalidates
/// the previous import of that kind; a late result is applied only while its
/// token is still current.
@MainActor
final class ReplayImports {
    enum Kind: Hashable { case reference, photos }

    struct Token: Equatable {
        let kind: Kind
        let generation: UInt64
    }

    private var generations: [Kind: UInt64] = [:]
    private var tasks: [Kind: Task<Void, Never>] = [:]

    /// A new import of `kind` that supersedes any pending one. Use directly
    /// for synchronous imports (Files, the example) so they also win over a
    /// slow Photos import still in flight.
    @discardableResult
    func begin(_ kind: Kind) -> Token {
        tasks[kind]?.cancel()
        tasks[kind] = nil
        generations[kind, default: 0] &+= 1
        return Token(kind: kind, generation: generations[kind]!)
    }

    /// Runs an asynchronous import of `kind`, superseding any pending one.
    func start(_ kind: Kind, _ operation: @escaping @MainActor (Token) async -> Void) {
        let token = begin(kind)
        tasks[kind] = Task { await operation(token) }
    }

    func isCurrent(_ token: Token) -> Bool {
        generations[token.kind] == token.generation && !Task.isCancelled
    }

    /// Cancels and invalidates every pending import (reset, leaving the tool).
    func cancelAll() {
        for kind in [Kind.reference, .photos] { begin(kind) }
    }
}
#endif
