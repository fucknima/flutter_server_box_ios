import Foundation

struct VirtKeyDefinition: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let sequence: String
    let explanation: String
}

enum VirtKeyCatalog {
    static let all: [VirtKeyDefinition] = [
        VirtKeyDefinition(
            id: "tab",
            label: "Tab",
            sequence: "\t",
            explanation: "Send the Tab key, used for shell completion."
        ),
        VirtKeyDefinition(
            id: "esc",
            label: "Esc",
            sequence: "\u{1B}",
            explanation: "Send the Escape key."
        ),
        VirtKeyDefinition(
            id: "ctrlC",
            label: "Ctrl-C",
            sequence: "\u{3}",
            explanation: "Interrupt or terminate the current foreground process."
        ),
        VirtKeyDefinition(
            id: "ctrlD",
            label: "Ctrl-D",
            sequence: "\u{4}",
            explanation: "Send end-of-file; closes the shell or exits the process."
        ),
        VirtKeyDefinition(
            id: "ctrlL",
            label: "Ctrl-L",
            sequence: "\u{C}",
            explanation: "Clear the terminal screen."
        ),
        VirtKeyDefinition(
            id: "ctrlZ",
            label: "Ctrl-Z",
            sequence: "\u{1A}",
            explanation: "Suspend the current foreground process."
        ),
        VirtKeyDefinition(
            id: "arrowUp",
            label: "\u{2191}",
            sequence: "\u{1B}[A",
            explanation: "Move the cursor up or recall the previous shell command."
        ),
        VirtKeyDefinition(
            id: "arrowDown",
            label: "\u{2193}",
            sequence: "\u{1B}[B",
            explanation: "Move the cursor down or recall the next shell command."
        ),
        VirtKeyDefinition(
            id: "arrowLeft",
            label: "\u{2190}",
            sequence: "\u{1B}[D",
            explanation: "Move the cursor left."
        ),
        VirtKeyDefinition(
            id: "arrowRight",
            label: "\u{2192}",
            sequence: "\u{1B}[C",
            explanation: "Move the cursor right."
        ),
        VirtKeyDefinition(
            id: "home",
            label: "Home",
            sequence: "\u{1B}[H",
            explanation: "Jump to the start of the current line."
        ),
        VirtKeyDefinition(
            id: "end",
            label: "End",
            sequence: "\u{1B}[F",
            explanation: "Jump to the end of the current line."
        ),
        VirtKeyDefinition(
            id: "pgup",
            label: "PgUp",
            sequence: "\u{1B}[5~",
            explanation: "Scroll the terminal up by one page."
        ),
        VirtKeyDefinition(
            id: "pgdn",
            label: "PgDn",
            sequence: "\u{1B}[6~",
            explanation: "Scroll the terminal down by one page."
        ),
    ]
}
