#include "CTinyStats.h"
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
#include <IOKit/storage/ata/ATASMARTLib.h>
#include <string.h>
#include <strings.h>
#include <stdio.h>
#include <ctype.h>
#include <CommonCrypto/CommonDigest.h>

_Static_assert(sizeof(NVMeSMARTData) == 512, "NVMe SMART log ABI must be 512 bytes");

/* NVMe SMART/Health Information log layout from the public NVMe specification.
 * Decode byte-wise so packed data never causes unaligned loads. */
static uint64_t little64(const uint8_t *bytes) {
    uint64_t value = 0;
    for (unsigned i = 0; i < 8; i++) value |= (uint64_t)bytes[i] << (8 * i);
    return value;
}
static uint64_t counter128(const uint8_t *bytes, uint64_t scale, uint32_t bit, uint32_t *overflow) {
    uint64_t low = little64(bytes);
    if (little64(bytes + 8) || low > UINT64_MAX / scale) {
        *overflow |= bit; return UINT64_MAX;
    }
    return low * scale;
}
bool ts_decode_nvme_health(const uint8_t *bytes, size_t size, ts_storage_health *out) {
    if (!bytes || !out || size < 512) return false;
    out->protocol = 1; out->capable = true; out->available = true; out->error = 0;
    out->critical_warning = bytes[0]; out->warning = bytes[0] != 0;
    uint16_t kelvin = bytes[1] | (uint16_t)bytes[2] << 8;
    out->temperature_valid = kelvin >= 200 && kelvin <= 500;
    out->temperature_celsius = out->temperature_valid ? (double)kelvin - 273.15 : 0;
    out->available_spare = bytes[3]; out->spare_threshold = bytes[4]; out->endurance_used = bytes[5];
    out->spare_valid = bytes[3] <= 100 && bytes[4] <= 100;
    out->overflow_mask = 0;
    out->total_read = counter128(bytes + 32, 512000, 1U << 0, &out->overflow_mask);
    out->total_written = counter128(bytes + 48, 512000, 1U << 1, &out->overflow_mask);
    out->power_cycles = counter128(bytes + 112, 1, 1U << 2, &out->overflow_mask);
    out->power_on_hours = counter128(bytes + 128, 1, 1U << 3, &out->overflow_mask);
    out->unsafe_shutdowns = counter128(bytes + 144, 1, 1U << 4, &out->overflow_mask);
    out->media_errors = counter128(bytes + 160, 1, 1U << 5, &out->overflow_mask);
    out->error_entries = counter128(bytes + 176, 1, 1U << 6, &out->overflow_mask);
    return true;
}
/* A BSD name is temporary. Hash the reported product/serial identity locally;
 * only the hash crosses into the model or preferences, never the raw serial. */
