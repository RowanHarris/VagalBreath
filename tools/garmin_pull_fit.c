/*
 * garmin_pull_fit.c — Fast uncached USB MTP puller for Garmin Venu 3 .FIT activity logs.
 *
 * Uses libmtp in uncached raw-device mode to read GARMIN/Activity/ without hanging on a
 * full device scan, copying new .fit files incrementally into a local sessions/ folder.
 *
 * Build on macOS (Homebrew libmtp):
 *   clang -O2 -Wall -Wextra -I/opt/homebrew/include -L/opt/homebrew/lib \
 *         -Wl,-rpath,/opt/homebrew/lib -lmtp tools/garmin_pull_fit.c -o tools/garmin_pull_fit
 */

#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <utime.h>
#include <libmtp.h>

typedef struct {
    uint32_t item_id;
    char *filename;
    uint64_t filesize;
    time_t mtime;
} FitEntry;

static int ends_with_fit(const char *name) {
    if (name == NULL) {
        return 0;
    }
    size_t len = strlen(name);
    if (len < 4) {
        return 0;
    }
    return strcasecmp(name + len - 4, ".fit") == 0;
}

static int compare_fit_entries_desc(const void *a, const void *b) {
    const FitEntry *ea = (const FitEntry *)a;
    const FitEntry *eb = (const FitEntry *)b;
    if (ea->mtime != eb->mtime) {
        return (eb->mtime > ea->mtime) ? 1 : -1;
    }
    return strcasecmp(eb->filename, ea->filename);
}

static uint32_t find_child_folder(
    LIBMTP_mtpdevice_t *dev,
    uint32_t storage_id,
    uint32_t parent_id,
    const char *name
) {
    LIBMTP_file_t *files = LIBMTP_Get_Files_And_Folders(dev, storage_id, parent_id);
    uint32_t found = 0;
    LIBMTP_file_t *cur = files;
    while (cur != NULL) {
        LIBMTP_file_t *next = cur->next;
        if (cur->filename != NULL && strcasecmp(cur->filename, name) == 0) {
            found = cur->item_id;
        }
        LIBMTP_destroy_file_t(cur);
        cur = next;
    }
    return found;
}

static int ensure_dir(const char *path) {
    struct stat st;
    if (stat(path, &st) == 0) {
        if (S_ISDIR(st.st_mode)) {
            return 0;
        }
        fprintf(stderr, "Path exists and is not a directory: %s\n", path);
        return -1;
    }
    char tmp[1024];
    size_t len = strlen(path);
    if (len == 0 || len >= sizeof(tmp)) {
        fprintf(stderr, "Invalid directory path: %s\n", path);
        return -1;
    }
    strcpy(tmp, path);
    for (char *p = tmp + 1; *p != '\0'; p++) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(tmp, 0755) != 0 && errno != EEXIST) {
                perror(tmp);
                return -1;
            }
            *p = '/';
        }
    }
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) {
        perror(tmp);
        return -1;
    }
    return 0;
}

static void print_usage(const char *prog) {
    fprintf(stderr,
        "Usage: %s [--out <dir>] [--recent <N>] [--force] [--list]\n"
        "  --out <dir>   Destination folder for .fit files (default: sessions)\n"
        "  --recent <N>  Only inspect/pull the N newest .fit files (default: all)\n"
        "  --force       Re-download files even if they already exist locally\n"
        "  --list        List GARMIN/Activity/*.fit files without downloading\n",
        prog
    );
}

