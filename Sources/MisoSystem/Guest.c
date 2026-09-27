#include "MisoSystem.h"
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <mach/mach.h>
#include <sandbox.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
    char *data;
    size_t capacity;
    size_t used;
    int error;
} policy_buffer;

static void append(policy_buffer *buffer, const char *format, ...) {
    if (buffer->error) return;
    va_list arguments;
    va_start(arguments, format);
    int count = vsnprintf(buffer->data + buffer->used, buffer->capacity - buffer->used,
                          format, arguments);
    va_end(arguments);
    if (count < 0 || (size_t)count >= buffer->capacity - buffer->used) {
        buffer->error = EOVERFLOW;
        return;
    }
    buffer->used += (size_t)count;
}

static bool valid_root(const char *root) {
    if (!root || root[0] != '/' || strlen(root) < 2 || strlen(root) >= PATH_MAX ||
        root[strlen(root) - 1] == '/') return false;
    const char *part = root + 1;
    for (const char *cursor = part;; cursor++) {
        unsigned char c = (unsigned char)*cursor;
        if (c == '"' || c == '\\' || (c && (c < 32 || c == 127))) return false;
        if (c && c != '/') continue;
        size_t length = (size_t)(cursor - part);
        if (!length || (length == 1 && part[0] == '.') ||
            (length == 2 && part[0] == '.' && part[1] == '.')) return false;
        if (!c) return true;
        part = cursor + 1;
    }
}

static bool valid_user(const char *username) {
    if (!username || username[0] < 'a' || username[0] > 'z' || strlen(username) > 31)
        return false;
    return strspn(username, "abcdefghijklmnopqrstuvwxyz0123456789_-") == strlen(username);
}

static void aliases(policy_buffer *buffer, const char *root, const char *kind,
                     const char *path) {
    append(buffer, "(%s \"%s\")(%s \"/System/Volumes/Data%s\")"
                   "(%s \"%s%s\")(%s \"%s/System/Volumes/Data%s\")",
           kind, path, kind, path, kind, root, path, kind, root, path);
}

int miso_guest_policy(const char *root, const char *username, const char *capability,
                      char *buffer, size_t capacity) {
    if (!buffer || !capacity) return EINVAL;
    buffer[0] = '\0';
    if (!valid_root(root) || !valid_user(username) || !capability) return EINVAL;
    bool readonly = strcmp(capability, "read-only") == 0;
    bool ruby = strcmp(capability, "ruby") == 0;
    bool git = strcmp(capability, "git") == 0;
    bool cask = strcmp(capability, "cask") == 0;
    bool mise = strcmp(capability, "mise") == 0;
    bool android = strcmp(capability, "android") == 0;
    bool flutter = strcmp(capability, "flutter") == 0;
    bool brew = strcmp(capability, "brew") == 0 || cask;
    if (!readonly && !ruby && !git && !brew && !mise && !android && !flutter && strcmp(capability, "base")) return EINVAL;
    policy_buffer policy = {buffer, capacity, 0, 0};
    append(&policy, "(version 1)(allow default)(deny file-write*)(deny network*)"
                    "(deny mach-lookup)(deny process-info* (target others))"
                    "(deny signal (target others))"
                    "(allow file-write* (literal \"/dev/null\")(literal \"%s/dev/null\"))"
                    "(deny file-read* (subpath \"/dev\")(subpath \"%s/dev\"))", root, root);
    append(&policy, "(allow file-read*");
    const char *devices[] = {"null", "random", "urandom", "fd"};
    for (size_t i = 0; i < 4; i++) {
        const char *kind = i == 3 ? "subpath" : "literal";
        append(&policy, "(%s \"/dev/%s\")(%s \"%s/dev/%s\")", kind, devices[i], kind, root, devices[i]);
    }
    append(&policy, ")");
    if (!readonly) {
        char home[128];
        snprintf(home, sizeof(home), "/Users/%s/Library/Caches", username);
        append(&policy, "(allow file-write*");
        aliases(&policy, root, "subpath", "/opt/homebrew");
        aliases(&policy, root, "subpath", "/private/tmp");
        aliases(&policy, root, "subpath", home);
        if (cask) aliases(&policy, root, "subpath", "/Applications/Kiro CLI.app");
        if (mise) {
            const char *directories[] = {".config/mise", ".local/share/mise", ".local/state/mise"};
            for (size_t i = 0; i < 3; i++) {
                snprintf(home, sizeof(home), "/Users/%s/%s", username, directories[i]);
                aliases(&policy, root, "subpath", home);
            }
        }
        if (android) {
            const char *directories[] = {"android-sdk", ".android"};
            for (size_t i = 0; i < 2; i++) {
                snprintf(home, sizeof(home), "/Users/%s/%s", username, directories[i]);
                aliases(&policy, root, "subpath", home);
            }
        }
        if (flutter) {
            const char *directories[] = {"flutter", ".pub-cache", ".config/flutter", ".dart-tool"};
            for (size_t i = 0; i < 4; i++) {
                snprintf(home, sizeof(home), "/Users/%s/%s", username, directories[i]);
                aliases(&policy, root, "subpath", home);
            }
        }
        snprintf(home, sizeof(home), "/Users/%s/.homebrew", username);
        aliases(&policy, root, "subpath", home);
        if (ruby) {
            snprintf(home, sizeof(home), "/Users/%s/.rbenv", username);
            aliases(&policy, root, "subpath", home);
            append(&policy, "(subpath \"/dev/fd\")(subpath \"%s/dev/fd\")", root);
        }
        if (git) {
            snprintf(home, sizeof(home), "/Users/%s/.gitconfig", username);
            aliases(&policy, root, "literal", home);
            snprintf(home, sizeof(home), "/Users/%s/.gitconfig.lock", username);
            aliases(&policy, root, "literal", home);
        }
        append(&policy, ")");
    }
    if (brew) {
        append(&policy, "(allow network-bind network-outbound network-inbound");
        aliases(&policy, root, "subpath", "/private/tmp");
        append(&policy, ")");
    }
    return policy.error;
}

