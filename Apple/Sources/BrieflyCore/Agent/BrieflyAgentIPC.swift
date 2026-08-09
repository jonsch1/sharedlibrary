#if os(macOS)
import Darwin
import Foundation

public enum BrieflyAgentIPC {
    public static let version = 1
    public static let appBundleIdentifier = "fyi.readbriefly.BrieflyNative"
    static let maximumFrameBytes = 2_000_000

    public static func socketURL(fileManager: FileManager = .default) throws -> URL {
        let directory = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Briefly", directoryHint: .isDirectory)
            .appending(path: "Agent", directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory.appending(path: "briefly.sock")
    }
}

public final class BrieflyAgentSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (BrieflyAgentCall) async -> BrieflyAgentReply

    private let handler: Handler
    private let requestedSocketURL: URL?
    private let queue = DispatchQueue(label: "fyi.readbriefly.agent-ipc")
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var socketDescriptor: Int32 = -1
    private var socketURL: URL?

    public init(socketURL: URL? = nil, handler: @escaping Handler) {
        requestedSocketURL = socketURL
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard source == nil else { return }

        let url = try requestedSocketURL ?? BrieflyAgentIPC.socketURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard url.path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw BrieflyAgentFailure(
                code: "ipc_unavailable",
                message: "Briefly's local agent socket path is too long."
            )
        }
        unlink(url.path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixFailure("create the local agent socket") }
        do {
            try bindSocket(descriptor, to: url.path)
            guard chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                throw posixFailure("secure the local agent socket")
            }
            guard listen(descriptor, 8) == 0 else {
                throw posixFailure("listen on the local agent socket")
            }
        } catch {
            Darwin.close(descriptor)
            unlink(url.path)
            throw error
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.resume()
        socketDescriptor = descriptor
        socketURL = url
        self.source = source
    }

    public func stop() {
        lock.lock()
        let source = self.source
        let descriptor = socketDescriptor
        let url = socketURL
        self.source = nil
        socketDescriptor = -1
        socketURL = nil
        lock.unlock()

        source?.cancel()
        if descriptor >= 0 { Darwin.close(descriptor) }
        if let url { unlink(url.path) }
    }

    private func acceptConnection() {
        lock.lock()
        let listener = socketDescriptor
        lock.unlock()
        guard listener >= 0 else { return }
        let descriptor = Darwin.accept(listener, nil, nil)
        guard descriptor >= 0 else { return }
        setTimeout(on: descriptor, seconds: 180)
        let handler = self.handler
        Task.detached {
            defer { Darwin.close(descriptor) }
            let reply: BrieflyAgentReply
            do {
                let requestData = try readFrame(from: descriptor)
                let call = try JSONDecoder().decode(BrieflyAgentCall.self, from: requestData)
                guard call.version == BrieflyAgentIPC.version else {
                    throw BrieflyAgentFailure(
                        code: "upgrade_required",
                        message: "Briefly and briefly-mcp use incompatible agent API versions."
                    )
                }
                reply = await handler(call)
            } catch let failure as BrieflyAgentFailure {
                reply = BrieflyAgentReply(error: failure)
            } catch {
                reply = BrieflyAgentReply(error: BrieflyAgentFailure(
                    code: "invalid_request",
                    message: "Briefly could not read the local agent request."
                ))
            }
            if let data = try? JSONEncoder().encode(reply) {
                try? writeFrame(data, to: descriptor)
            }
        }
    }
}

public struct BrieflyAgentSocketClient: Sendable {
    private let requestedSocketURL: URL?
    private let launchesApp: Bool

    public init(socketURL: URL? = nil, launchesApp: Bool = true) {
        requestedSocketURL = socketURL
        self.launchesApp = launchesApp
    }

    public func call(_ request: BrieflyAgentCall) async throws -> BrieflyAgentReply {
        let requestedSocketURL = self.requestedSocketURL
        let launchesApp = self.launchesApp
        return try await Task.detached {
            let url = try requestedSocketURL ?? BrieflyAgentIPC.socketURL()
            var descriptor = connectSocket(at: url.path)
            if descriptor < 0, launchesApp {
                try launchBriefly()
                let deadline = Date().addingTimeInterval(15)
                repeat {
                    usleep(100_000)
                    descriptor = connectSocket(at: url.path)
                } while descriptor < 0 && Date() < deadline
            }
            guard descriptor >= 0 else { throw BrieflyAgentFailure.unavailable }
            defer { Darwin.close(descriptor) }
            setTimeout(on: descriptor, seconds: 180)
            try writeFrame(try JSONEncoder().encode(request), to: descriptor)
            return try JSONDecoder().decode(
                BrieflyAgentReply.self,
                from: readFrame(from: descriptor)
            )
        }.value
    }
}

private func bindSocket(_ descriptor: Int32, to path: String) throws {
    var address = unixAddress(path)
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else { throw posixFailure("bind the local agent socket") }
}

private func connectSocket(at path: String) -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return -1 }
    var address = unixAddress(path)
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if result == 0 { return descriptor }
    Darwin.close(descriptor)
    return -1
}

private func unixAddress(_ path: String) -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    path.withCString { source in
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            _ = strncpy(
                destination.baseAddress?.assumingMemoryBound(to: CChar.self),
                source,
                destination.count - 1
            )
        }
    }
    return address
}

private func readFrame(from descriptor: Int32) throws -> Data {
    let header = try readExactly(4, from: descriptor)
    let length = header.withUnsafeBytes { bytes in
        bytes.loadUnaligned(as: UInt32.self).bigEndian
    }
    guard length > 0, length <= BrieflyAgentIPC.maximumFrameBytes else {
        throw BrieflyAgentFailure(
            code: "invalid_request",
            message: "The local agent message has an invalid size."
        )
    }
    return try readExactly(Int(length), from: descriptor)
}

private func writeFrame(_ data: Data, to descriptor: Int32) throws {
    guard !data.isEmpty, data.count <= BrieflyAgentIPC.maximumFrameBytes else {
        throw BrieflyAgentFailure(
            code: "invalid_request",
            message: "The local agent message is too large."
        )
    }
    var length = UInt32(data.count).bigEndian
    try withUnsafeBytes(of: &length) { bytes in
        try writeAll(Data(bytes), to: descriptor)
    }
    try writeAll(data, to: descriptor)
}

private func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
        let readCount = data.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress?.advanced(by: offset), count - offset)
        }
        guard readCount > 0 else { throw posixFailure("read the local agent response") }
        offset += readCount
    }
    return data
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
    var offset = 0
    while offset < data.count {
        let writeCount = data.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress?.advanced(by: offset), data.count - offset)
        }
        guard writeCount > 0 else { throw posixFailure("write the local agent request") }
        offset += writeCount
    }
}

private func setTimeout(on descriptor: Int32, seconds: Int) {
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    withUnsafePointer(to: &timeout) { pointer in
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            pointer,
            socklen_t(MemoryLayout<timeval>.size)
        )
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            pointer,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }
}

private func launchBriefly() throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/open")
    if let appPath = ProcessInfo.processInfo.environment["BRIEFLY_APP_PATH"], !appPath.isEmpty {
        process.arguments = ["-gj", appPath]
    } else {
        process.arguments = ["-gj", "-b", BrieflyAgentIPC.appBundleIdentifier]
    }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw BrieflyAgentFailure.unavailable }
}

private func posixFailure(_ action: String) -> BrieflyAgentFailure {
    BrieflyAgentFailure(
        code: "ipc_unavailable",
        message: "Briefly could not \(action)."
    )
}
#endif
