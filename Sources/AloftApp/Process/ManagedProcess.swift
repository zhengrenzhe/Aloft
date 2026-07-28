import Darwin
import Dispatch
import Foundation

final class ManagedProcess: @unchecked Sendable {
    typealias OutputHandler = @Sendable (Data) -> Void

    private let source: DispatchSourceRead
    private let state: State

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
        let state = State(
            fileDescriptor: masterFileDescriptor,
            onOutput: onOutput
        )

        self.source = source
        self.state = state

        source.setEventHandler { [state, weak source] in
            guard let source else {
                return
            }
            state.readAvailableData(from: source)
        }
        source.setCancelHandler {
            Darwin.close(masterFileDescriptor)
        }
        source.resume()
    }

    func close() {
        state.cancel(source)
    }
}

private extension ManagedProcess {
    final class State: @unchecked Sendable {
        private let fileDescriptor: Int32
        private let onOutput: OutputHandler
        private let cancellationLock = NSLock()
        private var cancellationRequested = false

        init(
            fileDescriptor: Int32,
            onOutput: @escaping OutputHandler
        ) {
            self.fileDescriptor = fileDescriptor
            self.onOutput = onOutput
        }

        func readAvailableData(from source: DispatchSourceRead) {
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
                    cancel(source)
                    return
                }

                switch errno {
                case EINTR:
                    continue
                case EAGAIN:
                    return
                case EIO:
                    cancel(source)
                    return
                default:
                    cancel(source)
                    return
                }
            }
        }

        func cancel(_ source: DispatchSourceRead) {
            cancellationLock.lock()
            let mustCancel = cancellationRequested == false
            cancellationRequested = true
            cancellationLock.unlock()

            if mustCancel {
                source.cancel()
            }
        }
    }
}
