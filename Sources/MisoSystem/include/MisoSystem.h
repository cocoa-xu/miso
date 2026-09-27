#ifndef MISO_SYSTEM_H
#define MISO_SYSTEM_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

int miso_security_probe(void);

int miso_guest_policy(const char *root, const char *username, const char *capability,
                      char *buffer, size_t capacity);
_Noreturn void miso_guest_exec(const char *root, uint32_t uid, uint32_t gid,
                              const char *username, const char *capability,
                              char *const arguments[]);

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
                     char *const environment[], const char *directory,
                     int input, int output, int error,
                     double timeout_seconds, double grace_seconds,
                     const miso_cancellation *cancellation, miso_process_result *result);

#endif
