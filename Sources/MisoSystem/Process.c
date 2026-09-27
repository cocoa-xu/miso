#include "MisoSystem.h"
#include <errno.h>
#include <math.h>
#include <signal.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

struct miso_cancellation {
    atomic_bool requested;
};

miso_cancellation *miso_cancellation_create(void) {
    miso_cancellation *token = malloc(sizeof(*token));
    if (token) atomic_init(&token->requested, false);
    return token;
}

void miso_cancellation_destroy(miso_cancellation *token) { free(token); }

void miso_cancellation_request(miso_cancellation *token) {
    if (token) atomic_store_explicit(&token->requested, true, memory_order_relaxed);
}

bool miso_cancellation_requested(const miso_cancellation *token) {
    return token && atomic_load_explicit(&token->requested, memory_order_relaxed);
}

static double monotonic_seconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return -1;
    return (double)value.tv_sec + (double)value.tv_nsec / 1000000000.0;
}

static int spawn_process(const char *executable, char *const arguments[],
                         char *const environment[], const char *directory,
                         int input, int output, int error,
                         pid_t *pid) {
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int status = posix_spawn_file_actions_init(&actions);
    if (status) return status;
    status = posix_spawnattr_init(&attributes);
    if (status) {
        posix_spawn_file_actions_destroy(&actions);
        return status;
    }
    sigset_t mask, defaults;
    sigemptyset(&mask);
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGINT);
    sigaddset(&defaults, SIGTERM);
    sigaddset(&defaults, SIGPIPE);
    short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK |
                  POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT;
    if (!(status = posix_spawnattr_setflags(&attributes, flags)) &&
        !(status = posix_spawnattr_setpgroup(&attributes, 0)) &&
        !(status = posix_spawnattr_setsigmask(&attributes, &mask)) &&
        !(status = posix_spawnattr_setsigdefault(&attributes, &defaults)) &&
        !(status = posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO)) &&
        !(status = posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO)) &&
        !(status = posix_spawn_file_actions_adddup2(&actions, error, STDERR_FILENO))) {
        if (directory) status = posix_spawn_file_actions_addchdir_np(&actions, directory);
        if (!status) status = posix_spawn(pid, executable, &actions, &attributes, arguments, environment);
    }
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    return status;
}

int miso_process_run(const char *executable, char *const arguments[],
                     char *const environment[], const char *directory,
                     int input, int output, int error,
                     double timeout_seconds, double grace_seconds,
                     const miso_cancellation *cancellation, miso_process_result *result) {
    if (!executable || !arguments || !arguments[0] || !environment || !result ||
        (directory && directory[0] != '/') || input < 0 || output < 0 || error < 0 || !isfinite(timeout_seconds) ||
        !isfinite(grace_seconds) || timeout_seconds <= 0 || grace_seconds < 0) return EINVAL;
    memset(result, 0, sizeof(*result));
    result->exit_code = -1;
    if (miso_cancellation_requested(cancellation)) {
        result->cancelled = true;
        return 0;
    }
    double started = monotonic_seconds();
    if (started < 0) return errno;
    pid_t pid;
    int status = spawn_process(executable, arguments, environment, directory, input, output, error, &pid);
    if (status) return status;

    bool terminating = false;
    double terminate_at = 0;
    int failure = 0;
    for (;;) {
        siginfo_t information = {0};
        if (waitid(P_PID, (id_t)pid, &information, WEXITED | WNOHANG | WNOWAIT) == -1) {
            if (errno == EINTR) continue;
            failure = errno;
            break;
        }
        if (information.si_pid == pid) break;
        double now = monotonic_seconds();
        if (now < 0) {
            failure = errno;
            break;
        }
        if (!terminating && (miso_cancellation_requested(cancellation) || now - started >= timeout_seconds)) {
            result->cancelled = miso_cancellation_requested(cancellation);
            result->timed_out = !result->cancelled;
            terminating = true;
            terminate_at = now + grace_seconds;
            kill(-pid, SIGTERM);
        }
        if (terminating && now >= terminate_at) kill(-pid, SIGKILL);
        struct timespec pause = {.tv_sec = 0, .tv_nsec = 20000000};
        nanosleep(&pause, NULL);
    }
    kill(-pid, SIGKILL);
    int wait_status;
    while (waitpid(pid, &wait_status, 0) == -1) {
        if (errno == EINTR) continue;
        return failure ? failure : errno;
    }
    if (WIFEXITED(wait_status)) result->exit_code = WEXITSTATUS(wait_status);
    if (WIFSIGNALED(wait_status)) result->signal = WTERMSIG(wait_status);
    result->elapsed_seconds = monotonic_seconds() - started;
    return failure;
}
