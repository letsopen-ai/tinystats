/* AppleSMC wire layout and commands researched against exelban/Stats (MIT).
 * See THIRD_PARTY_NOTICES.md. Read-only: no write command is implemented. */
#include "CTinyStats.h"
#include <IOKit/IOKitLib.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } smc_version;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, memory; } smc_limits;
typedef struct { uint32_t size, type; uint8_t attributes; } smc_info;
typedef struct {
    uint32_t key; smc_version version; smc_limits limits; smc_info info;
    uint8_t result, status, command; uint32_t index; uint8_t bytes[32];
} smc_message;
_Static_assert(sizeof(smc_message) == 80, "AppleSMC ABI must remain 80 bytes");
typedef struct { uint32_t key; smc_info info; } cache_entry;
struct ts_smc { io_connect_t connection; cache_entry cache[512]; size_t count; };
static uint32_t fourcc(const char *key) {
    return (uint32_t)(uint8_t)key[0]<<24 | (uint32_t)(uint8_t)key[1]<<16 | (uint32_t)(uint8_t)key[2]<<8 | (uint8_t)key[3];
}
static bool call(ts_smc *ctx, smc_message *input, smc_message *output) {
    if (!ctx || !ctx->connection) return false;
    size_t size = sizeof(*output); memset(output, 0, size);
    return IOConnectCallStructMethod(ctx->connection, 2, input, sizeof(*input), output, &size) == KERN_SUCCESS
        && size == sizeof(*output) && output->result == 0;
}
ts_smc *ts_smc_open(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return NULL;
    ts_smc *ctx = calloc(1, sizeof(*ctx));
    if (ctx && IOServiceOpen(service, mach_task_self(), 0, &ctx->connection) != KERN_SUCCESS) { free(ctx); ctx = NULL; }
    IOObjectRelease(service); return ctx;
}
void ts_smc_close(ts_smc *ctx) {
    if (ctx) { if (ctx->connection) IOServiceClose(ctx->connection); free(ctx); }
}
bool ts_smc_decode(uint32_t type, const uint8_t *bytes, size_t size, double *value) {
    if (!bytes || !value || size == 0 || size > 32) return false;
    if (type == fourcc("flt ") && size == 4) { float f = 0; memcpy(&f, bytes, 4); *value = f; }
    else if (type == fourcc("ui8 ") && size == 1) *value = bytes[0];
    else if (type == fourcc("ui16") && size == 2) *value = (bytes[0]<<8) | bytes[1];
    else if (type == fourcc("ui32") && size == 4) *value = (uint32_t)bytes[0]<<24 | (uint32_t)bytes[1]<<16 | (uint32_t)bytes[2]<<8 | bytes[3];
    else if ((type>>16 == ((uint32_t)'s'<<8 | 'p') || type>>16 == ((uint32_t)'f'<<8 | 'p')) && size == 2) {
        char digit = (char)(type & 255); int fraction = digit >= '0' && digit <= '9' ? digit-'0' : digit >= 'a' && digit <= 'f' ? digit-'a'+10 : -1;
        if (fraction < 0) return false;
        uint16_t raw = (uint16_t)(bytes[0]<<8 | bytes[1]);
        *value = (type>>24 == 's' ? (double)(int16_t)raw : (double)raw) / (double)(1U<<fraction);
    } else return false;
    return isfinite(*value);
}
bool ts_smc_read(ts_smc *ctx, const char *key, double *value) {
    if (!ctx || !key || strlen(key) != 4 || !value) return false;
    uint32_t code = fourcc(key); smc_info info = {0}; bool cached = false;
    for (size_t i=0; i<ctx->count; i++) if (ctx->cache[i].key == code) { info = ctx->cache[i].info; cached = true; break; }
    smc_message input = {0}, output = {0}; input.key = code;
    if (!cached) {
        input.command = 9;
        if (!call(ctx, &input, &output) || output.info.size == 0 || output.info.size > 32) return false;
        info = output.info;
        if (ctx->count < 512) ctx->cache[ctx->count++] = (cache_entry){code, info};
    }
    input.command = 5; input.info.size = info.size;
    if (!call(ctx, &input, &output)) return false;
    return ts_smc_decode(info.type, output.bytes, info.size, value);
}
uint32_t ts_smc_key_count(ts_smc *ctx) {
    double count = 0; return ts_smc_read(ctx, "#KEY", &count) && count > 0 && count < 32768 ? (uint32_t)count : 0;
}
bool ts_smc_key_at(ts_smc *ctx, uint32_t index, char key[5]) {
    smc_message input = {0}, output = {0}; input.command = 8; input.index = index;
    if (!call(ctx, &input, &output)) return false;
    key[0] = output.key>>24; key[1] = output.key>>16; key[2] = output.key>>8; key[3] = output.key; key[4] = 0;
    return true;
}
