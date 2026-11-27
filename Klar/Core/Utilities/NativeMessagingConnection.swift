import Foundation

/// Runs a native messaging host — the Mac app helper a browser extension
/// talks to — and exchanges length-prefixed JSON messages with it over stdio,
/// the protocol Chrome uses: each message is a 32-bit little-endian length
/// followed by that many bytes of UTF-8 JSON.
///
/// Used for Apple's PasswordManagerBrowserExtensionHelper
/// (ApplePasswordsManager) and for the hosts extensions connect to
/// (ExtensionNativeMessaging). Hosts exit when their stdin closes, so one
/// never outlives Klar; keeping one alive past Klar would make macOS show
/// Klar as running in the background. The one exception is the Passwords
/// helper, kept after Klar quits until it's opened again
/// (ApplePasswordsHandover).
nonisolated final class NativeMessagingConnection: @unchecked Sendable {
    /// Called on a background queue with each message body (JSON).
    var onMessage: (@Sendable (Data) -> Void)?
    /// Called once on a background queue when the host exits, after its
    /// last message.
    var onExit: (@Sendable () -> Void)?

    /// Nil for a host another Klar process started and handed over.
    private let process: Process?
    /// The host's stdin, written to.
    private let input: FileHandle
    /// The host's stdout, read from.
    private let output: FileHandle
    /// Messages and the exit, in order.
    private let readQueue = DispatchQueue(label: "com.itsnwa.browser.native-messaging", qos: .userInitiated)
    /// Writes, off the caller's thread: a host that stops reading would
    /// block the writer once the pipe fills.
    private let writeQueue = DispatchQueue(label: "com.itsnwa.browser.native-messaging.write", qos: .userInitiated)
    /// readQueue's.
    private var buffer = Data()
    private var didReportExit = false
    /// writeQueue's.
    private var isInputClosed = false

    /// `arguments` are what Chrome passes: the calling extension's origin.
    init(executableURL: URL, arguments: [String], workingDirectory: URL? = nil) {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        self.process = process
        self.input = input.fileHandleForWriting
        self.output = output.fileHandleForReading
    }

    /// A host that's already running: the write end of its stdin and the
    /// read end of its stdout, handed over from the Klar before this one.
    /// It's not this process's child, so its exit shows as its stdout ending.
    init(adoptingInput input: Int32, output: Int32) {
        process = nil
        self.input = FileHandle(fileDescriptor: input, closeOnDealloc: true)
        self.output = FileHandle(fileDescriptor: output, closeOnDealloc: true)
    }

    /// Launches the host, or starts reading from an adopted one.
    func start() throws {
        // A write after the host exits must fail with EPIPE rather than
        // raise SIGPIPE, which would terminate Klar.
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)

        output.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // The host's gone once everything it wrote has been read.
                handle.readabilityHandler = nil
                guard let self else { return }
                self.readQueue.async { [weak self] in self?.reportExit() }
                return
            }
            guard let self else { return }
            self.readQueue.async { [weak self] in self?.consume(data) }
        }
        guard let process else { return }
        process.terminationHandler = { [weak self] _ in
            // Its stdout ends with it, unless something it started holds
            // on to it.
            guard let self else { return }
            self.readQueue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.reportExit() }
        }
        do {
            try process.run()
        } catch {
            output.readabilityHandler = nil
            process.terminationHandler = nil
            closeInput()
            try? output.close()
            throw error
        }
        logDebug(.general, "native messaging host \(process.executableURL?.lastPathComponent ?? "?") launched (pid \(process.processIdentifier))")
    }

    /// Sends any JSON value: an object, array, string, number or bool.
    /// Throws if it isn't one; a host that's gone shows as onExit.
    func send(_ message: Any) throws {
        let body = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])
        var length = UInt32(body.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        let message = frame
        writeQueue.async { [self] in
            guard !isInputClosed else { return }
            do {
                try input.write(contentsOf: message)
            } catch {
                logWarning(.general, "Couldn't write to a native messaging host: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        output.readabilityHandler = nil
        // Closing stdin is the native messaging signal to exit.
        closeInput()
        if let process, process.isRunning { process.terminate() }
    }

    /// Stops reading and gives copies of the host's stdin (write end) and
    /// stdout (read end), closed on exec, for another process to carry on
    /// with. The host keeps running as long as any copy of its stdin is open.
    func detach() -> (input: Int32, output: Int32)? {
        output.readabilityHandler = nil
        process?.terminationHandler = nil
        // What's waiting goes out before another process writes.
        writeQueue.sync {}
        let inputCopy = fcntl(input.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        let outputCopy = fcntl(output.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard inputCopy >= 0, outputCopy >= 0 else {
            if inputCopy >= 0 { close(inputCopy) }
            if outputCopy >= 0 { close(outputCopy) }
            return nil
        }
        return (inputCopy, outputCopy)
    }

    /// On the write queue, so it never closes the descriptor under a write.
    private func closeInput() {
        writeQueue.async { [self] in
            guard !isInputClosed else { return }
            isInputClosed = true
            try? input.close()
        }
    }

    private func reportExit() {
        guard !didReportExit else { return }
        didReportExit = true
        onExit?()
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while buffer.count >= 4 {
            let length = buffer.prefix(4).enumerated().reduce(0) { total, byte in
                total | Int(byte.element) << (8 * byte.offset)
            }
            guard buffer.count >= 4 + length else { return }
            let body = buffer.dropFirst(4).prefix(length)
            buffer = Data(buffer.dropFirst(4 + length))
            onMessage?(Data(body))
        }
    }
}
