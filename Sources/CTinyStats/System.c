#include "CTinyStats.h"
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <sys/mount.h>
#include <sys/resource.h>
#include <libproc.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <netdb.h>
#include <IOKit/IOKitLib.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// rusage_info CPU counters are Mach absolute-time ticks on Darwin, not nanoseconds.
// Widen before multiplying so long-lived processes cannot wrap during conversion.
uint64_t ts_ticks_to_nanoseconds(uint64_t ticks, uint32_t numer, uint32_t denom) {
    if (!numer || !denom) return 0;
    __uint128_t value = (__uint128_t)ticks * numer / denom;
    return value > UINT64_MAX ? UINT64_MAX : (uint64_t)value;
}

bool ts_read_cpu(ts_cpu *out) {
    memset(out, 0, sizeof(*out));
    natural_t count = 0; processor_info_array_t info = NULL; mach_msg_type_number_t size = 0;
    host_t host = mach_host_self();
    kern_return_t result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &size);
    mach_port_deallocate(mach_task_self(), host);
    if (result != KERN_SUCCESS) return false;
    out->count = count < TS_MAX_CORES ? count : TS_MAX_CORES;
    for (uint32_t i = 0; i < out->count; i++) {
        out->cores[i] = (ts_ticks){(uint32_t)info[i*CPU_STATE_MAX+CPU_STATE_USER],
            (uint32_t)info[i*CPU_STATE_MAX+CPU_STATE_SYSTEM], (uint32_t)info[i*CPU_STATE_MAX+CPU_STATE_IDLE],
            (uint32_t)info[i*CPU_STATE_MAX+CPU_STATE_NICE]};
    }
    vm_deallocate(mach_task_self(), (vm_address_t)info, size * sizeof(integer_t));
    getloadavg(out->load, 3);
    return true;
}

bool ts_read_memory(ts_memory *out) {
    memset(out, 0, sizeof(*out)); size_t size = sizeof(out->total);
    if (sysctlbyname("hw.memsize", &out->total, &size, NULL, 0) != 0) return false;
    vm_statistics64_data_t stats = {0}; mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    vm_size_t page = 0; host_t host = mach_host_self();
    kern_return_t result = host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&stats, &count);
    host_page_size(host, &page); mach_port_deallocate(mach_task_self(), host);
    if (result != KERN_SUCCESS) return false;
    out->active = (uint64_t)stats.active_count * page;
    out->inactive = (uint64_t)stats.inactive_count * page;
    out->wired = (uint64_t)stats.wire_count * page;
    out->compressed = (uint64_t)stats.compressor_page_count * page;
    out->free = (uint64_t)stats.free_count * page;
    out->speculative = (uint64_t)stats.speculative_count * page;
    out->purgeable = (uint64_t)stats.purgeable_count * page;
    struct xsw_usage swap = {0}; size = sizeof(swap);
    if (sysctlbyname("vm.swapusage", &swap, &size, NULL, 0) == 0) {
        out->swap_used = swap.xsu_used; out->swap_total = swap.xsu_total;
    }
    size = sizeof(out->pressure);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &out->pressure, &size, NULL, 0) != 0) out->pressure = 0;
    return true;
}

size_t ts_read_interfaces(ts_interface *out, size_t capacity) {
    size_t count = 0, length = 0;
    int mib[] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0};
    if (sysctl(mib, 6, NULL, &length, NULL, 0) != 0 || length > 16 * 1024 * 1024) return 0;
    char *buffer = malloc(length);
    if (!buffer || sysctl(mib, 6, buffer, &length, NULL, 0) != 0) { free(buffer); return 0; }
    for (char *cursor = buffer; cursor + sizeof(struct if_msghdr) <= buffer + length;) {
        struct if_msghdr *header = (struct if_msghdr *)cursor;
        if (!header->ifm_msglen || cursor + header->ifm_msglen > buffer + length) break;
        if (header->ifm_type == RTM_IFINFO2 && header->ifm_msglen >= sizeof(struct if_msghdr2) && count < capacity) {
            struct if_msghdr2 *info = (struct if_msghdr2 *)cursor;
            if (!(info->ifm_flags & IFF_LOOPBACK)) {
                ts_interface *row = &out[count]; memset(row, 0, sizeof(*row));
                if (if_indextoname(info->ifm_index, row->name)) {
                    count++; row->index = info->ifm_index; row->received = info->ifm_data.ifi_ibytes;
                    row->sent = info->ifm_data.ifi_obytes; row->up = (info->ifm_flags & IFF_UP) != 0;
                    row->running = (info->ifm_flags & IFF_RUNNING) != 0;
                    row->mtu = info->ifm_data.ifi_mtu;
                }
            }
        }
        cursor += header->ifm_msglen;
    }
    free(buffer);
    return count;
}