static _Noreturn void fail(const char *operation) {
    dprintf(STDERR_FILENO, "Guest execution: %s (%s)\n", operation, strerror(errno));
    _exit(125);
}

static void check_mount(const char *root, const char *suffix, bool readonly, const char *type) {
    char path[PATH_MAX];
    if (snprintf(path, sizeof(path), "%s%s", root, suffix) >= (int)sizeof(path)) {
        errno = ENAMETOOLONG;
        fail("mount path");
    }
    struct statfs info;
    if (statfs(path, &info)) fail("inspect mount");
    if (strcmp(info.f_mntonname, path) || (type && strcmp(info.f_fstypename, type)) ||
        !(info.f_flags & MNT_NOSUID) || ((info.f_flags & MNT_RDONLY) != 0) != readonly) {
        errno = EPERM;
        fail("mount access mismatch");
    }
}

_Noreturn void miso_guest_exec(const char *root, uint32_t uid, uint32_t gid,
                              const char *username, const char *capability,
                              char *const arguments[]) {
    char policy[65536];
    errno = miso_guest_policy(root, username, capability, policy, sizeof(policy));
    if (errno) fail("invalid policy parameters");
    if (geteuid() || getuid() || uid < 501 || uid > 60000 || gid < 20 || gid > 60000 ||
        !arguments || !arguments[0] || arguments[0][0] != '/') {
        errno = EINVAL;
        fail("invalid execution identity");
    }
    char resolved[PATH_MAX];
    struct stat info;
    if (!realpath(root, resolved) || strcmp(root, resolved) || lstat(root, &info) ||
        !S_ISDIR(info.st_mode) || info.st_uid || (info.st_mode & 0022)) {
        errno = EPERM;
        fail("unsafe execution root");
    }
    check_mount(root, "/System/Volumes/Data", false, "apfs");
    check_mount(root, "/System/Volumes/Preboot", true, "apfs");
    check_mount(root, "/System/Volumes/Preboot/Cryptexes/OS", true, NULL);
    check_mount(root, "/dev", false, "devfs");
    struct rlimit cores = {0, 0};
    if (setrlimit(RLIMIT_CORE, &cores)) fail("disable core dumps");
    if (task_set_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, MACH_PORT_NULL) != KERN_SUCCESS) {
        errno = EPERM;
        fail("clear bootstrap port");
    }
    for (int fd = 3, limit = getdtablesize(); fd < limit; fd++) close(fd);
    if (chroot(root) || chdir("/")) fail("enter execution root");
    char *error = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (sandbox_init(policy, 0, &error)) {
        dprintf(STDERR_FILENO, "Guest policy: %s\n", error ? error : "unknown error");
        sandbox_free_error(error);
        _exit(125);
    }
#pragma clang diagnostic pop
    if (setgroups(0, NULL) || setgid(gid) || setuid(uid) || getuid() != uid || geteuid() != uid ||
        getgid() != gid || getegid() != gid) fail("drop privileges");
    char home[128], user[64], login[64];
    snprintf(home, sizeof(home), "HOME=/Users/%s", username);
    snprintf(user, sizeof(user), "USER=%s", username);
    snprintf(login, sizeof(login), "LOGNAME=%s", username);
    char *environment[] = {"PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                           "LANG=C", "LC_ALL=C", "TMPDIR=/private/tmp", home, user, login, NULL};
    execve(arguments[0], arguments, environment);
    if (errno == EPERM || errno == EACCES) {
        dprintf(STDERR_FILENO, "Guest execution: execve denied (%s)\n", strerror(errno));
        _exit(126);
    }
    fail("execve");
}
