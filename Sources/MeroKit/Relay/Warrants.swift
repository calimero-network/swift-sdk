import Foundation

/// The signed authorisations a delegated (relay) write carries, byte-identical
/// with mero-js `src/warrant/*` and core `crates/account/src/{warrant,creation,governance}.rs`.
///
/// Each is a borsh structure sent as hex, signed by the **device** key over a
/// `domainHash` preimage. Inputs are hex strings; outputs are hex.
public enum Warrants {
    static let warrantDomain = "calimero.warrant.v2"
    static let intentDomain = "calimero.warrant.intent.v1"
    static let creationDomain = "calimero.context-creation-warrant.v1"
    static let creationInitDomain = "calimero.context-creation.init.v1"
    static let governanceDomain = "calimero.governance-warrant.v1"
    static let governanceOpDomain = "calimero.governance-warrant.op.v1"

    /// A node refuses more cited heads than this per list.
    public static let maxCitedHeads = 64
    /// `MAX_WARRANT_RELEASE_VERSION_LEN`, in UTF-8 bytes.
    public static let maxReleaseVersionBytes = 256
    /// Context-creation labels (`name`, `serviceName`), in UTF-8 bytes.
    public static let maxLabelBytes = 256

    // MARK: - Data-write warrant (v2)

    /// The commitment to a call: `domainHash(INTENT, [method, canonicalJSON(args)])`.
    public static func intentHash(method: String, argsJson: JSONValue) -> Data {
        domainHash(intentDomain, [Data(method.utf8), CanonicalJSON.data(argsJson)])
    }

    /// The parts of a data-write warrant, before signing.
    public struct WarrantInput: Sendable {
        public var context: String
        public var authorAccount: String
        public var executor: String
        public var executorKey: String
        public var releaseBytecodeId: String
        public var releaseVersion: String
        public var method: String
        public var argsJson: JSONValue
        public var nonce: UInt64
        public var notAfter: UInt64
        public var accountHeads: [String]
        public var governanceFloor: [String]

        public init(
            context: String, authorAccount: String, executor: String, executorKey: String,
            releaseBytecodeId: String, releaseVersion: String = "", method: String, argsJson: JSONValue,
            nonce: UInt64, notAfter: UInt64, accountHeads: [String] = [], governanceFloor: [String] = []
        ) {
            self.context = context; self.authorAccount = authorAccount; self.executor = executor
            self.executorKey = executorKey; self.releaseBytecodeId = releaseBytecodeId
            self.releaseVersion = releaseVersion; self.method = method; self.argsJson = argsJson
            self.nonce = nonce; self.notAfter = notAfter; self.accountHeads = accountHeads
            self.governanceFloor = governanceFloor
        }
    }

    /// The 32-byte preimage the device signs for `input`, given its public key.
    public static func warrantPreimage(_ input: WarrantInput, devicePublicKey: Data) throws -> Data {
        let heads = try citedHeads(input.accountHeads, "accountHeads")
        let floor = try citedHeads(input.governanceFloor, "governanceFloor")
        var parts: [Data] = [
            try Hex.decode(input.context, label: "context", bytes: 32),
            try Hex.decode(input.authorAccount, label: "authorAccount", bytes: 32),
            devicePublicKey,
            try Hex.decode(input.executor, label: "executor", bytes: 32),
            try Hex.decode(input.executorKey, label: "executorKey", bytes: 32),
            try Hex.decode(input.releaseBytecodeId, label: "releaseBytecodeId", bytes: 32),
            try releaseVersionBytes(input.releaseVersion),
            Data(input.method.utf8),
            intentHash(method: input.method, argsJson: input.argsJson),
            LittleEndian.u64(UInt64(heads.count)),
        ]
        parts += heads
        parts.append(LittleEndian.u64(UInt64(floor.count)))
        parts += floor
        parts += [LittleEndian.u64(input.nonce), LittleEndian.u64(input.notAfter)]
        return domainHash(warrantDomain, parts)
    }

