#ifndef MISO_SYSTEM_H
#define MISO_SYSTEM_H

#include <stdbool.h>
#include <stdint.h>

typedef struct miso_cancellation miso_cancellation;

typedef struct {
    int exit_code;
    int signal;
    bool timed_out;
    bool cancelled;
    double elapsed_seconds;
} miso_process_result;

miso_cancellation *miso_cancellation_create(void);
void miso_cancellation_destroy(miso_cancellation *token);
void miso_cancellation_request(miso_cancellation *token);
bool miso_cancellation_requested(const miso_cancellation *token);

int miso_copy_tree(const char *source, const char *destination,
                   const miso_cancellation *cancellation);

int miso_process_run(const char *executable, char *const arguments[],
                     char *const environment[], int input, int output, int error,
                     double timeout_seconds, double grace_seconds,
                     const miso_cancellation *cancellation, miso_process_result *result);

#endif
