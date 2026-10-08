import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An application an account founds a namespace on, learned from the registry.
public struct ResolvedApplication: Sendable, Equatable {
    public let applicationId: String
    public let signerId: String
    public let version: String
}

/// An application's id computed the way merod computes it, and its latest
/// published version. Port of mero-js `src/account/application-id.ts`.
///
/// core's `ApplicationId::for_bundle(package, signer_id)` is
/// `sha256(borsh((package, signer_id)))`; the version is not an input. A node
/// learns the id when it installs the bundle; an account installs nothing, so
/// it derives the id from the registry's listing.
public enum ApplicationRegistry {
    public static let defaultURL = "https://apps.calimero.network"

    /// A bundle as `GET {registry}/api/v2/bundles?package=…` lists it.
    public struct Bundle: Sendable, Equatable {
        public let package: String?
        public let signerId: String?
        public let appVersion: String?
        public let yanked: Bool

        public init(package: String? = nil, signerId: String? = nil, appVersion: String? = nil, yanked: Bool = false) {
            self.package = package; self.signerId = signerId; self.appVersion = appVersion; self.yanked = yanked
        }
    }

    /// `sha256(borsh((package, signerId)))`, lowercase hex.
    public static func applicationIdForBundle(package: String, signerId: String) -> String {
        var w = BorshWriter()
        w.string(package)
        w.string(signerId)
        return Hex.encode(sha256(w.data))
    }

    /// The newest non-yanked version (numeric compare on `.`/`-` parts).
    public static func selectLatest(_ bundles: [Bundle]) -> Bundle? {
        bundles.filter { !$0.yanked && !($0.appVersion ?? "").isEmpty }.reduce(nil) { best, b in
            guard let best else { return b }
            return newer(b.appVersion ?? "", best.appVersion ?? "") ? b : best
        }
    }

    static func newer(_ a: String, _ b: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.split(whereSeparator: { $0 == "." || $0 == "-" }).map { Int($0) ?? 0 } }
        let (x, y) = (parts(a), parts(b))
        for i in 0..<max(x.count, y.count) {
            let (l, r) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if l != r { return l > r }
        }
        return false
    }

    /// Every version of `package` the registry lists.
    public static func bundles(
        registryURL: String = defaultURL, package: String, session: URLSession = .shared
    ) async throws -> [Bundle] {
        let query = package.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? package
        let url = try AccountHTTP.url(registryURL, "/api/v2/bundles?package=\(query)")
        let body = try await AccountHTTP.send(
            AccountHTTP.jsonRequest(url, method: "GET", body: nil, timeout: 15), session: session)
        return (body.arrayValue ?? []).map {
            Bundle(
                package: $0["package"]?.stringValue, signerId: $0["signerId"]?.stringValue,
                appVersion: $0["appVersion"]?.stringValue, yanked: $0["yanked"]?.boolValue == true)
        }
    }

    /// The application id an account founds `package` on. Refused when the live
    /// versions name more than one publisher: that is two applications under
    /// one name, and the founder signs the id.
    public static func resolve(
        registryURL: String = defaultURL, package: String, session: URLSession = .shared
    ) async throws -> ResolvedApplication {
        let live = try await bundles(registryURL: registryURL, package: package, session: session).filter { !$0.yanked }
        let signers = Set(live.compactMap { $0.signerId }.filter { !$0.isEmpty })
        guard signers.count <= 1 else {
            throw AccountError.invalidInput(
                "the registry lists \(package) under more than one publisher (\(signers.sorted().joined(separator: ", "))): "
                    + "refusing to guess which application it is")
        }
        guard let latest = selectLatest(live), let version = latest.appVersion else {
            throw AccountError.invalidInput("the registry lists no version of \(package)")
        }
        guard let signerId = latest.signerId, !signerId.isEmpty else {
            throw AccountError.invalidInput("the registry names no publisher for \(package) \(version)")
        }
        return ResolvedApplication(
            applicationId: applicationIdForBundle(package: package, signerId: signerId), signerId: signerId,
            version: version)
    }
}
