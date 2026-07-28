import AloftProcess
import Darwin
import Foundation

struct LaunchedProcess: Sendable, Equatable {
    let pid: pid_t
    let processGroupID: pid_t
    let masterFileDescriptor: Int32
}

enum ChildWaitResult: Sendable, Equatable {
    case running
    case exited(code: Int32)
    case signaled(signal: Int32)
}

enum ProcessLaunchPhase: String, Sendable {
    case openPTY
    case errorPipe
    case fork
    case signalMask
    case setsid
    case controllingTTY
    case duplicateStandardIO
    case changeDirectory
    case exec
}

struct ProcessLaunchError: Error, Sendable, Equatable {
    let phase: ProcessLaunchPhase
    let code: Int32
}

enum ProcessLauncher {
    static func launch(command: String, cwd: String) throws -> LaunchedProcess {
        let result = command.withCString { commandPointer in
            cwd.withCString { cwdPointer in
                aloft_launch(commandPointer, cwdPointer)
            }
        }

        guard result.phase == ALOFT_LAUNCH_NONE else {
            throw ProcessLaunchError(
                phase: launchPhase(for: result.phase),
                code: Int32(result.error_code)
            )
        }

        return LaunchedProcess(
            pid: result.pid,
            processGroupID: result.pgid,
            masterFileDescriptor: Int32(result.master_fd)
        )
    }

    static func processGroupExists(_ pgid: pid_t) throws -> Bool {
        let result = aloft_process_group_exists(pgid)
        if result < 0 {
            throw posixError(-result)
        }
        return result == 1
    }

    static func signalProcessGroup(_ pgid: pid_t, signal: Int32) throws {
        let result = aloft_signal_process_group(pgid, signal)
        if result < 0 {
            throw posixError(-result)
        }
    }

    static func wait(pid: pid_t, noHang: Bool) throws -> ChildWaitResult {
        var status: Int32 = 0
        let result = aloft_waitpid(pid, &status, noHang ? WNOHANG : 0)

        if result == 0 {
            return .running
        }
        if result == -1 {
            throw posixError(errno)
        }
        if wIfExited(status) {
            return .exited(code: wExitStatus(status))
        }
        if wIfSignaled(status) {
            return .signaled(signal: wTermSignal(status))
        }

        preconditionFailure("waitpid returned an unsupported child state")
    }

    private static func launchPhase(
        for phase: aloft_launch_phase
    ) -> ProcessLaunchPhase {
        switch phase {
        case ALOFT_LAUNCH_OPEN_PTY:
            return .openPTY
        case ALOFT_LAUNCH_ERROR_PIPE:
            return .errorPipe
        case ALOFT_LAUNCH_FORK:
            return .fork
        case ALOFT_LAUNCH_SIGNAL_MASK:
            return .signalMask
        case ALOFT_LAUNCH_SETSID:
            return .setsid
        case ALOFT_LAUNCH_CONTROLLING_TTY:
            return .controllingTTY
        case ALOFT_LAUNCH_DUP_STDIO:
            return .duplicateStandardIO
        case ALOFT_LAUNCH_CHDIR:
            return .changeDirectory
        case ALOFT_LAUNCH_EXEC:
            return .exec
        case ALOFT_LAUNCH_NONE:
            preconditionFailure("successful launch has no failure phase")
        default:
            preconditionFailure("unknown launch phase \(phase.rawValue)")
        }
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private static func wIfExited(_ status: Int32) -> Bool {
        waitStatus(status) == 0
    }

    private static func wExitStatus(_ status: Int32) -> Int32 {
        (status >> 8) & 0xff
    }

    private static func wIfSignaled(_ status: Int32) -> Bool {
        let value = waitStatus(status)
        return value != 0x7f && value != 0
    }

    private static func wTermSignal(_ status: Int32) -> Int32 {
        waitStatus(status)
    }

    private static func waitStatus(_ status: Int32) -> Int32 {
        status & 0x7f
    }
}
