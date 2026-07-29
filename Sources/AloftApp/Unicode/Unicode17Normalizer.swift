enum Unicode17Normalizer {
    static func normalize(_ scalars: some Sequence<UInt32>) -> [UInt32] {
        var builder = Builder()
        for scalar in scalars {
            builder.append(scalar)
        }
        return builder.scalars
    }

    struct Builder: Sendable {
        private(set) var scalars: [UInt32] = []

        var count: Int { scalars.count }

        mutating func append(_ scalar: UInt32) {
            appendCanonicalDecomposition(of: scalar)
        }

        mutating func reset() {
            scalars.removeAll(keepingCapacity: true)
        }

        private mutating func appendCanonicalDecomposition(of scalar: UInt32) {
            if Self.isHangulSyllable(scalar) {
                let syllableIndex = scalar - Self.hangulSBase
                let leading = Self.hangulLBase + syllableIndex / Self.hangulNCount
                let vowel = Self.hangulVBase
                    + (syllableIndex % Self.hangulNCount) / Self.hangulTCount
                let trailingIndex = syllableIndex % Self.hangulTCount
                insertCanonicalOrdered(leading)
                insertCanonicalOrdered(vowel)
                if trailingIndex != 0 {
                    insertCanonicalOrdered(Self.hangulTBase + trailingIndex)
                }
            } else if let decomposition = Unicode17Data.canonicalDecomposition(of: scalar) {
                for component in decomposition {
                    appendCanonicalDecomposition(of: component)
                }
            } else {
                insertCanonicalOrdered(scalar)
            }
        }

        private mutating func insertCanonicalOrdered(_ scalar: UInt32) {
            let combiningClass = Unicode17Data.canonicalCombiningClass(of: scalar)
            scalars.append(scalar)
            guard combiningClass != 0 else { return }

            var index = scalars.index(before: scalars.endIndex)
            while index > scalars.startIndex {
                let previousIndex = scalars.index(before: index)
                let previousClass = Unicode17Data.canonicalCombiningClass(
                    of: scalars[previousIndex]
                )
                guard previousClass != 0, previousClass > combiningClass else {
                    break
                }
                scalars.swapAt(previousIndex, index)
                index = previousIndex
            }
        }

        private static let hangulSBase: UInt32 = 0xAC00
        private static let hangulLBase: UInt32 = 0x1100
        private static let hangulVBase: UInt32 = 0x1161
        private static let hangulTBase: UInt32 = 0x11A7
        private static let hangulLCount: UInt32 = 19
        private static let hangulVCount: UInt32 = 21
        private static let hangulTCount: UInt32 = 28
        private static let hangulNCount = hangulVCount * hangulTCount
        private static let hangulSCount = hangulLCount * hangulNCount

        private static func isHangulSyllable(_ scalar: UInt32) -> Bool {
            scalar >= hangulSBase && scalar < hangulSBase + hangulSCount
        }
    }
}
