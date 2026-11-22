//
//  AppCheckDebugTokens.swift
//  ContourApp — throwaway OpenAI demo, not for merging
//
//  The plan server answers 401 without an App Check token, and free signing can't
//  use App Attest. So this does what the SDK's debug provider does, without the SDK:
//  swaps a debug token made in the Firebase console for an App Check token, and
//  keeps that until it expires. The same call the SDKs make:
//  https://firebase.google.com/docs/reference/appcheck/rest/v1/projects.apps/exchangeDebugToken
//
//  Nothing here may print, log or show the three config values or the token.
//

import Foundation

/// What's in AppCheck.local.plist. Git ignores that file, and Neel makes it himself.
nonisolated struct AppCheckLocalConfig: Equatable, CustomStringConvertible, CustomReflectable {
    let appID: String
    let apiKey: String
    let debugToken: String

    var description: String { "AppCheckLocalConfig(hidden)" }
    var customMirror: Mirror { Mirror(self, children: [:]) }

    init(appID: String, apiKey: String, debugToken: String) {
        self.appID = appID
        self.apiKey = apiKey
        self.debugToken = debugToken
    }

    /// Fails naming the key that's missing, never showing what's in it.
    init(contentsOf url: URL) throws {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AppCheckTokenError.badConfig("the file")
        }
        func value(_ key: String) throws -> String {
            let found = (plist[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !found.isEmpty, !found.hasPrefix("PASTE_") else { throw AppCheckTokenError.badConfig(key) }
            return found
        }
        self.init(appID: try value("GOOGLE_APP_ID"), apiKey: try value("API_KEY"),
                  debugToken: try value("DEBUG_TOKEN"))
    }
}

/// Why there's no token. Only fixed words and a status code, so it's safe to show.
nonisolated enum AppCheckTokenError: LocalizedError, Equatable {
    case badConfig(String)
    case refused(status: Int)
    case unreachable
    case badResponse

    var errorDescription: String? {
        switch self {
        case .badConfig(let key): "check \(key) in AppCheck.local.plist"
        case .refused(let status): "App Check said \(status)"
        case .unreachable: "can't reach App Check"
        case .badResponse: "App Check sent a bad answer"
        }
    }
}

/// One App Check token at a time, shared by everyone who asks for it. Firebase
/// puts a restrictive quota on this call, so it only happens when it has to.
actor AppCheckDebugTokens {
    private struct Reply: Decodable {
        var token: String
        var ttl: String
    }

    /// Asks for a new one this long before it expires, so none dies on the way.
    private static let margin: TimeInterval = 60

    private let config: AppCheckLocalConfig
    private let projectID: String
    private let bundleID: String?
    private let session: URLSession
    private let now: @Sendable () -> Date
    private var cached: (token: String, expires: Date)?
    private var fetching: Task<String, any Error>?

    init(config: AppCheckLocalConfig, projectID: String, bundleID: String? = Bundle.main.bundleIdentifier,
         session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config
        self.projectID = projectID
        self.bundleID = bundleID
        self.session = session
        self.now = now
    }

    /// The cached token, or a new one. Cancelling stops the wait right away,
    /// because the plan's time limit includes getting this.
    func token() async throws -> String {
        if let cached, now() < cached.expires { return cached.token }
        let fetch = fetching ?? startFetching()
        return try await withTaskCancellationHandler {
            try await fetch.value
        } onCancel: {
            fetch.cancel()
        }
    }

    private func startFetching() -> Task<String, any Error> {
        let task = Task {
            defer { fetching = nil }
            let (token, lifetime) = try await exchange()
            cached = (token, now().addingTimeInterval(lifetime - Self.margin))
            return token
        }
        fetching = task
        return task
    }

    private func exchange() async throws -> (token: String, lifetime: TimeInterval) {
        let address = "https://firebaseappcheck.googleapis.com/v1/projects/\(projectID)/apps/\(config.appID):exchangeDebugToken"
        guard let url = URL(string: address) else { throw AppCheckTokenError.badConfig("GOOGLE_APP_ID") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The header, not ?key=, so the key never sits in a URL.
        request.setValue(config.apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        // For a key restricted to this app. The SDK sends it too.
        request.setValue(bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        request.httpBody = try JSONEncoder().encode(["debugToken": config.debugToken])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            try Task.checkCancellation()
            // Not the URLError itself: it carries the address.
            throw AppCheckTokenError.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw AppCheckTokenError.refused(status: status) }

        // "ttl" is a protobuf duration in seconds, like "3600s".
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), !reply.token.isEmpty,
              reply.ttl.hasSuffix("s"), let lifetime = TimeInterval(reply.ttl.dropLast()), lifetime > 0 else {
            throw AppCheckTokenError.badResponse
        }
        return (reply.token, lifetime)
    }
}