static void stable_identity(CFDictionaryRef characteristics, ts_storage_health *out) {
    CFTypeRef serial = CFDictionaryGetValue(characteristics, CFSTR("Serial Number"));
    char value[256] = {0};
    if (!serial || CFGetTypeID(serial) != CFStringGetTypeID() ||
        !CFStringGetCString(serial, value, sizeof(value), kCFStringEncodingUTF8)) return;
    bool useful = false;
    for (size_t i = 0; value[i]; i++) if (isalnum((unsigned char)value[i]) && value[i] != '0') useful = true;
    if (!useful || strlen(value) < 4 || strcasecmp(value, "unknown") == 0 || strcasecmp(value, "none") == 0) return;
    char identity[512]; unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    int length = snprintf(identity, sizeof(identity), "%s\n%s", out->name, value);
    if (length > 0 && (size_t)length < sizeof(identity)) {
        CC_SHA256(identity, (CC_LONG)length, digest);
        for (size_t i = 0; i < sizeof(digest); i++) snprintf(out->stable_id + i * 2, 3, "%02x", digest[i]);
    }
}
static bool is_true_property(io_registry_entry_t entry, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    bool result = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(value);
    if (value) CFRelease(value);
    return result;
}
static void read_nvme(io_service_t service, ts_storage_health *out) {
    IOCFPlugInInterface **plugin = NULL; IONVMeSMARTInterface **smart = NULL; SInt32 score = 0;
    out->error = IOCreatePlugInInterfaceForService(service, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    if (out->error != kIOReturnSuccess || !plugin) { if (plugin) IODestroyPlugInInterface(plugin); return; }
    out->error = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart);
    if (out->error == 0 && smart) {
        NVMeSMARTData data = {0};
        out->error = (*smart)->SMARTReadData(smart, &data);
        if (out->error == kIOReturnSuccess) ts_decode_nvme_health((const uint8_t *)&data, sizeof(data), out);
        (*smart)->Release(smart);
    }
    IODestroyPlugInInterface(plugin);
}
static void read_ata(io_service_t service, ts_storage_health *out) {
    IOCFPlugInInterface **plugin = NULL; IOATASMARTInterface **smart = NULL; SInt32 score = 0;
    out->error = IOCreatePlugInInterfaceForService(service, kIOATASMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    if (out->error != kIOReturnSuccess || !plugin) { if (plugin) IODestroyPlugInInterface(plugin); return; }
    out->error = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOATASMARTInterfaceID), (LPVOID *)&smart);
    if (out->error == 0 && smart) {
        Boolean exceeded = false;
        out->error = (*smart)->SMARTReturnStatus(smart, &exceeded);
        if (out->error == kIOReturnSuccess) { out->available = true; out->warning = exceeded; }
        /* Never enable SMART, change power state, or run a self-test here. */
        (*smart)->Release(smart);
    }
    IODestroyPlugInInterface(plugin);
}
size_t ts_read_storage_health(ts_storage_health *out, size_t capacity) {
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDevice"), &iterator) != KERN_SUCCESS) return 0;
    io_service_t device; size_t count = 0;
    while ((device = IOIteratorNext(iterator))) {
        CFTypeRef protocol = IORegistryEntryCreateCFProperty(device, CFSTR("Protocol Characteristics"), kCFAllocatorDefault, 0);
        bool virtual_device = false;
        if (protocol && CFGetTypeID(protocol) == CFDictionaryGetTypeID()) {
            CFTypeRef interconnect = CFDictionaryGetValue(protocol, CFSTR("Physical Interconnect"));
            virtual_device = interconnect && CFEqual(interconnect, CFSTR("Virtual Interface"));
        }
        if (protocol) CFRelease(protocol);
        if (count >= capacity || virtual_device) { IOObjectRelease(device); continue; }
        ts_storage_health *row = &out[count++]; memset(row, 0, sizeof(*row));
        IORegistryEntryGetRegistryEntryID(device, &row->id);
        strlcpy(row->name, "Storage device", sizeof(row->name));
        CFTypeRef characteristics = IORegistryEntryCreateCFProperty(device, CFSTR("Device Characteristics"), kCFAllocatorDefault, 0);
        if (characteristics && CFGetTypeID(characteristics) == CFDictionaryGetTypeID()) {
            CFTypeRef name = CFDictionaryGetValue(characteristics, CFSTR("Product Name"));
            if (name && CFGetTypeID(name) == CFStringGetTypeID()) CFStringGetCString(name, row->name, sizeof(row->name), kCFStringEncodingUTF8);
            stable_identity(characteristics, row);
        }
        if (characteristics) CFRelease(characteristics);
        CFTypeRef bsd = IORegistryEntrySearchCFProperty(device, kIOServicePlane, CFSTR("BSD Name"), kCFAllocatorDefault, kIORegistryIterateRecursively);
        if (bsd && CFGetTypeID(bsd) == CFStringGetTypeID()) CFStringGetCString(bsd, row->bsd_name, sizeof(row->bsd_name), kCFStringEncodingUTF8);
        if (bsd) CFRelease(bsd);
        if (is_true_property(device, CFSTR(kIOPropertyNVMeSMARTCapableKey))) {
            row->capable = true; row->protocol = 1; read_nvme(device, row);
        } else if (is_true_property(device, CFSTR(kIOPropertySMARTCapableKey))) {
            row->capable = true; row->protocol = 2; read_ata(device, row);
        }
        IOObjectRelease(device);
    }
    IOObjectRelease(iterator); return count;
}