    /// Sign a data-write warrant with the device `keys`. Returns hex.
    public static func signWarrant(_ input: WarrantInput, keys: DeviceKeys) throws -> String {
        let publicKey = try Ed25519.publicKey(seed: keys.signSecret)
        let preimage = try warrantPreimage(input, devicePublicKey: publicKey)
        let signature = try keys.sign(preimage)
        return try warrantWire(input, devicePublicKey: publicKey, signature: signature)
    }

    /// The borsh wire layout of a data-write warrant (exposed for conformance tests).
    public static func warrantWire(_ input: WarrantInput, devicePublicKey: Data, signature: Data) throws -> String {
        let heads = try citedHeads(input.accountHeads, "accountHeads")
        let floor = try citedHeads(input.governanceFloor, "governanceFloor")
        var w = BorshWriter()
        w.raw(try Hex.decode(input.context, label: "context", bytes: 32))
        w.raw(try Hex.decode(input.authorAccount, label: "authorAccount", bytes: 32))
        w.raw(devicePublicKey)
        w.raw(try Hex.decode(input.executor, label: "executor", bytes: 32))
        w.raw(try Hex.decode(input.executorKey, label: "executorKey", bytes: 32))
        w.raw(try Hex.decode(input.releaseBytecodeId, label: "releaseBytecodeId", bytes: 32))
        w.bytes(try releaseVersionBytes(input.releaseVersion))
        w.string(input.method)
        w.raw(intentHash(method: input.method, argsJson: input.argsJson))
        w.u32(UInt32(heads.count))
        heads.forEach { w.raw($0) }
        w.u32(UInt32(floor.count))
        floor.forEach { w.raw($0) }
        w.u64(input.nonce)
        w.u64(input.notAfter)
        w.raw(try checkedSignature(signature))
        return Hex.encode(w.data)
    }

    // MARK: - Context-creation warrant

    /// The commitment to a new context's init args.
    public static func creationInitHash(_ initArgs: JSONValue) -> Data {
        domainHash(creationInitDomain, [CanonicalJSON.data(initArgs)])
    }

    public struct CreationInput: Sendable {
        public var group: String
        /// 64 hex; random when `nil`.
        public var seed: String?
        public var authorAccount: String
        public var executor: String
        public var executorKey: String
        public var applicationId: String
        public var serviceName: String?
        public var name: String?
        public var initArgs: JSONValue
        public var nonce: UInt64
        public var notAfter: UInt64
        public var accountHeads: [String]
        public var governanceFloor: [String]

        public init(
            group: String, seed: String? = nil, authorAccount: String, executor: String, executorKey: String,
            applicationId: String, serviceName: String? = nil, name: String? = nil, initArgs: JSONValue = [:],
            nonce: UInt64, notAfter: UInt64, accountHeads: [String] = [], governanceFloor: [String] = []
        ) {
            self.group = group; self.seed = seed; self.authorAccount = authorAccount; self.executor = executor
            self.executorKey = executorKey; self.applicationId = applicationId; self.serviceName = serviceName
            self.name = name; self.initArgs = initArgs; self.nonce = nonce; self.notAfter = notAfter
            self.accountHeads = accountHeads; self.governanceFloor = governanceFloor
        }
    }

    /// The creation preimage for `input` with a concrete `seed`.
    public static func creationPreimage(_ input: CreationInput, seed: Data, devicePublicKey: Data) throws -> Data {
        let heads = try citedHeads(input.accountHeads, "accountHeads")
        let floor = try citedHeads(input.governanceFloor, "governanceFloor")
        let serviceName = try label(input.serviceName, "serviceName")
        let name = try label(input.name, "name")
        var parts: [Data] = [
            try Hex.decode(input.group, label: "group", bytes: 32),
            seed,
            try Hex.decode(input.authorAccount, label: "authorAccount", bytes: 32),
            devicePublicKey,
            try Hex.decode(input.executor, label: "executor", bytes: 32),
            try Hex.decode(input.executorKey, label: "executorKey", bytes: 32),
            try Hex.decode(input.applicationId, label: "applicationId", bytes: 32),
            Data([serviceName == nil ? 0 : 1]),
            serviceName ?? Data(),
            Data([name == nil ? 0 : 1]),
            name ?? Data(),
            creationInitHash(input.initArgs),
            LittleEndian.u64(UInt64(heads.count)),
        ]
        parts += heads
        parts.append(LittleEndian.u64(UInt64(floor.count)))
        parts += floor
        parts += [LittleEndian.u64(input.nonce), LittleEndian.u64(input.notAfter)]
        return domainHash(creationDomain, parts)
    }

