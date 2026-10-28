#include "CTinyStats.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

// Optional private OS interface. Resolve every required symbol before using it.
// No privileged helper, writes, subprocesses or sampling timer live in this adapter.
struct ts_report {
  void *library;
  CFTypeRef subscription;
  CFMutableDictionaryRef channels;
  CFDictionaryRef (*samples)(CFTypeRef, CFMutableDictionaryRef, CFTypeRef);
  CFStringRef (*name)(CFDictionaryRef);
  CFStringRef (*group)(CFDictionaryRef);
  CFStringRef (*subgroup)(CFDictionaryRef);
  CFStringRef (*unit)(CFDictionaryRef);
  int (*format)(CFDictionaryRef);
  int (*count)(CFDictionaryRef);
  CFStringRef (*state_name)(CFDictionaryRef, int);
  uint64_t (*residency)(CFDictionaryRef, int);
  int64_t (*integer)(CFDictionaryRef, int);
};

static void report_string(CFStringRef value, char *output, size_t capacity) {
  output[0] = 0;
  if (value && CFGetTypeID(value) == CFStringGetTypeID() &&
      !CFStringGetCString(value, output, capacity, kCFStringEncodingUTF8)) output[0] = 0;
}

static bool report_channel(struct ts_report *r, CFDictionaryRef item) {
  char group[64], subgroup[64], name[64];
  report_string(r->group(item), group, sizeof(group));
  report_string(r->subgroup(item), subgroup, sizeof(subgroup));
  report_string(r->name(item), name, sizeof(name));
  if (!strcmp(group, "CPU Stats"))
    return !strcmp(subgroup, "CPU Complex Performance States") &&
      (!strncmp(name, "ECPU", 4) || !strncmp(name, "PCPU", 4) || !strncmp(name, "MCPU", 4));
  if (!strcmp(group, "GPU Stats"))
    return !strcmp(subgroup, "GPU Performance States") && !strcmp(name, "GPUPH");
  if (!strcmp(group, "Energy Model"))
    return !strcmp(name, "CPU Energy") || !strcmp(name, "GPU Energy") ||
      !strcmp(name, "ANE Energy") || !strcmp(name, "ANE0") || !strcmp(name, "ANE") ||
      !strcmp(name, "DRAM Energy") || !strcmp(name, "DRAM0") || !strcmp(name, "DRAM");
  return false;
}

void ts_report_close(ts_report *r) {
  if (!r) return;
  if (r->subscription) CFRelease(r->subscription);
  if (r->channels) CFRelease(r->channels);
  if (r->library) dlclose(r->library);
  free(r);
}

ts_report *ts_report_open(void) {
#if !defined(__arm64__)
  return NULL;
#else
  ts_report *r = calloc(1, sizeof(*r));
  if (!r) return NULL;
  r->library = dlopen("/usr/lib/libIOReport.dylib", RTLD_LOCAL | RTLD_LAZY);
  if (!r->library) { ts_report_close(r); return NULL; }
  CFMutableDictionaryRef (*copy)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t) =
    dlsym(r->library, "IOReportCopyChannelsInGroup");
  void (*merge)(CFMutableDictionaryRef, CFDictionaryRef, CFTypeRef) =
    dlsym(r->library, "IOReportMergeChannels");
  CFTypeRef (*subscribe)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef) =
    dlsym(r->library, "IOReportCreateSubscription");
#define LOAD(field, symbol) r->field = dlsym(r->library, symbol)
  LOAD(samples, "IOReportCreateSamples");
  LOAD(name, "IOReportChannelGetChannelName");
  LOAD(group, "IOReportChannelGetGroup");
  LOAD(subgroup, "IOReportChannelGetSubGroup");
  LOAD(unit, "IOReportChannelGetUnitLabel");
  LOAD(format, "IOReportChannelGetFormat");
  LOAD(count, "IOReportStateGetCount");
  LOAD(state_name, "IOReportStateGetNameForIndex");
  LOAD(residency, "IOReportStateGetResidency");
  LOAD(integer, "IOReportSimpleGetIntegerValue");
#undef LOAD
  if (!copy || !merge || !subscribe || !r->samples || !r->name || !r->group || !r->subgroup ||
      !r->unit || !r->format || !r->count || !r->state_name || !r->residency || !r->integer) {
    ts_report_close(r); return NULL;
  }
  CFStringRef groups[] = {CFSTR("CPU Stats"), CFSTR("GPU Stats"), CFSTR("Energy Model")};
  CFStringRef subgroups[] = {CFSTR("CPU Complex Performance States"), CFSTR("GPU Performance States"), NULL};
  CFMutableDictionaryRef desired = NULL;
  for (size_t i = 0; i < 3; i++) {
    CFMutableDictionaryRef next = copy(groups[i], subgroups[i], 0, 0, 0);
    if (!next) continue;
    if (desired) { merge(desired, next, NULL); CFRelease(next); }
    else desired = next;
  }
  if (!desired) { ts_report_close(r); return NULL; }
  CFArrayRef all = CFDictionaryGetValue(desired, CFSTR("IOReportChannels"));
  CFMutableArrayRef selected = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
  if (all && CFGetTypeID(all) == CFArrayGetTypeID()) {
    CFIndex length = CFArrayGetCount(all);
    // Bound traversal and subscription size even on unfamiliar OS releases.
    for (CFIndex i = 0; i < length && i < 4096 && CFArrayGetCount(selected) < TS_REPORT_ROWS; i++) {
      CFTypeRef item = CFArrayGetValueAtIndex(all, i);
      if (item && CFGetTypeID(item) == CFDictionaryGetTypeID() && report_channel(r, item))
        CFArrayAppendValue(selected, item);
    }
  }
  CFDictionarySetValue(desired, CFSTR("IOReportChannels"), selected);
  if (CFArrayGetCount(selected)) r->subscription = subscribe(NULL, desired, &r->channels, 0, NULL);
  CFRelease(selected);
  CFRelease(desired);
  if (!r->subscription || !r->channels) { ts_report_close(r); return NULL; }
  return r;
#endif
}

size_t ts_report_read(ts_report *r, ts_report_row *output, size_t capacity) {
  if (!r || !output || !capacity) return 0;
  CFDictionaryRef sample = r->samples(r->subscription, r->channels, NULL);
  if (!sample) return 0;
  CFArrayRef channels = CFDictionaryGetValue(sample, CFSTR("IOReportChannels"));
  size_t written = 0;
  if (channels && CFGetTypeID(channels) == CFArrayGetTypeID()) {
    CFIndex length = CFArrayGetCount(channels);
    for (CFIndex i = 0; i < length && i < TS_REPORT_ROWS && written < capacity; i++) {
      CFTypeRef item = CFArrayGetValueAtIndex(channels, i);
      if (!item || CFGetTypeID(item) != CFDictionaryGetTypeID() || !report_channel(r, item)) continue;
      int format = r->format(item);
      if (format != 1 && format != 2) continue;
      ts_report_row row = {0};
      report_string(r->name(item), row.name, sizeof(row.name));
      report_string(r->unit(item), row.unit, sizeof(row.unit));
      row.format = format;
      if (format == 1) {
        row.energy = r->integer(item, 0);
      } else {
        int count = r->count(item);
        if (count <= 0 || count > TS_REPORT_STATES) continue;
        row.count = (uint32_t)count;
        for (int j = 0; j < count; j++) {
          report_string(r->state_name(item, j), row.states[j].name, sizeof(row.states[j].name));
          row.states[j].residency = r->residency(item, j);
        }
      }
      output[written++] = row;
    }
  }
  CFRelease(sample);
  return written;
}
