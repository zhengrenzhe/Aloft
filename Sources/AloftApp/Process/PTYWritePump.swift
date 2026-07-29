import Darwin
import Foundation

struct PTYSystemCallError: Error, Equatable, Sendable {
    let code: Int32
}

struct PTYWritePump: Sendable {
    typealias WriteOperation = @Sendable (
        Int32,
        UnsafeRawBufferPointer
    ) -> Result<Int, PTYSystemCallError>
    typealias WaitWritableOperation = @Sendable (
        Int32
    ) -> Result<Bool, PTYSystemCallError>

    let write: WriteOperation
    let waitWritable: WaitWritableOperation

    static let live = PTYWritePump(
        write: { fileDescriptor, bytes in
            let count = Darwin.write(
                fileDescriptor,
                bytes.baseAddress,
                bytes.count
            )
            if count >= 0 {
                return .success(count)
            }
            return .failure(
                PTYSystemCallError(code: errno)
            )
        },
        waitWritable: { fileDescriptor in
            var descriptor = pollfd(
                fd: fileDescriptor,
                events: Int16(POLLOUT),
                revents: 0
            )
            let result = Darwin.poll(&descriptor, 1, 50)
            if result > 0 {
                let terminalEvents = Int16(
                    POLLERR | POLLHUP | POLLNVAL
                )
                if descriptor.revents & terminalEvents != 0 {
                    return .failure(
                        PTYSystemCallError(code: EIO)
                    )
                }
                return .success(
                    descriptor.revents & Int16(POLLOUT) != 0
                )
            }
            if result == 0 {
                return .success(false)
            }
            return .failure(
                PTYSystemCallError(code: errno)
            )
        }
    )

    func writeAll(
        _ data: Data,
        to fileDescriptor: Int32,
        isCancelled: () -> Bool
    ) throws {
        var offset = 0

        while offset < data.count {
            if isCancelled() {
                throw CocoaError(.userCancelled)
            }

            let result = data.withUnsafeBytes { bytes in
                write(
                    fileDescriptor,
                    UnsafeRawBufferPointer(
                        rebasing: bytes[offset...]
                    )
                )
            }
            switch result {
            case .success(let count) where count > 0:
                offset += count
            case .failure(let failure)
                where failure.code == EINTR:
                continue
            case .failure(let failure)
                where failure.code == EAGAIN
                    || failure.code == EWOULDBLOCK:
                switch waitWritable(fileDescriptor) {
                case .success:
                    continue
                case .failure(let waitFailure)
                    where waitFailure.code == EINTR:
                    continue
                case .failure(let waitFailure):
                    throw posixError(waitFailure.code)
                }
            case .success:
                throw posixError(EIO)
            case .failure(let failure):
                if isCancelled() {
                    throw CocoaError(.userCancelled)
                }
                throw posixError(failure.code)
            }
        }
    }

    private func posixError(_ code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code)
        )
    }
}
