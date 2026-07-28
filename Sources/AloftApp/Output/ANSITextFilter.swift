struct ANSITextFilter {
    private enum State {
        case text
        case escape
        case csi
        case osc
        case oscEscape
    }

    private var state: State = .text

    mutating func consume(_ text: String) -> String {
        var result = String.UnicodeScalarView()

        for scalar in text.unicodeScalars {
            switch state {
            case .text:
                if scalar.value == 0x1B {
                    state = .escape
                } else {
                    result.append(scalar)
                }
            case .escape:
                if scalar == "[" {
                    state = .csi
                } else if scalar == "]" {
                    state = .osc
                } else {
                    state = .text
                }
            case .csi:
                if (0x40...0x7E).contains(scalar.value) {
                    state = .text
                }
            case .osc:
                if scalar.value == 0x07 {
                    state = .text
                } else if scalar.value == 0x1B {
                    state = .oscEscape
                }
            case .oscEscape:
                state = scalar == "\\" ? .text : .osc
            }
        }

        return String(result)
    }
}
