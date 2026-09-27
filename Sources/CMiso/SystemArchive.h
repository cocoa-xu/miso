#ifndef MISO_SYSTEM_ARCHIVE_H
#define MISO_SYSTEM_ARCHIVE_H

#include <stdint.h>
#include <sys/types.h>

// macOS exposes this system-library ABI without SDK headers.
struct archive;
struct archive_entry;
enum { ARCHIVE_OK = 0, ARCHIVE_EOF = 1 };
int archive_version_number(void);
struct archive *archive_read_new(void);
int archive_read_free(struct archive *);
int archive_read_close(struct archive *);
int archive_read_support_filter_gzip(struct archive *);
int archive_read_support_filter_none(struct archive *);
int archive_read_support_format_tar(struct archive *);
int archive_read_open_fd(struct archive *, int, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_data_skip(struct archive *);
const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
mode_t archive_entry_perm(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);

#endif
