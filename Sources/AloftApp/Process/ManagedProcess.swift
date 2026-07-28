import Darwin
import Dispatch
import Foundation

final class ManagedProcess: @unchecked Sendable {
    typealias OutputHandler = @Sendable (Data) -> Void

    private let fileDescriptor: Int32
    private let onOutput: OutputHandler
    private let source: DispatchSourceRead
    private let cancellationLock = NSLock()
    private var cancellationRequested = false

    init(
        masterFileDescriptor: Int32,
        onOutput: @escaping OutputHandler
    ) {
        let queue = DispatchQueue(
            label: "com.aloft.managed-process.\(masterFileDescriptor)",
            qos: .utility
        )
        let source = DispatchSource.makeReadSource(
            fileDescriptor: masterFileDescriptor,
            queue: queue
        )

        self.fileDescriptor = masterFileDescriptor
        self.onOutput = onOutput
        self.source = source

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
        cancellationLock.lock()
        let mustCancel = cancellationRequested == false
        cancellationRequested = true
        cancellationLock.unlock()

        if mustCancel {
            source.cancel()
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
