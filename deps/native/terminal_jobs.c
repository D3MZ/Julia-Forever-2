#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <termios.h>

/* A narrow libc ABI boundary. Julia owns polling, cancellation and lifecycle. */
struct jf2_terminal_job {
    pid_t pid, owner, session, previous_group;
    int terminal, finished, restored, status, spawn_failed, stopped;
};

int jf2_terminal_restore(struct jf2_terminal_job *job);

static int jf2_terminal_stdio(posix_spawn_file_actions_t *actions, int source, int target, int mode) {
    if (!isatty(source)) return posix_spawn_file_actions_adddup2(actions, source, target);
    char path[PATH_MAX];
    int code = ttyname_r(source, path, sizeof(path));
    /* A new file description prevents libuv's O_NONBLOCK from leaking to the editor. */
    return code ? code : posix_spawn_file_actions_addopen(actions, target, path, mode, 0);
}

static int jf2_owned_spawn(struct jf2_terminal_job **out, const char *cwd,
        char *const argv[], char *const envp[], int input, int output, int errors, int foreground) {
    if (!out || !cwd || !argv || !argv[0]) return EINVAL;
    *out = NULL;
    pid_t previous = 0;
    if (foreground) {
        previous = tcgetpgrp(input);
        if (previous < 0) return errno;
        if (previous != getpgrp() || tcgetsid(input) != getsid(0)) return EPERM;
    } else if (isatty(input) || isatty(output) || isatty(errors)) return EINVAL;
    struct jf2_terminal_job *job = calloc(1, sizeof(*job));
    if (!job) return ENOMEM;
    job->terminal = foreground ? fcntl(input, F_DUPFD_CLOEXEC, 3) : -1;
    if (foreground && job->terminal < 0) { int code = errno; free(job); return code; }
    job->owner = getpid(); job->session = getsid(0); job->previous_group = previous;
    posix_spawnattr_t attrs;
    posix_spawn_file_actions_t actions;
    int attrs_ready = 0, actions_ready = 0;
    int code = posix_spawnattr_init(&attrs);
    if (!code) { attrs_ready = 1; code = posix_spawn_file_actions_init(&actions); }
    if (!code) actions_ready = 1;
    sigset_t mask, defaults;
    sigemptyset(&mask);
    if (!code) code = pthread_sigmask(SIG_SETMASK, NULL, &mask);
    sigemptyset(&defaults);
    const int signals[] = {SIGINT, SIGQUIT, SIGTERM, SIGTSTP, SIGTTIN, SIGTTOU};
    for (unsigned i = 0; i < sizeof(signals)/sizeof(signals[0]); ++i) {
        sigdelset(&mask, signals[i]); sigaddset(&defaults, signals[i]);
    }
    if (!code) code = posix_spawnattr_setsigmask(&attrs, &mask);
    if (!code) code = posix_spawnattr_setsigdefault(&attrs, &defaults);
    if (!code) code = posix_spawnattr_setpgroup(&attrs, 0);
    if (!code) code = posix_spawnattr_setflags(&attrs,
        POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
    if (!code) code = jf2_terminal_stdio(&actions, input, STDIN_FILENO, O_RDONLY);
    if (!code) code = jf2_terminal_stdio(&actions, output, STDOUT_FILENO, O_WRONLY);
    if (!code) code = jf2_terminal_stdio(&actions, errors, STDERR_FILENO, O_WRONLY);
    if (!code) code = posix_spawn_file_actions_addchdir_np(&actions, cwd);
    if (!code && foreground) code = posix_spawn_file_actions_addtcsetpgrp_np(&actions, STDIN_FILENO);
    if (!code && foreground) code = posix_spawn_file_actions_addclose(&actions, job->terminal);
    if (!code) code = posix_spawnp(&job->pid, argv[0], &actions, &attrs, argv, envp);
    if (actions_ready) posix_spawn_file_actions_destroy(&actions);
    if (attrs_ready) posix_spawnattr_destroy(&attrs);
    if (code) {
        job->pid = 0; job->spawn_failed = 1; job->finished = 1;
        int restored = jf2_terminal_restore(job);
        if (!restored) { if (job->terminal >= 0) close(job->terminal); free(job); }
        else { *out = job; code = restored; }
    } else *out = job;
    return code;
}

int jf2_terminal_spawn(struct jf2_terminal_job **out, const char *cwd,
        char *const argv[], char *const envp[], int input, int output, int errors) {
    return jf2_owned_spawn(out, cwd, argv, envp, input, output, errors, 1);
}

int jf2_pipe_spawn(struct jf2_terminal_job **out, const char *cwd,
        char *const argv[], char *const envp[], int input, int output, int errors) {
    return jf2_owned_spawn(out, cwd, argv, envp, input, output, errors, 0);
}

int jf2_terminal_poll(struct jf2_terminal_job *job, int *finished, int *exit_code, int *signal) {
    if (!job || job->owner != getpid() || !finished || !exit_code || !signal) return EINVAL;
    if (!job->finished) {
        siginfo_t info = {0};
        int code;
        /* Keep the dead leader unreaped until release, preventing group-ID reuse during pipe drain. */
        do { code = waitid(P_PID, (id_t)job->pid, &info, WEXITED | WNOHANG | WNOWAIT); } while (code < 0 && errno == EINTR);
        if (code < 0) return errno;
        if (info.si_pid == job->pid) {
            job->finished = 1; job->stopped = 0;
            job->status = info.si_code == CLD_EXITED ? info.si_status << 8 : info.si_status;
        } else {
            do { code = waitid(P_PID, (id_t)job->pid, &info, WSTOPPED | WCONTINUED | WNOHANG); } while (code < 0 && errno == EINTR);
            if (code < 0) return errno;
            if (info.si_pid == job->pid) job->stopped = info.si_code == CLD_STOPPED ? info.si_status : 0;
        }
    }
    *finished = job->finished;
    *exit_code = job->finished && WIFEXITED(job->status) ? WEXITSTATUS(job->status) : -1;
    *signal = job->finished && WIFSIGNALED(job->status) ? WTERMSIG(job->status) : 0;
    return 0;
}

int jf2_terminal_stopped(struct jf2_terminal_job *job, int *signal) {
    if (!job || job->owner != getpid() || !signal) return EINVAL;
    *signal = job->stopped;
    return 0;
}

int jf2_terminal_signal(struct jf2_terminal_job *job, int signal) {
    if (!job || job->owner != getpid() || (signal != SIGTERM && signal != SIGKILL && signal != SIGCONT)) return EINVAL;
    int finished, exit_code, term_signal;
    int code = jf2_terminal_poll(job, &finished, &exit_code, &term_signal);
    if (code || job->spawn_failed) return code;
    if (getpgid(job->pid) != job->pid || getsid(job->pid) != job->session) return EPERM;
    return kill(-job->pid, signal) < 0 ? errno : 0;
}

int jf2_terminal_restore(struct jf2_terminal_job *job) {
    if (!job || job->owner != getpid()) return EINVAL;
    if (job->restored) return 0;
    if (!job->finished) return EBUSY;
    if (job->terminal < 0) { job->restored = 1; return 0; }
    pid_t foreground = tcgetpgrp(job->terminal);
    if (foreground < 0) return errno;
    if (foreground != job->pid && foreground != job->previous_group) {
        if (!job->spawn_failed || kill(-foreground, 0) == 0 || errno != ESRCH) return ESTALE;
    }
    sigset_t blocked, previous;
    sigemptyset(&blocked); sigaddset(&blocked, SIGTTOU);
    int code = pthread_sigmask(SIG_BLOCK, &blocked, &previous);
    if (code) return code;
    int changed;
    do { changed = tcsetpgrp(job->terminal, job->previous_group); } while (changed < 0 && errno == EINTR);
    int error = changed < 0 ? errno : 0;
    int restored = pthread_sigmask(SIG_SETMASK, &previous, NULL);
    if (!error && !restored) job->restored = 1;
    return error ? error : restored;
}

int jf2_terminal_release(struct jf2_terminal_job *job) {
    if (!job || job->owner != getpid()) return EINVAL;
    if (!job->finished || !job->restored) return EBUSY;
    int code = 0;
    if (!job->spawn_failed) {
        pid_t waited;
        do { waited = waitpid(job->pid, &job->status, 0); } while (waited < 0 && errno == EINTR);
        if (waited < 0) code = errno;
    }
    int closed = job->terminal >= 0 && close(job->terminal) < 0 ? errno : 0;
    free(job);
    return code ? code : closed;
}

unsigned int jf2_terminal_abi(void) { return 0x00010000u; }

/* A self-only job-control request, never a caller-selected process/group signal. */
int jf2_terminal_self_state(int input, int output, int *parent, int *group,
        int *session, int *foreground) {
    if (!parent || !group || !session || !foreground) return EINVAL;
    if (!isatty(input) || !isatty(output)) return ENOTTY;
    pid_t own = getpid(), owner = getppid(), current = getpgrp(), sid = getsid(0);
    if (own <= 1 || owner <= 1 || current <= 1 || sid <= 1) return EPERM;
    /* A live job-control parent must remain outside this job but in its session. */
    pid_t parent_session = getsid(owner), parent_group = getpgid(owner);
    if (parent_session <= 1 || parent_group <= 1 || parent_session != sid || parent_group == current) return ENOTSUP;
    if (tcgetsid(input) != sid || tcgetsid(output) != sid) return ENOTTY;
    pid_t input_group = tcgetpgrp(input), output_group = tcgetpgrp(output);
    if (input_group < 0 || output_group < 0) return errno;
    if (input_group != output_group) return ENOTTY;
    *parent = owner; *group = current; *session = sid;
    *foreground = input_group == current;
    return 0;
}

int jf2_terminal_self_suspend(int input, int output, int parent, int group, int session) {
    int actual_parent, actual_group, actual_session, foreground;
    int code = jf2_terminal_self_state(input, output, &actual_parent, &actual_group,
        &actual_session, &foreground);
    if (code) return code;
    if (!foreground || actual_parent != parent || actual_group != group || actual_session != session) return ESTALE;
    struct sigaction action;
    if (sigaction(SIGTSTP, NULL, &action) < 0) return errno;
    if (action.sa_handler != SIG_DFL) return ENOTSUP;
    sigset_t mask;
    code = pthread_sigmask(SIG_SETMASK, NULL, &mask);
    if (code) return code;
    if (sigismember(&mask, SIGTSTP)) return ENOTSUP;
    struct termios modes;
    if (tcgetattr(input, &modes) < 0) return errno;
    if (!(modes.c_lflag & ICANON) || !(modes.c_lflag & ISIG)) return EBUSY;
    /* raise targets this calling process only; never stop sibling pipeline jobs. */
    code = raise(SIGTSTP);
    return code == 0 ? 0 : errno ? errno : EIO;
}