    /// Sign a context-creation warrant. Returns the warrant hex and the seed used.
    public static func signCreationWarrant(
        _ input: CreationInput, keys: DeviceKeys
    ) throws -> (
        warrant: String, seed: String
    ) {
        let seed = try input.seed.map { try Hex.decode($0, label: "seed", bytes: 32) } ?? randomBytes(32)
        let publicKey = try Ed25519.publicKey(seed: keys.signSecret)
        let signature = try keys.sign(try creationPreimage(input, seed: seed, devicePublicKey: publicKey))
        return (try creationWire(input, seed: seed, devicePublicKey: publicKey, signature: signature), Hex.encode(seed))
    }

    /// The borsh wire layout of a creation warrant.
    public static func creationWire(
        _ input: CreationInput, seed: Data, devicePublicKey: Data, signature: Data
    ) throws -> String {
        let heads = try citedHeads(input.accountHeads, "accountHeads")
        let floor = try citedHeads(input.governanceFloor, "governanceFloor")
        var w = BorshWriter()
        w.raw(try Hex.decode(input.group, label: "group", bytes: 32))
        w.raw(seed)
        w.raw(try Hex.decode(input.authorAccount, label: "authorAccount", bytes: 32))
        w.raw(devicePublicKey)
        w.raw(try Hex.decode(input.executor, label: "executor", bytes: 32))
        w.raw(try Hex.decode(input.executorKey, label: "executorKey", bytes: 32))
        w.raw(try Hex.decode(input.applicationId, label: "applicationId", bytes: 32))
        w.optionBytes(try label(input.serviceName, "serviceName"))
        w.optionBytes(try label(input.name, "name"))
        w.raw(creationInitHash(input.initArgs))
        w.u32(UInt32(heads.count))
        heads.forEach { w.raw($0) }
        w.u32(UInt32(floor.count))
        floor.forEach { w.raw($0) }
        w.u64(input.nonce)
        w.u64(input.notAfter)
        w.raw(try checkedSignature(signature))
        return Hex.encode(w.data)
    }

    // MARK: - Governance warrant

    /// A governance op: borsh `GroupOp` (`.group`) or `RootOp` (`.root`) bytes.
    public struct GovernanceOp: Sendable, Equatable {
        public enum Kind: UInt8, Sendable { case group = 0, root = 1 }
        public let kind: Kind
        public let bytes: Data

        public init(kind: Kind, bytes: Data) {
            self.kind = kind
            self.bytes = bytes
        }
    }

    public static func governanceOpHash(_ op: GovernanceOp) -> Data {
        domainHash(governanceOpDomain, [Data([op.kind.rawValue]), op.bytes])
    }

    public struct GovernanceInput: Sendable {
        public var scope: String
        public var op: GovernanceOp
        public var authorAccount: String
        public var executor: String
        public var executorKey: String
        public var nonce: UInt64
        public var notAfter: UInt64
        public var accountHeads: [String]
        public var governanceFloor: [String]

        public init(
            scope: String, op: GovernanceOp, authorAccount: String, executor: String, executorKey: String,
            nonce: UInt64, notAfter: UInt64, accountHeads: [String] = [], governanceFloor: [String] = []
        ) {
            self.scope = scope; self.op = op; self.authorAccount = authorAccount; self.executor = executor
            self.executorKey = executorKey; self.nonce = nonce; self.notAfter = notAfter
            self.accountHeads = accountHeads; self.governanceFloor = governanceFloor
        }
    }

