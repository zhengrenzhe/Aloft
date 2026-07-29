import Darwin
import Dispatch
import Foundation
import AloftProcess

final class ManagedProcess: @unchecked Sendable {
    typealias OutputHandler = @Sendable (Data) -> Void

    private let fileDescriptor: Int32
    private let onOutput: OutputHandler
    private let source: DispatchSourceRead
    private let controlQueue: DispatchQueue
    private let controlFileDescriptor: Int32
    private let cancellationLock = NSLock()
    private var cancellationRequested = false

    init(
        masterFileDescriptor: Int32,
        onOutput: @escaping OutputHandler
    ) throws {
        let controlFileDescriptor = Darwin.fcntl(
            masterFileDescriptor,
            F_DUPFD_CLOEXEC,
            0
        )
        guard controlFileDescriptor >= 0 else {
            let error = errno
            Darwin.close(masterFileDescriptor)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(error)
            )
        }

        let readQueue = DispatchQueue(
            label: "com.aloft.managed-process.\(masterFileDescriptor)",
            qos: .utility
        )
        let source = DispatchSource.makeReadSource(
            fileDescriptor: masterFileDescriptor,
            queue: readQueue
        )
        let controlQueue = DispatchQueue(
            label: """
            com.aloft.managed-process.control.\
            \(controlFileDescriptor)
            """,
            qos: .utility
        )

        self.fileDescriptor = masterFileDescriptor
        self.onOutput = onOutput
        self.source = source
        self.controlQueue = controlQueue
        self.controlFileDescriptor = controlFileDescriptor

        source.setEventHandler { [weak self] in
            self?.readAvailableData()
        }
        source.setCancelHandler {
            Darwin.close(masterFileDescriptor)
        }
        source.resume()
    }

    deinit {
        close()
    }

    func close() {
        let mustCancel = cancellationLock.withLock {
            guard cancellationRequested == false else {
                return false
            }
            cancellationRequested = true
            return true
        }

        if mustCancel {
            source.cancel()
            let descriptorToClose = controlFileDescriptor
            controlQueue.async {
                Darwin.close(descriptorToClose)
            }
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            controlQueue.async { [self] in
                do {
                    try PTYWritePump.live.writeAll(
                        data,
                        to: controlFileDescriptor,
                        isCancelled: { [weak self] in
                            self?.isCancellationRequested ?? true
                        }
                    )
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func resize(_ size: TerminalSize) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            controlQueue.async { [self] in
                guard isCancellationRequested == false,
                      controlFileDescriptor >= 0 else {
                    continuation.resume(
                        throwing: CocoaError(.userCancelled)
                    )
                    return
                }
                let result = aloft_set_window_size(
                    controlFileDescriptor,
                    UInt16(size.rows),
                    UInt16(size.columns),
                    UInt16(size.pixelWidth),
                    UInt16(size.pixelHeight)
                )
                guard result == 0 else {
                    continuation.resume(
                        throwing: NSError(
                            domain: NSPOSIXErrorDomain,
                            code: Int(-result)
                        )
                    )
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    private var isCancellationRequested: Bool {
        cancellationLock.withLock {
            cancellationRequested
        }
    }

    private func readAvailableData() {
        var buffer = [UInt8](repeating: 0, count: 4_096)

        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(fileDescriptor, $0.baseAddress, $0.count)
            }

            if count > 0 {
                onOutput(Data(buffer.prefix(count)))
                continue
            }
            if count == 0 {
                close()
                return
            }

            switch errno {
            case EINTR:
                continue
            case EAGAIN:
                return
            case EIO:
                close()
                return
            default:
                close()
                return
            }
        }
    }
}
