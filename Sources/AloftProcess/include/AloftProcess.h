#ifndef ALOFT_PROCESS_H
#define ALOFT_PROCESS_H

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

typedef enum {
    ALOFT_LAUNCH_NONE = 0,
    ALOFT_LAUNCH_OPEN_PTY,
    ALOFT_LAUNCH_ERROR_PIPE,
    ALOFT_LAUNCH_FORK,
    ALOFT_LAUNCH_SIGNAL_MASK,
    ALOFT_LAUNCH_SETSID,
    ALOFT_LAUNCH_CONTROLLING_TTY,
    ALOFT_LAUNCH_DUP_STDIO,
    ALOFT_LAUNCH_CHDIR,
    ALOFT_LAUNCH_EXEC
} aloft_launch_phase;

typedef struct {
    pid_t pid;
    pid_t pgid;
    int master_fd;
    aloft_launch_phase phase;
    int error_code;
} aloft_launch_result;

aloft_launch_result aloft_launch(
    const char *command,
    const char *cwd,
    const char *shell
);
int aloft_process_group_exists(pid_t pgid);
int aloft_signal_process_group(pid_t pgid, int signal_number);
int aloft_set_window_size(
    int fd,
    uint16_t rows,
    uint16_t columns,
    uint16_t pixel_width,
    uint16_t pixel_height
);
pid_t aloft_waitpid(pid_t pid, int *status, int options);

#endif
