/*
 * samsung-tethering-watch — event-driven USB watcher for Android tethering.
 *
 * Watches for Android phones (known vendor IDs) via an IOKit notification
 * and runs the tethering wrapper (/usr/local/bin/samsung-tethering-daemon)
 * for each device arrival. The run loop is never blocked — the wrapper runs
 * in a worker thread — so arrivals are always delivered.
 *
 * Self-healing: if the wrapper exits with code 3 ("the link died while the
 * phone is still attached and tethering"), the wrapper is re-run a bounded
 * number of times. This covers the driver dying (e.g. keep-alive failures)
 * without the phone being unplugged.
 *
 * Zero CPU while idle (~1 MB RSS).
 *
 * Build (done by `bin/tether autostart on`):
 *   clang -O2 -o samsung-tethering-watch usb-watch.c \
 *         -framework IOKit -framework CoreFoundation
 *
 * Runs as root via launchd (RunAtLoad). Logs to stderr, which launchd
 * redirects to /var/log/samsung-tethering.log.
 */

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

/* Android phone vendors (hex idVendor). */
static const int kAndroidVids[] = {
    0x04e8, /* Samsung */
    0x18d1, /* Google / Pixel */
    0x2717, /* Xiaomi */
    0x12d1, /* Huawei / Honor */
    0x22d9, /* BBK (Oppo/OnePlus/realme) */
    0x2a70, /* BBK */
    0x2d95, /* vivo */
    0x0fce, /* Sony */
    0x1004, /* LG */
    0x22b8, /* Motorola */
    0x19d2, /* ZTE */
    0x0bb4, /* HTC */
    0x17ef, /* Lenovo */
    0x0421, /* Nokia */
    0x0b05, /* ASUS */
};
#define N_VENDORS ((int)(sizeof(kAndroidVids) / sizeof(kAndroidVids[0])))

static const char *kWrapperPath = "/usr/local/bin/samsung-tethering-daemon";
#define kRetryExit 3    /* wrapper: link died but phone still present */
#define kMaxRetries 5   /* bounded retries before waiting for a new event */

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cond = PTHREAD_COND_INITIALIZER;
static int g_wake = 0;

static void device_arrived(void *refcon, io_iterator_t iterator) {
    (void)refcon;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != 0) {
        IOObjectRelease(service);
    }
    pthread_mutex_lock(&g_lock);
    g_wake = 1;
    pthread_cond_signal(&g_cond);
    pthread_mutex_unlock(&g_lock);
}

static void *worker(void *arg) {
    (void)arg;
    int retries = 0;
    for (;;) {
        pthread_mutex_lock(&g_lock);
        while (!g_wake) pthread_cond_wait(&g_cond, &g_lock);
        g_wake = 0;
        retries = 0; /* a fresh arrival resets the retry budget */
        pthread_mutex_unlock(&g_lock);

        for (;;) {
            pid_t pid = fork();
            if (pid == 0) {
                execl(kWrapperPath, kWrapperPath, (char *)NULL);
                _exit(127);
            }
            int status = 0;
            waitpid(pid, &status, 0);
            if (WIFEXITED(status) && WEXITSTATUS(status) == kRetryExit
                && retries < kMaxRetries) {
                retries++;
                sleep(3);
                continue;
            }
            break;
        }
    }
    return NULL;
}

int main(void) {
    mach_port_t main_port;
    IONotificationPortRef notify_port;
    io_iterator_t iterator;
    CFMutableDictionaryRef matching;
    CFMutableArrayRef vids;
    pthread_t thread;
    kern_return_t kr;

    if (IOMainPort(MACH_PORT_NULL, &main_port) != KERN_SUCCESS) {
        fprintf(stderr, "samsung-tethering-watch: IOMainPort failed\n");
        return 1;
    }
    notify_port = IONotificationPortCreate(main_port);
    if (notify_port == NULL) {
        fprintf(stderr, "samsung-tethering-watch: IONotificationPortCreate failed\n");
        return 1;
    }

    matching = IOServiceMatching("IOUSBHostDevice");
    if (matching == NULL) {
        fprintf(stderr, "samsung-tethering-watch: IOServiceMatching failed\n");
        return 1;
    }
    vids = CFArrayCreateMutable(kCFAllocatorDefault, N_VENDORS, &kCFTypeArrayCallBacks);
    for (int i = 0; i < N_VENDORS; i++) {
        CFNumberRef num = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType,
                                         &kAndroidVids[i]);
        CFArrayAppendValue(vids, num);
        CFRelease(num);
    }
    CFDictionarySetValue(matching, CFSTR("idVendor"), vids);
    CFRelease(vids);

    /* IOServiceAddMatchingNotification consumes `matching`. */
    kr = IOServiceAddMatchingNotification(notify_port, kIOMatchedNotification,
                                          matching, device_arrived, NULL, &iterator);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "samsung-tethering-watch: "
                        "IOServiceAddMatchingNotification failed (%d)\n", kr);
        return 1;
    }

    if (pthread_create(&thread, NULL, worker, NULL) != 0) {
        fprintf(stderr, "samsung-tethering-watch: pthread_create failed\n");
        return 1;
    }
    pthread_detach(thread);

    /* Arm: drain devices already present, then watch for new arrivals. */
    device_arrived(NULL, iterator);

    CFRunLoopAddSource(CFRunLoopGetCurrent(),
                       IONotificationPortGetRunLoopSource(notify_port),
                       kCFRunLoopDefaultMode);
    CFRunLoopRun();
    return 0;
}
