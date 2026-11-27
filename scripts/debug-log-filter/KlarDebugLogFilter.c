// Leaves only Klar's own log messages in Debug runs of Klar, so Xcode's
// console shows what Klar logs and not what the system and WebKit do. Built
// only for the Debug configuration (the "Debug log filter" script phase) and
// loaded by the shared scheme (DYLD_INSERT_LIBRARIES); Release builds never
// contain or load it.
//
// A log handle made for any other subsystem is disabled as it's made, so its
// messages are skipped wherever they're sent from. Messages without a
// subsystem (WebKit's from its page processes, Core Audio's…) are dropped as
// they're sent. Runtime issues (SwiftUI's, Swift concurrency's) are kept:
// Xcode shows them from their own subsystem. print() goes to stdout, which
// this doesn't touch. dyld interposes these entry points for every library,
// the system's included, because this one is loaded at launch.

#include <os/log.h>
#include <stdint.h>
#include <string.h>

extern void _os_log_impl(void *dso, os_log_t log, os_log_type_t type, const char *format, uint8_t *buf, uint32_t size);
extern void _os_log_debug_impl(void *dso, os_log_t log, os_log_type_t type, const char *format, uint8_t *buf, uint32_t size);
extern void _os_log_error_impl(void *dso, os_log_t log, os_log_type_t type, const char *format, uint8_t *buf, uint32_t size);
extern void _os_log_fault_impl(void *dso, os_log_t log, os_log_type_t type, const char *format, uint8_t *buf, uint32_t size);
/// What Swift's os_log and Logger send through (libtrace's private header)
extern void os_log_pack_send(void *pack, os_log_t log, os_log_type_t type);

static int isKept(const char *subsystem) {
    return subsystem && (strncmp(subsystem, "com.itsnwa.browser", 18) == 0
                         || strcmp(subsystem, "com.apple.runtime-issues") == 0);
}

static os_log_t filtered_os_log_create(const char *subsystem, const char *category) {
    return isKept(subsystem) ? os_log_create(subsystem, category) : OS_LOG_DISABLED;
}

#define FILTERED(name) \
    static void filtered##name(void *dso, os_log_t log, os_log_type_t type, const char *format, uint8_t *buf, uint32_t size) { \
        if (log != OS_LOG_DEFAULT) name(dso, log, type, format, buf, size); \
    }
FILTERED(_os_log_impl)
FILTERED(_os_log_debug_impl)
FILTERED(_os_log_error_impl)
FILTERED(_os_log_fault_impl)

static void filtered_os_log_pack_send(void *pack, os_log_t log, os_log_type_t type) {
    if (log != OS_LOG_DEFAULT) os_log_pack_send(pack, log, type);
}

__attribute__((used)) static const struct { const void *replacement; const void *replacee; } interposers[]
    __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)filtered_os_log_create, (const void *)os_log_create },
    { (const void *)filtered_os_log_impl, (const void *)_os_log_impl },
    { (const void *)filtered_os_log_debug_impl, (const void *)_os_log_debug_impl },
    { (const void *)filtered_os_log_error_impl, (const void *)_os_log_error_impl },
    { (const void *)filtered_os_log_fault_impl, (const void *)_os_log_fault_impl },
    { (const void *)filtered_os_log_pack_send, (const void *)os_log_pack_send },
};
