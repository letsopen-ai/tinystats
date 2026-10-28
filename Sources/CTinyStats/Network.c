#include "CTinyStats.h"
#include <SystemConfiguration/SystemConfiguration.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <netinet6/in6_var.h>
#include <netdb.h>
#include <sys/ioctl.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Store notifications only mark a flag. All discovery remains on the shared sampler.
typedef struct { atomic_uint references; atomic_bool changed; } network_signal;
struct ts_network_watch { SCDynamicStoreRef store; network_signal *signal; };
static const void *signal_retain(const void *info) {
    network_signal *signal = (network_signal *)info;
    atomic_fetch_add(&signal->references, 1);
    return info;
}
static void signal_release(const void *info) {
    network_signal *signal = (network_signal *)info;
    if (atomic_fetch_sub(&signal->references, 1) == 1) free(signal);
}
static void network_changed(SCDynamicStoreRef store, CFArrayRef keys, void *info) {
    (void)store; (void)keys;
    atomic_store(&((network_signal *)info)->changed, true);
}
static CFArrayRef network_patterns(void) {
    const void *values[] = {
        CFSTR("^State:/Network/Global/(IPv4|IPv6|DNS)$"),
        CFSTR("^State:/Network/Interface/[^/]+/(IPv4|IPv6|Link)$"),
        CFSTR("^State:/Network/Service/[^/]+/(IPv4|IPv6|DNS)$"),
        CFSTR("^Setup:/Network/Service/[^/]+(/Interface)?$")
    };
    return CFArrayCreate(NULL, values, 4, &kCFTypeArrayCallBacks);
}
ts_network_watch *ts_network_open(dispatch_queue_t queue) {
    ts_network_watch *watch = calloc(1, sizeof(*watch));
    if (!watch) return NULL;
    watch->signal = calloc(1, sizeof(*watch->signal));
    if (!watch->signal) { free(watch); return NULL; }
    atomic_init(&watch->signal->references, 1);
    atomic_init(&watch->signal->changed, true);
    SCDynamicStoreContext context = {0, watch->signal, signal_retain, signal_release, NULL};
    watch->store = SCDynamicStoreCreate(NULL, CFSTR("TinyStats network"), network_changed, &context);
    if (!watch->store) { ts_network_close(watch); return NULL; }
    if (queue) {
        CFArrayRef patterns = network_patterns();
        if (SCDynamicStoreSetNotificationKeys(watch->store, NULL, patterns))
            SCDynamicStoreSetDispatchQueue(watch->store, queue);
        CFRelease(patterns);
    }
    return watch;
}
void ts_network_close(ts_network_watch *watch) {
    if (!watch) return;
    if (watch->store) {
        SCDynamicStoreSetDispatchQueue(watch->store, NULL);
        CFRelease(watch->store);
    }
    if (watch->signal) signal_release(watch->signal);
    free(watch);
}
bool ts_network_changed(ts_network_watch *watch) {
    return watch && atomic_exchange(&watch->signal->changed, false);
}
CFDictionaryRef ts_network_copy_state(ts_network_watch *watch) {
    if (!watch || !watch->store) return NULL;
    CFArrayRef patterns = network_patterns();
    CFDictionaryRef result = SCDynamicStoreCopyMultiple(watch->store, NULL, patterns);
    CFRelease(patterns);
    return result;
}

int32_t ts_network_prefix(const uint8_t *bytes, size_t length) {
    if (!bytes || (length != 4 && length != 16)) return -1;
    int32_t prefix = 0; bool ended = false;
    for (size_t i = 0; i < length; i++) for (int bit = 7; bit >= 0; bit--) {
        bool set = (bytes[i] & (1u << bit)) != 0;
        if (ended && set) return -1;
        if (set) prefix++; else ended = true;
    }
    return prefix;
}
int32_t ts_read_network_details(ts_network_details *out, size_t capacity) {
    if (!out || !capacity) return -1;
    if (capacity > 128) capacity = 128;
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return -1;
    int fd = socket(AF_INET6, SOCK_DGRAM, 0);
    size_t count = 0;
    for (struct ifaddrs *item = list; item; item = item->ifa_next) {
        if (!item->ifa_addr || !item->ifa_name || (item->ifa_flags & IFF_LOOPBACK)) continue;
        int family = item->ifa_addr->sa_family;
        uint32_t index = if_nametoindex(item->ifa_name);
        if (!index) continue;
        size_t slot = 0;
        for (; slot < count; slot++) if (out[slot].index == index) break;
        if (slot == count) {
            if (count == capacity) continue;
            memset(&out[count], 0, sizeof(*out));
            strlcpy(out[count].name, item->ifa_name, sizeof(out[count].name));
            out[count].index = index; count++;
        }
        ts_network_details *details = &out[slot];
        if (family != AF_INET && family != AF_INET6) continue;
        if (details->count == TS_NETWORK_ADDRESSES) { details->truncated = true; continue; }
        ts_network_address address = {0};
        address.family = family == AF_INET ? 4 : 6;
        address.prefix = -1;
        if (getnameinfo(item->ifa_addr, item->ifa_addr->sa_len, address.address,
            sizeof(address.address), NULL, 0, NI_NUMERICHOST) != 0) continue;
        if (item->ifa_netmask && item->ifa_netmask->sa_family == family) {
            if (family == AF_INET) address.prefix = ts_network_prefix(
                (const uint8_t *)&((struct sockaddr_in *)item->ifa_netmask)->sin_addr, 4);
            else address.prefix = ts_network_prefix(
                (const uint8_t *)&((struct sockaddr_in6 *)item->ifa_netmask)->sin6_addr, 16);
        }
        if ((item->ifa_flags & IFF_POINTOPOINT) && item->ifa_dstaddr && item->ifa_dstaddr->sa_family == family)
            getnameinfo(item->ifa_dstaddr, item->ifa_dstaddr->sa_len, address.destination,
                sizeof(address.destination), NULL, 0, NI_NUMERICHOST);
        if (family == AF_INET6 && fd >= 0) {
            struct in6_ifreq request = {0};
            strlcpy(request.ifr_name, item->ifa_name, sizeof(request.ifr_name));
            request.ifr_ifru.ifru_addr = *(struct sockaddr_in6 *)item->ifa_addr;
            if (ioctl(fd, SIOCGIFAFLAG_IN6, &request) == 0) {
                int flags = request.ifr_ifru.ifru_flags6;
                address.flags_valid = true;
                address.temporary = (flags & IN6_IFF_TEMPORARY) != 0;
                address.deprecated = (flags & IN6_IFF_DEPRECATED) != 0;
                address.not_ready = (flags & (IN6_IFF_NOTREADY | IN6_IFF_DETACHED)) != 0;
            }
        }
        details->addresses[details->count++] = address;
    }
    if (fd >= 0) close(fd);
    freeifaddrs(list);
    return (int32_t)count;
}
