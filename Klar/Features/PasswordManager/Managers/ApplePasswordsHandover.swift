import Foundation
import Security

/// Keeps Klar paired with Apple's Passwords helper after it's quit, so the
/// next Klar, opened again or updated, doesn't ask for a new code.
///
/// The helper keeps its side of the pairing in memory only and exits when
/// its stdin closes, so the helper itself has to outlive the old Klar. As
/// Klar quits, it hands the helper's stdin and stdout to a keeper: Klar's own
/// executable, started with `keeperArgument` (KlarMain runs it before any of
/// the app). The keeper waits for the next Klar to connect to a Unix socket
/// in the user's temporary folder and passes it the two descriptors
/// (SCM_RIGHTS). The helper checks its parent only as it launches, so it
/// carries on with the new Klar.
///
/// Klar's side of the pairing (the session key) goes through the keychain
/// instead, where only Klar can read it, so whoever got hold of the pipes
/// couldn't read or forge a message. The keeper also hands them only to a
/// process signed like Klar.
///
/// The keeper waits for as long as it takes Klar to be opened again, unless
/// the helper ends the pairing or exits, or the keeper's quit: while it
/// waits, macOS 27 shows Klar as "Running in Background" in the Dock, and
/// quitting it there lets the helper go. Logging out ends both.
nonisolated enum ApplePasswordsHandover {
    static let keeperArgument = "--apple-passwords-keeper"

    /// How often the keeper checks that its socket is still the one a Klar
    /// would connect to: a later keeper replaces it, and a Klar that couldn't
    /// take over removes it.
    private static let socketCheckInterval: DispatchTimeInterval = .seconds(60)

    /// The descriptors the keeper starts with.
    private enum KeeperDescriptor {
        static let helperInput: Int32 = 3
        static let helperOutput: Int32 = 4
        static let listener: Int32 = 5
    }

    private static let keychainService = "com.itsnwa.browser.passwords-handover"

    /// Klar's side of the pairing.
    struct Pairing: Codable {
        let session: SRPSession.Pairing
        /// The helper's capabilities from its hello, as JSON.
        let capabilities: Data
        /// Replies are matched by request number, so the next Klar carries
        /// on counting rather than mistaking a late reply for its own.
        let nextRequestID: Int
    }

    private static var socketPath: String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("com.itsnwa.browser.passwords-handover").path
    }

    // MARK: - Quitting

    /// Hands the helper behind `connection` to a keeper for the next Klar,
    /// which then resumes `pairing`. Called as Klar quits: the connection
    /// stops reading either way.
    @discardableResult
    static func handOver(_ connection: NativeMessagingConnection, pairing: Pairing) -> Bool {
        // The keeper gets the requirement rather than reading it from its
        // own code, which an update replaces on disk.
        guard let requirement = designatedRequirement() else {
            logError(.passwords, "handover: no designated requirement")
            return false
        }
        guard save(pairing) else { return false }
        guard let listener = listen(at: socketPath) else {
            logError(.passwords, "handover: couldn't listen at \(socketPath) (errno \(errno))")
            deleteSavedPairing()
            return false
        }
        defer { close(listener) }
        guard let pipes = connection.detach() else {
            deleteSavedPairing()
            return false
        }
        defer {
            close(pipes.input)
            close(pipes.output)
        }
        guard spawnKeeper(helperInput: pipes.input, helperOutput: pipes.output, listener: listener, requirement: requirement) else {
            unlink(socketPath)
            deleteSavedPairing()
            return false
        }
        return true
    }

    private static func spawnKeeper(helperInput: Int32, helperOutput: Int32, listener: Int32, requirement: String) -> Bool {
        guard let executable = Bundle.main.executablePath else { return false }

        // The file actions run in order, so a source numbered 3 to 5 would be
        // replaced before it's copied: copy each above those first.
        let sources = [helperInput, helperOutput, listener].map { fcntl($0, F_DUPFD_CLOEXEC, 10) }
        defer { sources.filter { $0 >= 0 }.forEach { close($0) } }
        guard !sources.contains(where: { $0 < 0 }) else { return false }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Nothing of Klar's but what's handed over, and a session of its own,
        // away from whatever started Klar.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, sources[0], KeeperDescriptor.helperInput)
        posix_spawn_file_actions_adddup2(&actions, sources[1], KeeperDescriptor.helperOutput)
        posix_spawn_file_actions_adddup2(&actions, sources[2], KeeperDescriptor.listener)

        let arguments = [executable, keeperArgument, requirement].map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) } }
        // Without dyld's variables: a Debug run from Xcode inserts its log
        // filter, which the keeper, outliving the run with no console or
        // debugger, has no use for.
        let environment = ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix("DYLD_") }
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { environment.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, arguments, environment)
        guard status == 0 else {
            logError(.passwords, "handover: couldn't start the keeper (\(status))")
            return false
        }
        logDebug(.passwords, "handed the Passwords helper to a keeper (pid \(pid))")
        return true
    }

    /// The designated requirement of this build's code: for a signed Klar,
    /// its bundle identifier and Team ID, which the next version meets too.
    private static func designatedRequirement() -> String? {
        var running: SecCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running else { return nil }
        var onDisk: SecStaticCode?
        guard SecCodeCopyStaticCode(running, [], &onDisk) == errSecSuccess, let onDisk else { return nil }
        var designated: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(onDisk, [], &designated) == errSecSuccess, let designated else {
            return nil
        }
        var text: CFString?
        guard SecRequirementCopyString(designated, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }

    // MARK: - Keeper

    /// The keeper's whole life, in place of Klar's: hands the helper's pipes
    /// to the first process to connect that's signed like Klar, or lets the
    /// helper go once there's no pairing left to keep.
    static func runKeeper() -> Never {
        // A client that's gone must not take the keeper, and the helper, down.
        signal(SIGPIPE, SIG_IGN)
        let arguments = CommandLine.arguments
        var parsed: SecRequirement?
        guard
            arguments.count > 2,
            SecRequirementCreateWithString(arguments[2] as CFString, [], &parsed) == errSecSuccess,
            let requirement = parsed
        else { exit(EXIT_FAILURE) }
        let socketFile = fileIdentity(atPath: socketPath)
        let ownsSocket = { socketFile != nil && fileIdentity(atPath: socketPath) == socketFile }

        func finish(handedOver: Bool) -> Never {
            // The socket and the saved pairing are a later keeper's once it
            // has taken the address over.
            if ownsSocket() {
                unlink(socketPath)
                if !handedOver { deleteSavedPairing() }
            }
            exit(EXIT_SUCCESS)
        }

        let clients = DispatchSource.makeReadSource(fileDescriptor: KeeperDescriptor.listener, queue: .main)
        clients.setEventHandler {
            let client = accept(KeeperDescriptor.listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            guard peer(of: client, satisfies: requirement) else {
                logError(.passwords, "keeper: a process not signed like Klar connected")
                return
            }
            if send([KeeperDescriptor.helperInput, KeeperDescriptor.helperOutput], over: client) {
                finish(handedOver: true)
            }
        }

        // What the helper sends meanwhile, a whole message at a time, so the
        // next Klar starts reading at the start of one. Notices of codes that
        // arrived are dropped; a message ending the pairing, or one that
        // can't be read, leaves nothing to keep.
        var flags = fcntl(KeeperDescriptor.helperOutput, F_GETFL)
        if flags >= 0, flags & O_NONBLOCK != 0 {
            flags &= ~O_NONBLOCK
            _ = fcntl(KeeperDescriptor.helperOutput, F_SETFL, flags)
        }
        let helper = DispatchSource.makeReadSource(fileDescriptor: KeeperDescriptor.helperOutput, queue: .main)
        helper.setEventHandler {
            guard let message = readMessage(from: KeeperDescriptor.helperOutput),
                  ApplePasswordsManager.leavesPairing(message)
            else {
                logDebug(.passwords, "keeper: the Passwords helper ended the pairing or exited")
                finish(handedOver: false)
            }
        }

        let socketCheck = DispatchSource.makeTimerSource(queue: .main)
        socketCheck.schedule(deadline: .now() + socketCheckInterval, repeating: socketCheckInterval, leeway: .seconds(30))
        socketCheck.setEventHandler {
            if !ownsSocket() { finish(handedOver: false) }
        }

        // Quit from the Dock, or logging out.
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { finish(handedOver: false) }

        let sources: [DispatchSourceProtocol] = [clients, helper, socketCheck, termination]
        sources.forEach { $0.resume() }
        withExtendedLifetime(sources) { dispatchMain() }
    }

    /// One native messaging message from a blocking descriptor: its body, or
    /// nil at the end of the stream or for a length no message has.
    private static func readMessage(from descriptor: Int32) -> Data? {
        guard let header = read(4, from: descriptor) else { return nil }
        let length = header.enumerated().reduce(0) { total, byte in total | Int(byte.element) << (8 * byte.offset) }
        guard length <= 1 << 20 else { return nil }
        return read(length, from: descriptor)
    }

    private static func read(_ count: Int, from descriptor: Int32) -> Data? {
        var data = Data(count: count)
        var received = 0
        while received < count {
            let result = data.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress! + received, count - received)
            }
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { return nil }
            received += result
        }
        return data
    }

    /// Whether the process at the other end of `socket` is signed to meet
    /// `requirement`.
    private static func peer(of socket: Int32, satisfies requirement: SecRequirement) -> Bool {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        let attributes = [kSecGuestAttributeAudit: withUnsafeBytes(of: token) { Data($0) }] as CFDictionary
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let peer = guest else {
            return false
        }
        // Checks the code directory and signature against the running code,
        // not every page and resource: quick.
        return SecCodeCheckValidity(peer, [], requirement) == errSecSuccess
    }

    private static func fileIdentity(atPath path: String) -> [UInt64]? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return [UInt64(UInt32(bitPattern: info.st_dev)), info.st_ino]
    }

    // MARK: - Starting

    /// The helper's pipes and the pairing, if the Klar before this one handed
    /// them over as it quit. Waits on the keeper; call off the main thread.
    static func takeOver() -> (connection: NativeMessagingConnection, pairing: Pairing)? {
        // Most launches: no keeper, and nothing to read from the keychain.
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }
        // Whatever stops this one from taking over stops the next one too, so
        // the socket goes, and with it the keeper, which then lets the helper go.
        var handedOver = false
        defer { if !handedOver { unlink(socketPath) } }
        guard let pairing = takeSavedPairing() else { return nil }

        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        defer { close(socket) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard connect(socket, toPath: socketPath) else {
            logDebug(.passwords, "no keeper for the Passwords helper (errno \(errno))")
            return nil
        }
        guard let descriptors = receiveDescriptors(over: socket) else {
            logError(.passwords, "the keeper didn't hand over the Passwords helper")
            return nil
        }
        guard descriptors.count == 2 else {
            descriptors.forEach { close($0) }
            return nil
        }
        handedOver = true
        // Not for processes Klar starts.
        descriptors.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
        return (NativeMessagingConnection(adoptingInput: descriptors[0], output: descriptors[1]), pairing)
    }

    // MARK: - Keychain

    private static var keychainQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecUseDataProtectionKeychain: true
        ]
    }

    private static func save(_ pairing: Pairing) -> Bool {
        guard let data = try? JSONEncoder().encode(pairing) else { return false }
        deleteSavedPairing()
        var item = keychainQuery
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            logError(.passwords, "handover: couldn't save the pairing (\(status))")
            return false
        }
        return true
    }

    /// The saved pairing, which is deleted as it's read: it's for one launch.
    private static func takeSavedPairing() -> Pairing? {
        var query = keychainQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        deleteSavedPairing()
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Pairing.self, from: data)
    }

    private static func deleteSavedPairing() {
        SecItemDelete(keychainQuery as CFDictionary)
    }

    // MARK: - Sockets

    private static func listen(at path: String) -> Int32? {
        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { return nil }
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        unlink(path)
        guard
            var address = socketAddress(path),
            withUnsafePointer(to: &address, {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }) == 0,
            Darwin.listen(listener, 1) == 0
        else {
            close(listener)
            return nil
        }
        return listener
    }

    private static func connect(_ socket: Int32, toPath path: String) -> Bool {
        guard var address = socketAddress(path) else { return false }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
    }

    private static func socketAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    /// The header of a control message is 12 bytes, already aligned the way
    /// the descriptors after it need (CMSG_DATA).
    private static let controlHeaderLength = MemoryLayout<cmsghdr>.size

    private static func send(_ descriptors: [Int32], over socket: Int32) -> Bool {
        let length = controlHeaderLength + descriptors.count * MemoryLayout<Int32>.size
        let control = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: MemoryLayout<cmsghdr>.alignment)
        defer { control.deallocate() }
        control.storeBytes(
            of: cmsghdr(cmsg_len: socklen_t(length), cmsg_level: SOL_SOCKET, cmsg_type: SCM_RIGHTS),
            as: cmsghdr.self
        )
        for (index, descriptor) in descriptors.enumerated() {
            control.storeBytes(
                of: descriptor,
                toByteOffset: controlHeaderLength + index * MemoryLayout<Int32>.size,
                as: Int32.self
            )
        }
        // Descriptors travel with at least a byte of data.
        var byte: UInt8 = 0
        return withUnsafeMutablePointer(to: &byte) { bytePointer in
            var vector = iovec(iov_base: UnsafeMutableRawPointer(bytePointer), iov_len: 1)
            return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                var message = msghdr(
                    msg_name: nil, msg_namelen: 0,
                    msg_iov: vectorPointer, msg_iovlen: 1,
                    msg_control: control, msg_controllen: socklen_t(length),
                    msg_flags: 0
                )
                return sendmsg(socket, &message, 0) == 1
            }
        }
    }

    private static func receiveDescriptors(over socket: Int32) -> [Int32]? {
        // Room for more than are sent, so any extra ones are seen and closed.
        let capacity = controlHeaderLength + 4 * MemoryLayout<Int32>.size
        let control = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<cmsghdr>.alignment)
        defer { control.deallocate() }
        var byte: UInt8 = 0
        return withUnsafeMutablePointer(to: &byte) { bytePointer in
            var vector = iovec(iov_base: UnsafeMutableRawPointer(bytePointer), iov_len: 1)
            return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                var message = msghdr(
                    msg_name: nil, msg_namelen: 0,
                    msg_iov: vectorPointer, msg_iovlen: 1,
                    msg_control: control, msg_controllen: socklen_t(capacity),
                    msg_flags: 0
                )
                guard recvmsg(socket, &message, 0) == 1, Int(message.msg_controllen) >= controlHeaderLength else {
                    return nil
                }
                let header = control.load(as: cmsghdr.self)
                guard
                    header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS,
                    Int(header.cmsg_len) >= controlHeaderLength
                else { return nil }
                let count = (Int(header.cmsg_len) - controlHeaderLength) / MemoryLayout<Int32>.size
                let descriptors = (0..<count).map {
                    control.load(fromByteOffset: controlHeaderLength + $0 * MemoryLayout<Int32>.size, as: Int32.self)
                }
                guard message.msg_flags & MSG_CTRUNC == 0 else {
                    descriptors.forEach { close($0) }
                    return nil
                }
                return descriptors
            }
        }
    }
}
