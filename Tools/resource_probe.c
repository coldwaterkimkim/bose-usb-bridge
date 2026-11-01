/* Optional developer measurement tool; not linked or installed by the service. */
#define _DARWIN_C_SOURCE
#include <errno.h>
#include <libproc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static const char *expected_path;

static uint64_t mono_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static int read_usage(pid_t pid, struct rusage_info_v4 *out) {
    memset(out, 0, sizeof(*out));
    return proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t)out);
}

static int check_path(pid_t pid, char *path, size_t cap) {
    memset(path, 0, cap);
    int n = proc_pidpath(pid, path, (uint32_t)cap);
    return n > 0 && strcmp(path, expected_path) == 0;
}

static void print_csv_header(void) {
    puts("elapsed_s,cpu_user_delta_ms,cpu_system_delta_ms,cpu_total_pct,physical_footprint_bytes,resident_bytes,pkg_idle_wakeups_delta,interrupt_wakeups_delta,pageins_delta,disk_read_bytes_delta,disk_written_bytes_delta,logical_writes_delta,instructions_delta,cycles_delta");
}

static void print_sample(double elapsed, double wall_s,
                         const struct rusage_info_v4 *prev,
                         const struct rusage_info_v4 *cur) {
    uint64_t u = cur->ri_user_time - prev->ri_user_time;
    uint64_t s = cur->ri_system_time - prev->ri_system_time;
    double cpu_pct = wall_s > 0 ? ((double)(u + s) / 1e9) / wall_s * 100.0 : 0.0;
    printf("%.3f,%.3f,%.3f,%.2f,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu\n",
           elapsed, (double)u / 1e6, (double)s / 1e6, cpu_pct,
           (unsigned long long)cur->ri_phys_footprint,
           (unsigned long long)cur->ri_resident_size,
           (unsigned long long)(cur->ri_pkg_idle_wkups - prev->ri_pkg_idle_wkups),
           (unsigned long long)(cur->ri_interrupt_wkups - prev->ri_interrupt_wkups),
           (unsigned long long)(cur->ri_pageins - prev->ri_pageins),
           (unsigned long long)(cur->ri_diskio_bytesread - prev->ri_diskio_bytesread),
           (unsigned long long)(cur->ri_diskio_byteswritten - prev->ri_diskio_byteswritten),
           (unsigned long long)(cur->ri_logical_writes - prev->ri_logical_writes),
           (unsigned long long)(cur->ri_instructions - prev->ri_instructions),
           (unsigned long long)(cur->ri_cycles - prev->ri_cycles));
    fflush(stdout);
}

int main(int argc, char **argv) {
    if (argc != 4 || argv[3][0] != '/') {
        fprintf(stderr, "usage: %s PID SECONDS(1..3600) EXPECTED_BINARY_PATH\n", argv[0]);
        return 2;
    }
    expected_path = argv[3];
    char *end = NULL;
    long pid_long = strtol(argv[1], &end, 10);
    if (!end || *end || pid_long <= 0 || pid_long > 999999) {
        fprintf(stderr, "invalid PID\n");
        return 2;
    }
    end = NULL;
    long seconds = strtol(argv[2], &end, 10);
    if (!end || *end || seconds < 1 || seconds > 3600) {
        fprintf(stderr, "invalid seconds; use 1..3600\n");
        return 2;
    }
    pid_t pid = (pid_t)pid_long;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (!check_path(pid, path, sizeof(path))) {
        fprintf(stderr, "PID path did not match the expected BoseUSBBridge executable; no sample taken\n");
        return 3;
    }
    struct rusage_info_v4 prev, cur;
    if (read_usage(pid, &prev) != 0) {
        fprintf(stderr, "proc_pid_rusage initial read failed: %s\n", strerror(errno));
        return 4;
    }
    uint64_t process_start = prev.ri_proc_start_abstime;
    uint64_t start = mono_ns();
    uint64_t previous_time = start;
    print_csv_header();
    for (long i = 1; i <= seconds; i++) {
        struct timespec req = {.tv_sec = 1, .tv_nsec = 0};
        while (nanosleep(&req, &req) != 0 && errno == EINTR) {}
        if (!check_path(pid, path, sizeof(path))) {
            fprintf(stderr, "target process exited or changed path; sample stopped\n");
            return 5;
        }
        if (read_usage(pid, &cur) != 0) {
            fprintf(stderr, "proc_pid_rusage read failed at sample %ld: %s\n", i, strerror(errno));
            return 6;
        }
        if (cur.ri_proc_start_abstime != process_start) {
            fprintf(stderr, "process identity changed; sample stopped\n");
            return 7;
        }
        uint64_t now = mono_ns();
        double elapsed = (double)(now - start) / 1e9;
        double interval = (double)(now - previous_time) / 1e9;
        print_sample(elapsed, interval, &prev, &cur);
        prev = cur;
        previous_time = now;
    }
    return 0;
}
