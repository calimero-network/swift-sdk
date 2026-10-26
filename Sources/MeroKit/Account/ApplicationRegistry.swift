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
        /// The oldest node runtime that installs this bundle (`minRuntimeVersion`).
        /// A node older than this refuses the install outright.
        public let minRuntimeVersion: String?

        public init(
            package: String? = nil, signerId: String? = nil, appVersion: String? = nil, yanked: Bool = false,
            minRuntimeVersion: String? = nil
        ) {
            self.package = package; self.signerId = signerId; self.appVersion = appVersion; self.yanked = yanked
            self.minRuntimeVersion = minRuntimeVersion
        }

        init(json: JSONValue) {
            self.init(
                package: json["package"]?.stringValue, signerId: json["signerId"]?.stringValue,
                appVersion: json["appVersion"]?.stringValue, yanked: json["yanked"]?.boolValue == true,
                minRuntimeVersion: json["minRuntimeVersion"]?.stringValue ?? json["min_runtime_version"]?.stringValue)
        }
    }

    /// `sha256(borsh((package, signerId)))`, lowercase hex.
    public static func applicationIdForBundle(package: String, signerId: String) -> String {
        var w = BorshWriter()
        w.string(package)
        w.string(signerId)
        return Hex.encode(sha256(w.data))
    }

    /// The newest non-yanked version. With `runtimeVersion`, only versions a
    /// node on that runtime can install (`minRuntimeVersion` ≤ runtime); without
    /// it, any version.
    public static func selectLatest(_ bundles: [Bundle], runtimeVersion: String? = nil) -> Bundle? {
        bundles.filter {
            !$0.yanked && !($0.appVersion ?? "").isEmpty
                && supports(runtimeVersion: runtimeVersion, minRuntimeVersion: $0.minRuntimeVersion)
        }.reduce(nil) { best, b in
            guard let best else { return b }
            return compareVersions(b.appVersion ?? "", best.appVersion ?? "") > 0 ? b : best
        }
    }

    /// Semver precedence: negative when `a` sorts first, 0 when equal, positive
    /// when `a` sorts last. A prerelease sorts before its release
    /// (`0.12.0-rc.1` < `0.12.0`) and after every earlier release
    /// (`0.11.1` < `0.12.0-rc.1`); prerelease identifiers compare numerically
    /// when both are numbers (`rc.9` < `rc.10`). Build metadata is ignored.
    public static func compareVersions(_ a: String, _ b: String) -> Int {
        let (x, y) = (SemVer(a), SemVer(b))
        for i in 0..<max(x.core.count, y.core.count) {
            let (l, r) = (i < x.core.count ? x.core[i] : 0, i < y.core.count ? y.core[i] : 0)
            if l != r { return l < r ? -1 : 1 }
        }
        switch (x.pre.isEmpty, y.pre.isEmpty) {
        case (true, true): return 0
        case (true, false): return 1
        case (false, true): return -1
        case (false, false): break
        }
        for i in 0..<min(x.pre.count, y.pre.count) {
            let (l, r) = (x.pre[i], y.pre[i])
            switch (Int(l), Int(r)) {
            case (let ln?, let rn?): if ln != rn { return ln < rn ? -1 : 1 }
            case (.some, nil): return -1
            case (nil, .some): return 1
            case (nil, nil): if l != r { return l < r ? -1 : 1 }
            }
        }
        return x.pre.count == y.pre.count ? 0 : (x.pre.count < y.pre.count ? -1 : 1)
    }

    /// Whether a node on `runtimeVersion` installs a bundle that needs
    /// `minRuntimeVersion`. An unknown runtime or an undeclared minimum is no
    /// reason to refuse.
    public static func supports(runtimeVersion: String?, minRuntimeVersion: String?) -> Bool {
        guard let runtime = runtimeVersion, !runtime.isEmpty, let min = minRuntimeVersion, !min.isEmpty else {
            return true
        }
        return compareVersions(min, runtime) <= 0
    }

    /// The node's runtime version, read out of the error it answers an install
    /// of a too-new bundle with: "bundle requires runtime version X but current
    /// runtime is Y". The node exposes its runtime on no route, so this refusal
    /// is the one place it says it.
    public static func runtimeVersion(fromInstallError text: String) -> String? {
        guard let range = text.range(of: "current runtime is ") else { return nil }
        let version = text[range.upperBound...].prefix { $0.isLetter || $0.isNumber || ".-+".contains($0) }
        let trimmed = String(version).trimmingCharacters(in: CharacterSet(charactersIn: ".-+"))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// How many bundles ``newestCompatible(versions:yanked:skipping:runtimeVersion:limit:bundle:)``
    /// reads before giving up.
    static let compatibleWalkLimit = 64

    /// The newest of `versions` — less `yanked` and `skipping` (already
    /// checked) — whose bundle a node on `runtimeVersion` installs. Reads
    /// bundles newest first through `bundle`, at most `limit` of them.
    static func newestCompatible(
        versions: [String], yanked: [String], skipping: [String], runtimeVersion: String,
        limit: Int = compatibleWalkLimit, bundle: (String) async throws -> Bundle
    ) async throws -> String? {
        let excluded = Set(yanked).union(skipping)
        let candidates = Array(Set(versions)).filter { !excluded.contains($0) && !$0.isEmpty }
            .sorted { compareVersions($0, $1) > 0 }
        for version in candidates.prefix(limit) {
            let b = try await bundle(version)
            if !b.yanked, supports(runtimeVersion: runtimeVersion, minRuntimeVersion: b.minRuntimeVersion) {
                return version
            }
        }
        return nil
    }

    private struct SemVer {
        let core: [Int]
        let pre: [String]
        init(_ raw: String) {
            var v = Substring(raw.trimmingCharacters(in: .whitespaces))
            if v.first == "v" || v.first == "V" { v = v.dropFirst() }
            if let plus = v.firstIndex(of: "+") { v = v[..<plus] }
            let main: Substring
            if let dash = v.firstIndex(of: "-") {
                main = v[..<dash]
                pre = v[v.index(after: dash)...].split(separator: ".").map(String.init)
            } else {
                main = v
                pre = []
            }
            core = main.split(separator: ".", omittingEmptySubsequences: false).map {
                Int($0.prefix { $0.isNumber }) ?? 0
            }
        }
    }

    /// Every version of `package` the registry lists.
    public static func bundles(
        registryURL: String = defaultURL, package: String, session: URLSession = .shared
    ) async throws -> [Bundle] {
        let query = package.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? package
        let url = try AccountHTTP.url(registryURL, "/api/v2/bundles?package=\(query)")
        let body = try await AccountHTTP.send(
            AccountHTTP.jsonRequest(url, method: "GET", body: nil, timeout: 15), session: session)
        return (body.arrayValue ?? []).map(Bundle.init(json:))
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
