#include "MisoSystem.h"
#include <copyfile.h>
#include <errno.h>

static int copy_status(int what, int stage, copyfile_state_t state,
                       const char *source, const char *destination, void *context) {
    (void)what;
    (void)state;
    (void)source;
    (void)destination;
    if (stage == COPYFILE_ERR || miso_cancellation_requested(context)) return COPYFILE_QUIT;
    return COPYFILE_CONTINUE;
}

int miso_copy_tree(const char *source, const char *destination,
                   const miso_cancellation *cancellation) {
    if (!source || !destination) return EINVAL;
    if (miso_cancellation_requested(cancellation)) return ECANCELED;
    copyfile_state_t state = copyfile_state_alloc();
    if (!state) return ENOMEM;
    uint32_t enabled = 1;
    int result = 0;
    if (copyfile_state_set(state, COPYFILE_STATE_STATUS_CB, copy_status) ||
        copyfile_state_set(state, COPYFILE_STATE_STATUS_CTX, cancellation) ||
        copyfile_state_set(state, COPYFILE_STATE_FORBID_CROSS_MOUNT, &enabled) ||
        copyfile_state_set(state, COPYFILE_STATE_PRESERVE_SUID, &enabled) ||
        copyfile_state_set(state, COPYFILE_STATE_FORBID_DST_EXISTING_SYMLINKS, &enabled) ||
        copyfile(source, destination, state, COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW)) {
        result = errno ? errno : EIO;
    }
    copyfile_state_free(state);
    return result;
}
