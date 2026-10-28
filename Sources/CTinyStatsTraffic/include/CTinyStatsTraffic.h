#ifndef C_TINY_STATS_TRAFFIC_H
#define C_TINY_STATS_TRAFFIC_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
/* Nonblocking control socket. Its serial owner closes after read-source cancellation. */
int32_t ts_traffic_open(void);
bool ts_traffic_query(int32_t fd, uint64_t context);
/* Kernel scope accepts only providers 2/4. Modern scope fixes provider 9, never subflow 10. */
bool ts_traffic_subscribe(int32_t fd, uint32_t provider, uint64_t context);
bool ts_traffic_subscribe_modern(int32_t fd, uint64_t context);
/* 0 means no datagram ready; -1 includes truncation/EOF/errors. */
int32_t ts_traffic_receive(int32_t fd, uint8_t *bytes, size_t capacity);
/* Original projection of XNU identity flavor17. Unsupported layouts fail closed.
 * Path belongs to the exact owner observed during this call, not delegated responsibility. */
bool ts_traffic_process_identity(int32_t pid, uint64_t *unique_id, int32_t *version);
bool ts_traffic_process_path(int32_t pid, uint64_t unique_id, char *path, size_t capacity);
#endif
