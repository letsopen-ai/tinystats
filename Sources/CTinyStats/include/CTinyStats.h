#ifndef CTS_H
#define CTS_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#define TS_MAX_CORES 256

typedef struct { uint32_t user, system, idle, nice; } ts_ticks;
typedef struct { uint32_t count; ts_ticks cores[TS_MAX_CORES]; double load[3]; } ts_cpu;
typedef struct {
    uint64_t total, active, inactive, wired, compressed, free, speculative, purgeable, swap_used, swap_total;
    int pressure; /* 1 normal, 2 warning, 4 critical; 0 unavailable */
} ts_memory;
typedef struct {
    char name[32]; uint32_t index, mtu; uint64_t received, sent;
    bool up, running;
} ts_interface;
typedef struct { uint64_t id, read, written; char name[64]; } ts_disk_io;
typedef struct { char name[256], path[1024]; uint64_t total, available, mount_id; } ts_volume;
typedef struct {
    int32_t pid; uint64_t started, cpu_ns, footprint, read, written; char name[256];
} ts_process;
typedef struct { uint64_t rss, footprint, cpu_ns; } ts_self_usage;
bool ts_read_cpu(ts_cpu *out);
bool ts_read_memory(ts_memory *out);
size_t ts_read_interfaces(ts_interface *out, size_t capacity);
size_t ts_read_disks(ts_disk_io *out, size_t capacity);
size_t ts_read_volumes(ts_volume *out, size_t capacity);
/* Count estimate only: the caller must retry a filled record buffer. */
int32_t ts_process_count_hint(void);
size_t ts_read_processes(ts_process *out, size_t capacity);
// Identity only: pid/start/name are populated; no process inventory is enumerated.
bool ts_read_process_identity(int32_t pid, ts_process *out);
bool ts_read_self(ts_self_usage *out);
uint64_t ts_ticks_to_nanoseconds(uint64_t ticks, uint32_t numer, uint32_t denom);

typedef struct ts_smc ts_smc;
ts_smc *ts_smc_open(void);
void ts_smc_close(ts_smc *ctx);
uint32_t ts_smc_key_count(ts_smc *ctx);
bool ts_smc_key_at(ts_smc *ctx, uint32_t index, char key[5]);
bool ts_smc_read(ts_smc *ctx, const char *key, double *value);
/* Pure decoder exposed to verify undocumented data formats independently of hardware. */
bool ts_smc_decode(uint32_t type, const uint8_t *bytes, size_t size, double *value);
typedef struct {
    uint64_t id;
    char name[128], bsd_name[32], stable_id[65]; /* SHA-256 of device-reported identity; no raw serial leaves C */
    uint8_t protocol; /* 1 NVMe, 2 ATA, 0 unsupported */
    bool capable, available, warning, temperature_valid, spare_valid;
    uint8_t critical_warning, endurance_used, available_spare, spare_threshold;
    double temperature_celsius;
    uint64_t total_read, total_written, power_cycles, power_on_hours, unsafe_shutdowns, media_errors, error_entries;
    uint32_t overflow_mask; /* bit 0 read, 1 written, 2 cycles, 3 hours, 4 shutdowns, 5 media, 6 error entries */
    int32_t error;
} ts_storage_health;
size_t ts_read_storage_health(ts_storage_health *out, size_t capacity);
bool ts_decode_nvme_health(const uint8_t *bytes, size_t size, ts_storage_health *out);

#define TS_REPORT_ROWS 32
#define TS_REPORT_STATES 64
typedef struct { char name[32]; uint64_t residency; } ts_report_state;
typedef struct {
    char name[64], unit[32];
    int32_t format;
    uint32_t count;
    int64_t energy;
    ts_report_state states[TS_REPORT_STATES];
} ts_report_row;
typedef struct ts_report ts_report;
ts_report *ts_report_open(void);
void ts_report_close(ts_report *ctx);
size_t ts_report_read(ts_report *ctx, ts_report_row *out, size_t capacity);

#define TS_NETWORK_ADDRESSES 8
typedef struct {
    char address[80], destination[80];
    int32_t family, prefix; /* family 4 or 6; prefix -1 if unavailable */
    bool flags_valid, temporary, deprecated, not_ready;
} ts_network_address;
typedef struct {
    char name[32]; uint32_t index, count; bool truncated;
    ts_network_address addresses[TS_NETWORK_ADDRESSES];
} ts_network_details;
int32_t ts_read_network_details(ts_network_details *out, size_t capacity);
int32_t ts_network_prefix(const uint8_t *bytes, size_t length);
typedef struct ts_network_watch ts_network_watch;
ts_network_watch *ts_network_open(dispatch_queue_t queue);
void ts_network_close(ts_network_watch *ctx);
bool ts_network_changed(ts_network_watch *ctx);
CFDictionaryRef ts_network_copy_state(ts_network_watch *ctx);
#endif
