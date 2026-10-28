#include "CTinyStatsTraffic.h"
#include <errno.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/socket.h>
#include <sys/sys_domain.h>
#include <unistd.h>
#include <string.h>

/* Original wire declarations from public XNU protocol facts; no private framework linkage.
 * See THIRD_PARTY_NOTICES.md for the XNU sources these layouts were checked against. */
typedef struct { uint64_t context; uint32_t type; uint16_t length, flags; } traffic_header;
typedef struct { traffic_header header; uint64_t source; } traffic_query;
typedef struct {
    traffic_header header; uint64_t filter, events; uint32_t provider; int32_t pid; uint8_t uuid[16];
} traffic_subscription;
_Static_assert(sizeof(traffic_header) == 16, "traffic header ABI");
_Static_assert(sizeof(traffic_query) == 24, "traffic query ABI");
_Static_assert(sizeof(traffic_subscription) == 56, "traffic subscription ABI");

int32_t ts_traffic_open(void) {
    int fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) return -1;
    struct ctl_info info = {0};
    strlcpy(info.ctl_name, "com.apple.network.statistics", sizeof(info.ctl_name));
    if (ioctl(fd, CTLIOCGINFO, &info) < 0) goto failure;
    struct sockaddr_ctl address = {0};
    address.sc_len = sizeof(address); address.sc_family = AF_SYSTEM;
    address.ss_sysaddr = AF_SYS_CONTROL; address.sc_id = info.ctl_id;
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0) goto failure;
    /* One query fragment may contain 100 descriptors (~50 KiB). Default buffers drop
     * records even when the final success message is delivered. Inventory checks remain
     * mandatory; this bounded reserve is not evidence of complete delivery. */
    int capacity = 256 * 1024;
    if (setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &capacity, sizeof(capacity)) < 0) goto failure;
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 || fcntl(fd, F_SETFL, O_NONBLOCK) < 0) goto failure;
    return fd;
failure: {
    int saved = errno; close(fd); errno = saved; return -1;
}
}
bool ts_traffic_query(int32_t fd, uint64_t context) {
    traffic_query request = {{context, 1007, sizeof(request), 3}, UINT64_MAX};
    return send(fd, &request, sizeof(request), 0) == (ssize_t)sizeof(request);
}
static bool subscribe_provider(int32_t fd, uint32_t provider, uint64_t context) {
    traffic_subscription request = {0};
    request.header = (traffic_header){context, 1002, sizeof(request), 3};
    request.provider = provider;
    return send(fd, &request, sizeof(request), 0) == (ssize_t)sizeof(request);
}
bool ts_traffic_subscribe(int32_t fd, uint32_t provider, uint64_t context) {
    if (provider != 2 && provider != 4) { errno = EINVAL; return false; }
    return subscribe_provider(fd, provider, context);
}
bool ts_traffic_subscribe_modern(int32_t fd, uint64_t context) {
    return subscribe_provider(fd, 9, context);
}
int32_t ts_traffic_receive(int32_t fd, uint8_t *bytes, size_t capacity) {
    if (!bytes || capacity < 65536) { errno = EINVAL; return -1; }
    struct iovec vector = {bytes, capacity};
    struct msghdr message = {0}; message.msg_iov = &vector; message.msg_iovlen = 1;
    ssize_t count = recvmsg(fd, &message, MSG_DONTWAIT);
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
    if (count <= 0 || message.msg_flags & MSG_TRUNC) return -1;
    return (int32_t)count;
}

/* ABI facts from Apple XNU proc_info_private.h; see THIRD_PARTY_NOTICES.md. */
#include <libproc.h>
typedef struct {
    uint8_t uuid[16]; uint64_t unique, parent;
    int32_t version, parent_version; uint64_t reserved[2];
} traffic_process_identity;
_Static_assert(sizeof(traffic_process_identity) == 56, "process identity ABI");
_Static_assert(offsetof(traffic_process_identity, unique) == 16, "process unique ID offset");
_Static_assert(offsetof(traffic_process_identity, version) == 32, "process exec version offset");
bool ts_traffic_process_identity(int32_t pid, uint64_t *unique_id, int32_t *version) {
    if (!unique_id || !version) return false;
    *unique_id = 0; *version = 0;
    if (pid <= 0) return false;
    traffic_process_identity identity = {0};
    if (proc_pidinfo(pid, 17, 0, &identity, sizeof(identity)) != sizeof(identity)
        || identity.unique == 0) return false;
    *unique_id = identity.unique; *version = identity.version;
    return true;
}
bool ts_traffic_process_path(int32_t pid, uint64_t unique_id, char *path, size_t capacity) {
    if (!path || capacity != PROC_PIDPATHINFO_MAXSIZE) return false;
    memset(path, 0, capacity);
    uint64_t before = 0, after = 0; int32_t version_before = 0, version_after = 0;
    if (unique_id == 0 || !ts_traffic_process_identity(pid, &before, &version_before)
        || before != unique_id) return false;
    int count = proc_pidpath(pid, path, (uint32_t)capacity);
    if (count <= 0 || (size_t)count >= capacity || path[0] != '/'
        || !memchr(path, 0, capacity)
        || !ts_traffic_process_identity(pid, &after, &version_after)
        || after != unique_id || version_before != version_after) {
        memset(path, 0, capacity); return false;
    }
    return true;
}