int main(int argc, char **argv) {
    const char *out_dir = "sessions";
    int recent_limit = 0;
    int force = 0;
    int list_only = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--out") == 0 && i + 1 < argc) {
            out_dir = argv[++i];
        } else if (strcmp(argv[i], "--recent") == 0 && i + 1 < argc) {
            recent_limit = atoi(argv[++i]);
            if (recent_limit < 0) {
                recent_limit = 0;
            }
        } else if (strcmp(argv[i], "--force") == 0) {
            force = 1;
        } else if (strcmp(argv[i], "--list") == 0) {
            list_only = 1;
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "Unknown argument: %s\n", argv[i]);
            print_usage(argv[0]);
            return 1;
        }
    }

    LIBMTP_Init();
    LIBMTP_raw_device_t *rawdevices = NULL;
    int numrawdevices = 0;
    LIBMTP_error_number_t err = LIBMTP_Detect_Raw_Devices(&rawdevices, &numrawdevices);
    if (err != LIBMTP_ERROR_NONE || numrawdevices <= 0 || rawdevices == NULL) {
        fprintf(stderr, "No Garmin MTP device detected (err=%d). Plug in Venu 3 via USB.\n", err);
        return 1;
    }

    LIBMTP_mtpdevice_t *dev = LIBMTP_Open_Raw_Device_Uncached(&rawdevices[0]);
    free(rawdevices);
    if (dev == NULL) {
        fprintf(stderr, "Failed to open MTP device in uncached mode.\n");
        return 1;
    }

    char *friendly = LIBMTP_Get_Friendlyname(dev);
    printf("Connected to: %s\n", friendly ? friendly : "(unknown)");
    free(friendly);

    if (LIBMTP_Get_Storage(dev, LIBMTP_STORAGE_SORTBY_NOTSORTED) != 0 || dev->storage == NULL) {
        fprintf(stderr, "Failed to read device storage.\n");
        LIBMTP_Release_Device(dev);
        return 1;
    }

    uint32_t storage_id = dev->storage->id;
    uint32_t garmin_id = find_child_folder(dev, storage_id, LIBMTP_FILES_AND_FOLDERS_ROOT, "GARMIN");
    uint32_t act_id = garmin_id ? find_child_folder(dev, storage_id, garmin_id, "Activity") : 0;
    if (act_id == 0) {
        fprintf(stderr, "Could not locate GARMIN/Activity folder on device.\n");
        LIBMTP_Release_Device(dev);
        return 1;
    }

    LIBMTP_file_t *files = LIBMTP_Get_Files_And_Folders(dev, storage_id, act_id);
    size_t count = 0;
    size_t cap = 64;
    FitEntry *entries = (FitEntry *)malloc(cap * sizeof(FitEntry));
    if (entries == NULL) {
        fprintf(stderr, "Out of memory.\n");
        LIBMTP_Release_Device(dev);
        return 1;
    }

    LIBMTP_file_t *cur = files;
    while (cur != NULL) {
        LIBMTP_file_t *next = cur->next;
        if (cur->filetype != LIBMTP_FILETYPE_FOLDER && ends_with_fit(cur->filename)) {
            if (count == cap) {
                cap *= 2;
                FitEntry *grown = (FitEntry *)realloc(entries, cap * sizeof(FitEntry));
                if (grown == NULL) {
                    fprintf(stderr, "Out of memory.\n");
                    LIBMTP_destroy_file_t(cur);
                    cur = next;
                    continue;
                }
                entries = grown;
            }
            entries[count].item_id = cur->item_id;
            entries[count].filename = strdup(cur->filename);
            entries[count].filesize = cur->filesize;
            entries[count].mtime = cur->modificationdate;
            count++;
        }
        LIBMTP_destroy_file_t(cur);
        cur = next;
    }

    qsort(entries, count, sizeof(FitEntry), compare_fit_entries_desc);
    printf("Found %zu .fit files in GARMIN/Activity.\n", count);

    size_t limit = count;
    if (recent_limit > 0 && (size_t)recent_limit < count) {
        limit = (size_t)recent_limit;
    }

    if (list_only) {
        for (size_t i = 0; i < limit; i++) {
            printf("  %s  (%llu bytes)\n",
                   entries[i].filename, (unsigned long long)entries[i].filesize);
        }
    } else {
        if (ensure_dir(out_dir) != 0) {
            for (size_t i = 0; i < count; i++) {
                free(entries[i].filename);
            }
            free(entries);
            LIBMTP_Release_Device(dev);
            return 1;
        }

        size_t downloaded = 0;
        size_t skipped = 0;
        size_t failed = 0;

        for (size_t i = 0; i < limit; i++) {
            char local_path[2048];
            int n = snprintf(local_path, sizeof(local_path), "%s/%s", out_dir, entries[i].filename);
            if (n <= 0 || (size_t)n >= sizeof(local_path)) {
                fprintf(stderr, "Path too long for %s\n", entries[i].filename);
                failed++;
                continue;
            }

            if (!force) {
                struct stat st;
                if (stat(local_path, &st) == 0 && (uint64_t)st.st_size == entries[i].filesize) {
                    skipped++;
                    continue;
                }
            }

            printf("Pulling %s (%llu bytes)...\n",
                   entries[i].filename, (unsigned long long)entries[i].filesize);
            if (LIBMTP_Get_File_To_File(dev, entries[i].item_id, local_path, NULL, NULL) != 0) {
                fprintf(stderr, "  Failed to pull %s\n", entries[i].filename);
                LIBMTP_Dump_Errorstack(dev);
                failed++;
                continue;
            }

            if (entries[i].mtime > 0) {
                struct utimbuf tb;
                tb.actime = entries[i].mtime;
                tb.modtime = entries[i].mtime;
                utime(local_path, &tb);
            }
            downloaded++;
        }

        printf("Done: %zu downloaded, %zu already synced, %zu failed -> %s/\n",
               downloaded, skipped, failed, out_dir);
    }

    for (size_t i = 0; i < count; i++) {
        free(entries[i].filename);
    }
    free(entries);
    LIBMTP_Release_Device(dev);
    return 0;
}
