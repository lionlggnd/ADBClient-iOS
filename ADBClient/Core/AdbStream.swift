import Foundation

/// One logical stream (service) inside an ADB connection.
///
/// Reading is either pull-based (`read`, `readExactly`, `readAll`, blocking) or push-based
/// after `setHandlers`, which delivers data and close events in order on a private queue.
final class AdbStream {
    private enum State { case opening, open, closed, failed }

    let localId: UInt32
    private(set) var remoteId: UInt32 = 0
    private let connection: AdbConnection

    private let condition = NSCondition()
    private var state = State.opening
    private var writeReady = false
    private var buffer: [UInt8] = []
    private var readPosition = 0

    private let deliveryQueue = DispatchQueue(label: "adb.stream.delivery")
    private var dataHandler: ((Data) -> Void)?
    private var closeHandler: (() -> Void)?
    private var closeDelivered = false

    init(localId: UInt32, connection: AdbConnection) {
        self.localId = localId
        self.connection = connection
    }

    var isOpen: Bool {
        condition.lock()
        defer { condition.unlock() }
        return state == .open
    }

    // MARK: Events from the reader thread

    func didReceiveOkay(remoteId: UInt32) {
        condition.lock()
        if state == .opening {
            self.remoteId = remoteId
            state = .open
        }
        writeReady = true
        condition.broadcast()
        condition.unlock()
    }

    func didReceive(_ data: Data) {
        condition.lock()
        if let handler = dataHandler {
            deliveryQueue.async { handler(data) }
        } else {
            buffer.append(contentsOf: data)
            condition.broadcast()
        }
        condition.unlock()
    }

    func remoteClosed() {
        condition.lock()
        state = state == .opening ? .failed : .closed
        condition.broadcast()
        deliverCloseLocked()
        condition.unlock()
    }

    private func deliverCloseLocked() {
        guard let handler = closeHandler, !closeDelivered else { return }
        closeDelivered = true
        deliveryQueue.async { handler() }
    }

    // MARK: API

    func waitForOpen(service: String, timeout: TimeInterval) throws {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while state == .opening {
            if !condition.wait(until: deadline) { throw AdbError.timeout }
        }
        if state != .open { throw AdbError.streamOpenFailed(service) }
    }

    func setHandlers(onData: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        condition.lock()
        dataHandler = onData
        closeHandler = onClose
        if readPosition < buffer.count {
            let pending = Data(buffer[readPosition...])
            deliveryQueue.async { onData(pending) }
        }
        buffer.removeAll()
        readPosition = 0
        if state == .closed || state == .failed { deliverCloseLocked() }
        condition.unlock()
    }

    func write(_ data: Data) throws {
        var offset = 0
        let chunkSize = connection.maxPayload
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end))
            condition.lock()
            while !writeReady && state == .open { condition.wait() }
            guard state == .open else {
                condition.unlock()
                throw AdbError.closed
            }
            writeReady = false
            let remote = remoteId
            condition.unlock()
            try connection.send(AdbMessage(AdbMessage.wrte, localId, remote, chunk))
            offset = end
        }
    }

    /// Returns available data, or nil once the stream is closed and drained.
    func read() throws -> Data? {
        condition.lock()
        defer { condition.unlock() }
        while readPosition >= buffer.count && state == .open { condition.wait() }
        guard readPosition < buffer.count else { return nil }
        let data = Data(buffer[readPosition...])
        buffer.removeAll(keepingCapacity: true)
        readPosition = 0
        return data
    }

    func readExactly(_ count: Int) throws -> Data {
        condition.lock()
        defer { condition.unlock() }
        while buffer.count - readPosition < count {
            if state != .open { throw AdbError.closed }
            condition.wait()
        }
        let data = Data(buffer[readPosition..<(readPosition + count)])
        readPosition += count
        if readPosition == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readPosition = 0
        } else if readPosition > 1 << 20 {
            buffer.removeFirst(readPosition)
            readPosition = 0
        }
        return data
    }

    func readAll() throws -> Data {
        var output = Data()
        while let chunk = try read() { output.append(chunk) }
        return output
    }

    func close() {
        connection.closeStream(self)
        condition.lock()
        if state == .open || state == .opening { state = .closed }
        condition.broadcast()
        deliverCloseLocked()
        condition.unlock()
    }
}