    public static func governancePreimage(_ input: GovernanceInput, devicePublicKey: Data) throws -> Data {
        let heads = try citedHeads(input.accountHeads, "accountHeads")
        let floor = try citedHeads(input.governanceFloor, "governanceFloor")
        var parts: [Data] = [
            try Hex.decode(input.scope, label: "scope", bytes: 32),
            Data([input.op.kind.rawValue]),
            try Hex.decode(input.authorAccount, label: "authorAccount", bytes: 32),
            devicePublicKey,
            try Hex.decode(input.executor, label: "executor", bytes: 32),
            try Hex.decode(input.executorKey, label: "executorKey", bytes: 32),
            governanceOpHash(input.op),
            LittleEndian.u64(UInt64(heads.count)),
        ]
        parts += heads
        parts.append(LittleEndian.u64(UInt64(floor.count)))
        parts += floor
        parts += [LittleEndian.u64(input.nonce), LittleEndian.u64(input.notAfter)]
        return domainHash(governanceDomain, parts)
    }

    public static func signGovernanceWarrant(_ input: GovernanceInput, keys: DeviceKeys) throws -> String {
        let publicKey = try Ed25519.publicKey(seed: keys.signSecret)
        let signature = try keys.sign(try governancePreimage(input, devicePublicKey: publicKey))
        return try governanceWire(input, devicePublicKey: publicKey, signature: signature)
    }

    public static func governanceWire(
        _ input: GovernanceInput, devicePublicKey: Data, signature: Data
    ) throws
        -> String
    {
        let heads = try citedHeads(input.accountHeads, "accountHeads")
        let floor = try citedHeads(input.governanceFloor, "governanceFloor")
        var w = BorshWriter()
        w.raw(try Hex.decode(input.scope, label: "scope", bytes: 32))
        w.u8(input.op.kind.rawValue)
        w.raw(try Hex.decode(input.authorAccount, label: "authorAccount", bytes: 32))
        w.raw(devicePublicKey)
        w.raw(try Hex.decode(input.executor, label: "executor", bytes: 32))
        w.raw(try Hex.decode(input.executorKey, label: "executorKey", bytes: 32))
        w.raw(governanceOpHash(input.op))
        w.u32(UInt32(heads.count))
        heads.forEach { w.raw($0) }
        w.u32(UInt32(floor.count))
        floor.forEach { w.raw($0) }
        w.u64(input.nonce)
        w.u64(input.notAfter)
        w.raw(try checkedSignature(signature))
        return Hex.encode(w.data)
    }

    // MARK: - Helpers

    static func citedHeads(_ heads: [String], _ label: String) throws -> [Data] {
        guard heads.count <= maxCitedHeads else {
            throw AccountError.invalidInput(
                "\(label) cites \(heads.count) heads, over the \(maxCitedHeads) a node accepts")
        }
        return try heads.enumerated().map { try Hex.decode($1, label: "\(label)[\($0)]", bytes: 32) }
    }

    static func releaseVersionBytes(_ version: String) throws -> Data {
        let bytes = Data(version.utf8)
        guard bytes.count <= maxReleaseVersionBytes else {
            throw AccountError.invalidInput(
                "releaseVersion is \(bytes.count) bytes, over the \(maxReleaseVersionBytes) a node accepts")
        }
        return bytes
    }

    static func label(_ value: String?, _ what: String) throws -> Data? {
        guard let value else { return nil }
        let bytes = Data(value.utf8)
        guard bytes.count <= maxLabelBytes else {
            throw AccountError.invalidInput(
                "\(what) is \(bytes.count) UTF-8 bytes, over the \(maxLabelBytes) a node accepts")
        }
        return bytes
    }

    static func checkedSignature(_ signature: Data) throws -> Data {
        guard signature.count == 64 else {
            throw AccountError.protocolViolation("signer returned \(signature.count) bytes, expected 64")
        }
        return signature
    }
}
