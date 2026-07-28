#include "AloftProcess.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

typedef struct {
    aloft_launch_phase phase;
    int error_code;
} aloft_child_error;

static aloft_launch_result failure(aloft_launch_phase phase, int error_code) {
    aloft_launch_result result = {
        .pid = -1,
        .pgid = -1,
        .master_fd = -1,
        .phase = phase,
        .error_code = error_code,
    };
    return result;
}

static void child_fail(int error_fd, aloft_launch_phase phase) {
    int error_code = errno;
    aloft_child_error error = {
        .phase = phase,
        .error_code = error_code,
    };
    (void)write(error_fd, &error, sizeof(error));
    _exit(127);
}

static void reap_child(pid_t pid) {
    while (waitpid(pid, NULL, 0) == -1 && errno == EINTR) {
    }
}

static void terminate_and_reap_child(pid_t pid) {
    if (killpg(pid, SIGKILL) == -1 && errno == ESRCH) {
        (void)kill(pid, SIGKILL);
    }
    reap_child(pid);
}

aloft_launch_result aloft_launch(const char *command, const char *cwd) {
    int master_fd = -1;
    int slave_fd = -1;
    int error_pipe[2] = {-1, -1};

    if (openpty(&master_fd, &slave_fd, NULL, NULL, NULL) == -1) {
        return failure(ALOFT_LAUNCH_OPEN_PTY, errno);
    }
    if (pipe(error_pipe) == -1) {
        int error_code = errno;
        close(master_fd);
        close(slave_fd);
        return failure(ALOFT_LAUNCH_ERROR_PIPE, error_code);
    }
    if (fcntl(error_pipe[1], F_SETFD, FD_CLOEXEC) == -1) {
        int error_code = errno;
        close(error_pipe[0]);
        close(error_pipe[1]);
        close(master_fd);
        close(slave_fd);
        return failure(ALOFT_LAUNCH_ERROR_PIPE, error_code);
    }

    pid_t pid = fork();
    if (pid == -1) {
        int error_code = errno;
        close(error_pipe[0]);
        close(error_pipe[1]);
        close(master_fd);
        close(slave_fd);
        return failure(ALOFT_LAUNCH_FORK, error_code);
    }

    if (pid == 0) {
        close(error_pipe[0]);

        sigset_t empty_set;
        if (sigemptyset(&empty_set) == -1 ||
            sigprocmask(SIG_SETMASK, &empty_set, NULL) == -1) {
            child_fail(error_pipe[1], ALOFT_LAUNCH_SIGNAL_MASK);
        }
        if (setsid() == -1) {
            child_fail(error_pipe[1], ALOFT_LAUNCH_SETSID);
        }
        if (ioctl(slave_fd, TIOCSCTTY, 0) == -1) {
            child_fail(error_pipe[1], ALOFT_LAUNCH_CONTROLLING_TTY);
        }
        if (dup2(slave_fd, STDIN_FILENO) == -1 ||
            dup2(slave_fd, STDOUT_FILENO) == -1 ||
            dup2(slave_fd, STDERR_FILENO) == -1) {
            child_fail(error_pipe[1], ALOFT_LAUNCH_DUP_STDIO);
        }
        close(master_fd);
        close(slave_fd);
        if (chdir(cwd) == -1) {
            child_fail(error_pipe[1], ALOFT_LAUNCH_CHDIR);
        }
        execl("/bin/zsh", "zsh", "-l", "-c", command, (char *)NULL);
        child_fail(error_pipe[1], ALOFT_LAUNCH_EXEC);
    }

    close(slave_fd);
    close(error_pipe[1]);

    aloft_child_error child_error;
    size_t bytes_read = 0;
    while (bytes_read < sizeof(child_error)) {
        ssize_t count = read(
            error_pipe[0],
            (char *)&child_error + bytes_read,
            sizeof(child_error) - bytes_read
        );
        if (count > 0) {
            bytes_read += (size_t)count;
            continue;
        }
        if (count == 0) {
            break;
        }
        if (errno == EINTR) {
            continue;
        }

        int error_code = errno;
        close(error_pipe[0]);
        close(master_fd);
        terminate_and_reap_child(pid);
        return failure(ALOFT_LAUNCH_ERROR_PIPE, error_code);
    }
    close(error_pipe[0]);

    if (bytes_read != 0) {
        close(master_fd);
        reap_child(pid);
        if (bytes_read != sizeof(child_error)) {
            return failure(ALOFT_LAUNCH_ERROR_PIPE, EIO);
        }
        return failure(child_error.phase, child_error.error_code);
    }

    int flags = fcntl(master_fd, F_GETFL);
    if (flags == -1 || fcntl(master_fd, F_SETFL, flags | O_NONBLOCK) == -1) {
        int error_code = errno;
        close(master_fd);
        terminate_and_reap_child(pid);
        return failure(ALOFT_LAUNCH_OPEN_PTY, error_code);
    }

    aloft_launch_result result = {
        .pid = pid,
        .pgid = pid,
        .master_fd = master_fd,
        .phase = ALOFT_LAUNCH_NONE,
        .error_code = 0,
    };
    return result;
}

int aloft_process_group_exists(pid_t pgid) {
    if (killpg(pgid, 0) == 0 || errno == EPERM) {
        return 1;
    }
    if (errno == ESRCH) {
        return 0;
    }
    return -errno;
}

int aloft_signal_process_group(pid_t pgid, int signal_number) {
    if (killpg(pgid, signal_number) == 0) {
        return 0;
    }
    return -errno;
}

pid_t aloft_waitpid(pid_t pid, int *status, int options) {
    return waitpid(pid, status, options);
}
