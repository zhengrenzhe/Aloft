import Foundation

struct UTF8StreamDecoder {
    private var trailingBytes: [UInt8] = []

    mutating func consume(_ data: Data) -> String {
        let bytes = trailingBytes + data
        let incompleteCount = incompleteSuffixCount(in: bytes)
        let completeCount = bytes.count - incompleteCount

        trailingBytes = incompleteCount == 0 ? [] : Array(bytes.suffix(incompleteCount))
        return String(decoding: bytes.prefix(completeCount), as: UTF8.self)
    }

    mutating func finish() -> String {
        defer { trailingBytes.removeAll() }
        return String(decoding: trailingBytes, as: UTF8.self)
    }

    private func incompleteSuffixCount(in bytes: [UInt8]) -> Int {
        guard !bytes.isEmpty else { return 0 }

        var continuationCount = 0
        var index = bytes.count
        while index > 0, continuationCount < 3, isContinuation(bytes[index - 1]) {
            continuationCount += 1
            index -= 1
        }

        guard index > 0 else { return 0 }

        let leadingByte = bytes[index - 1]
        let scalarLength: Int
        switch leadingByte {
        case 0xC2...0xDF: scalarLength = 2
        case 0xE0...0xEF: scalarLength = 3
        case 0xF0...0xF4: scalarLength = 4
        default: return 0
        }

        if continuationCount > 0 {
            let secondByte = bytes[index]
            switch leadingByte {
            case 0xE0 where secondByte < 0xA0,
                 0xED where secondByte > 0x9F,
                 0xF0 where secondByte < 0x90,
                 0xF4 where secondByte > 0x8F:
                return 0
            default:
                break
            }
        }

        let availableLength = continuationCount + 1
        return availableLength < scalarLength ? availableLength : 0
    }

    private func isContinuation(_ byte: UInt8) -> Bool {
        byte & 0xC0 == 0x80
    }
}