static bool number(CFDictionaryRef dict, CFStringRef key, uint64_t *out) {
    CFTypeRef value = CFDictionaryGetValue(dict, key); int64_t result = 0;
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID() || !CFNumberGetValue(value, kCFNumberSInt64Type, &result) || result < 0) return false;
    *out = (uint64_t)result; return true;
}
size_t ts_read_disks(ts_disk_io *out, size_t capacity) {
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) != KERN_SUCCESS) return 0;
    size_t count = 0; io_object_t object;
    while ((object = IOIteratorNext(iter))) {
        io_registry_entry_t device = 0;
        if (IORegistryEntryGetParentEntry(object, kIOServicePlane, &device) == KERN_SUCCESS) {
            CFTypeRef protocol = IORegistryEntryCreateCFProperty(device, CFSTR("Protocol Characteristics"), kCFAllocatorDefault, 0);
            bool virtual_disk = protocol && CFGetTypeID(protocol) == CFDictionaryGetTypeID()
                && CFEqual(CFDictionaryGetValue((CFDictionaryRef)protocol, CFSTR("Physical Interconnect")) ?: CFSTR(""), CFSTR("Virtual Interface"));
            if (protocol) CFRelease(protocol);
            IOObjectRelease(device);
            if (virtual_disk) { IOObjectRelease(object); continue; }
        }
        CFTypeRef stats = IORegistryEntryCreateCFProperty(object, CFSTR("Statistics"), kCFAllocatorDefault, 0);
        uint64_t bytes_read = 0, bytes_written = 0;
        if (stats && CFGetTypeID(stats) == CFDictionaryGetTypeID() && count < capacity
            && number((CFDictionaryRef)stats, CFSTR("Bytes (Read)"), &bytes_read)
            && number((CFDictionaryRef)stats, CFSTR("Bytes (Write)"), &bytes_written)) {
            ts_disk_io *row = &out[count++]; memset(row, 0, sizeof(*row));
            IORegistryEntryGetRegistryEntryID(object, &row->id);
            io_name_t name = {0}; IORegistryEntryGetName(object, name); strlcpy(row->name, name, sizeof(row->name));
            row->read = bytes_read;
            row->written = bytes_written;
        }
        if (stats) CFRelease(stats); IOObjectRelease(object);
    }
    IOObjectRelease(iter); return count;
}
size_t ts_read_volumes(ts_volume *out, size_t capacity) {
    struct statfs *mounts = NULL; int total = getmntinfo(&mounts, MNT_NOWAIT); size_t count = 0;
    for (int i = 0; i < total && count < capacity; i++) {
        const char *path = mounts[i].f_mntonname;
        if (!(mounts[i].f_flags & MNT_LOCAL) || mounts[i].f_blocks == 0 || (mounts[i].f_flags & MNT_DONTBROWSE)) continue;
        if (strncmp(path, "/System/", 8) == 0 || strncmp(path, "/private/", 9) == 0 || strcmp(path, "/dev") == 0) continue;
        ts_volume *row = &out[count++]; memset(row, 0, sizeof(*row));
        strlcpy(row->path, path, sizeof(row->path));
        strlcpy(row->name, strcmp(path, "/") == 0 ? "Startup disk" : strrchr(path, '/') + 1, sizeof(row->name));
        row->mount_id = ((uint64_t)(uint32_t)mounts[i].f_fsid.val[0] << 32) | (uint32_t)mounts[i].f_fsid.val[1];
        row->total = mounts[i].f_blocks * (uint64_t)mounts[i].f_bsize;
        row->available = mounts[i].f_bavail * (uint64_t)mounts[i].f_bsize;
    }
    return count;
}
int32_t ts_process_count_hint(void) {
    int count = proc_listallpids(NULL, 0);
    return count > 0 ? count : 0;
}
bool ts_read_process_identity(int32_t pid, ts_process *out) {
    if (!out || pid <= 0) return false;
    memset(out, 0, sizeof(*out));
    struct rusage_info_v2 before = {0}, after = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&before) != 0 || !before.ri_proc_start_abstime) return false;
    proc_name(pid, out->name, sizeof(out->name));
    if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&after) != 0
        || before.ri_proc_start_abstime != after.ri_proc_start_abstime) return false;
    out->pid = pid;
    out->started = after.ri_proc_start_abstime;
    return true;
}
size_t ts_read_processes(ts_process *out, size_t capacity) {
    mach_timebase_info_data_t timebase = {0};
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || !timebase.numer || !timebase.denom) return 0;
    int process_count = proc_listallpids(NULL, 0);
    if (process_count <= 0) return 0;
    size_t slots = (size_t)process_count + 128; pid_t *pids = calloc(slots, sizeof(pid_t));
    if (!pids) return 0;
    int count = proc_listallpids(pids, (int)(slots * sizeof(pid_t))); size_t used = 0;
    for (int i = 0; i < count && (size_t)i < slots && used < capacity; i++) {
        if (pids[i] <= 0) continue;
        struct rusage_info_v2 usage = {0};
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V2, (rusage_info_t *)&usage) != 0) continue;
        ts_process *row = &out[used++]; memset(row, 0, sizeof(*row)); row->pid = pids[i];
        row->started = usage.ri_proc_start_abstime; row->cpu_ns = ts_ticks_to_nanoseconds(usage.ri_user_time + usage.ri_system_time, timebase.numer, timebase.denom);
        row->footprint = usage.ri_phys_footprint; row->read = usage.ri_diskio_bytesread; row->written = usage.ri_diskio_byteswritten;
        proc_name(row->pid, row->name, sizeof(row->name));
    }
    free(pids); return used;
}
bool ts_read_self(ts_self_usage *out) {
    mach_timebase_info_data_t timebase = {0};
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || !timebase.numer || !timebase.denom) return false;
    struct rusage_info_v2 usage = {0};
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V2, (rusage_info_t *)&usage) != 0) return false;
    *out = (ts_self_usage){usage.ri_resident_size, usage.ri_phys_footprint, ts_ticks_to_nanoseconds(usage.ri_user_time + usage.ri_system_time, timebase.numer, timebase.denom)};
    return true;
}
