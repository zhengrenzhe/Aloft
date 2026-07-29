import AppKit
import Foundation

struct ReleaseTerminalBenchmarkConfiguration:
    Equatable,
    Sendable {
    let duration: Duration

    static func resolve(
        environment: [String: String]
    ) -> ReleaseTerminalBenchmarkConfiguration? {
        guard environment[
            "ALOFT_RELEASE_TERMINAL_BENCHMARK"
        ] == "1" else {
            return nil
        }
        let seconds = max(
            1,
            environment[
                "ALOFT_RELEASE_TERMINAL_BENCHMARK_SECONDS"
            ].flatMap(Int.init) ?? 20
        )
        return ReleaseTerminalBenchmarkConfiguration(
            duration: .seconds(seconds)
        )
    }
}

@MainActor
final class ReleaseTerminalBenchmarkController {
    private let configuration:
        ReleaseTerminalBenchmarkConfiguration
    private var window: NSWindow?
    private var surface: SwiftTermSurface?
    private var feedingTask: Task<Void, Never>?

    init(
        configuration:
            ReleaseTerminalBenchmarkConfiguration
    ) {
        self.configuration = configuration
    }

    func start() {
        let surface = SwiftTermSurface(
            callbacks: TerminalSurfaceCallbacks(
                writeProtocolReply: { _, _ in },
                resizePTY: { _, _ in }
            )
        )
        let generation = UUID()
        surface.prepare(generation: generation)
        surface.promote(
            generation: generation,
            at: Date()
        )

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 1_200,
                height: 800
            ),
            styleMask: [
                .titled,
                .closable,
                .resizable,
            ],
            backing: .buffered,
            defer: false
        )
        window.title = "Aloft Terminal Benchmark"
        window.animationBehavior = .none
        window.contentView = surface.nativeView
        window.center()

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        self.surface = surface
        self.window = window
        let duration = configuration.duration
        let chunk = releaseTerminalBenchmarkChunk()
        feedingTask = Task.detached(
            priority: .userInitiated
        ) {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(
                by: duration
            )
            while clock.now < deadline {
                for _ in 0..<16 {
                    surface.feed(
                        chunk,
                        generation: generation
                    )
                }
                await surface.waitUntilIdle()
            }
            await MainActor.run {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

private func releaseTerminalBenchmarkChunk() -> Data {
    let pattern = Data(
        (
            "\u{1b}[36mstream\u{1b}[0m "
                + "ready 👩🏽‍💻 "
                + String(repeating: "z", count: 96)
                + "\rframe=00042\u{1b}[K\n"
        ).utf8
    )
    var result = Data(capacity: 64 * 1_024)
    while result.count + pattern.count <= 64 * 1_024 {
        result.append(pattern)
    }
    result.append(
        pattern.prefix(64 * 1_024 - result.count)
    )
    return result
}
