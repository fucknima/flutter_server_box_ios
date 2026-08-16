import Foundation

struct TerminalOutputParser: Sendable {
    private enum Mode: Sendable {
        case normal
        case escape
        case csi
        case operatingSystemCommand
        case operatingSystemCommandEscape
        case stringCommand
        case stringCommandEscape
    }

    private var mode: Mode = .normal

    mutating func consume(_ chunk: String) -> String {
        var output = String()
        output.reserveCapacity(chunk.count)

        for scalar in chunk.unicodeScalars {
            let value = scalar.value

            switch mode {
            case .normal:
                consumeNormal(value, scalar: scalar, output: &output)
            case .escape:
                consumeEscape(value)
            case .csi:
                if (0x40...0x7E).contains(value) {
                    mode = .normal
                }
            case .operatingSystemCommand:
                if value == 0x07 {
                    mode = .normal
                } else if value == 0x1B {
                    mode = .operatingSystemCommandEscape
                }
            case .operatingSystemCommandEscape:
                mode = value == 0x5C ? .normal : .operatingSystemCommand
            case .stringCommand:
                if value == 0x1B {
                    mode = .stringCommandEscape
                }
            case .stringCommandEscape:
                mode = value == 0x5C ? .normal : .stringCommand
            }
        }

        return output
    }

    private mutating func consumeNormal(
        _ value: UInt32,
        scalar: Unicode.Scalar,
        output: inout String
    ) {
        switch value {
        case 0x1B:
            mode = .escape
        case 0x08:
            if !output.isEmpty {
                output.removeLast()
            }
        case 0x09, 0x0A:
            output.unicodeScalars.append(scalar)
        case 0x0D, 0x07, 0x7F:
            break
        case 0x00..<0x20:
            break
        default:
            output.unicodeScalars.append(scalar)
        }
    }

    private mutating func consumeEscape(_ value: UInt32) {
        switch value {
        case 0x5B:
            mode = .csi
        case 0x5D:
            mode = .operatingSystemCommand
        case 0x50, 0x5E, 0x5F:
            mode = .stringCommand
        default:
            mode = .normal
        }
    }
}
