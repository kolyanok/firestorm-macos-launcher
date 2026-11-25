// Runtime patch for the Firestorm macOS client 12.0.7.68974 (arm64).
//
// The Windows client's certificate-validation wrapper at RVA 0x2641250 is
// patched at its entry with "xor eax,eax; ret".  The arm64 counterpart in the
// Mac client is the wrapper at unslid VA 0x1023BF420.  Its on-disk __text is
// protected, so the patch is applied in memory after the loader decrypts it.
//
// Written patch:
//   mov w0, #0        ; 0x52800000
//   ret               ; 0xd65f03c0
//
// The patch is intentionally limited to the identified wrapper.  It does not
// touch the game's other SSL implementations.

#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>

#define TARGET_VA        0x1023BF420ULL
#define ORIGINAL_WORD0   0xd10143ffU  /* sub sp, sp, #0x50          */
#define ORIGINAL_WORD1   0xa90257f6U  /* stp x22, x21, [sp, #0x20]  */
#define PATCH_WORD0      0x52800000U  /* mov w0, #0                 */
#define PATCH_WORD1      0xd65f03c0U  /* ret                        */

static void log_event(const char *event, long status) {
    const char *path = getenv("FIRESTORM_RET0_LOG");
    if (path == NULL || *path == '\0') path = "/tmp/FirestormRet0.log";
    char message[256];
    int length = snprintf(message, sizeof(message), "%s status=%ld\n", event, status);
    if (length <= 0 || length >= (int)sizeof(message)) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (fd >= 0) {
        (void)write(fd, message, (size_t)length);
        close(fd);
    }
}

/* Returns 1 when patched (or already patched), 0 when the bytes are not yet
 * available/decrypted, and -1 for an unexpected main image. */
static int patch_target(void) {
    const char *image = _dyld_get_image_name(0);
    if (image == NULL || strstr(image, "World of Warcraft") == NULL) {
        log_event("unexpected_main_image", 0);
        return -1;
    }

    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    uint32_t *target = (uint32_t *)(TARGET_VA + (uint64_t)slide);

    uint32_t word0, word1;
    memcpy(&word0, target, sizeof(word0));
    memcpy(&word1, target + 1, sizeof(word1));

    if (word0 == PATCH_WORD0 && word1 == PATCH_WORD1) {
        log_event("already_patched", (long)(uintptr_t)target);
        return 1;
    }
    if (word0 != ORIGINAL_WORD0 || word1 != ORIGINAL_WORD1) {
        return 0;
    }

    mach_vm_address_t start =
        (mach_vm_address_t)target & ~((mach_vm_address_t)vm_page_size - 1);
    mach_vm_size_t span =
        ((mach_vm_address_t)target + 8 - start + vm_page_size - 1) &
        ~((mach_vm_size_t)vm_page_size - 1);

    /* On this macOS/arm64 kernel, requesting RWX|COPY in one call fails with
     * KERN_PROTECTION_FAILURE.  Make a private writable copy first, write the
     * two instructions, then restore RX. */
    kern_return_t kr = mach_vm_protect(mach_task_self(), start, span, false,
                                       VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        log_event("mach_vm_protect_rw_failed", (long)kr);
        return 0; /* retry: the page may still be protected/encrypted */
    }

    target[0] = PATCH_WORD0;
    target[1] = PATCH_WORD1;
    sys_icache_invalidate(target, 8);

    kr = mach_vm_protect(mach_task_self(), start, span, false,
                         VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) log_event("restore_protect_failed", (long)kr);

    log_event("patched", (long)(uintptr_t)target);
    return 1;
}

static void *patch_thread(void *argument) {
    (void)argument;
    /* Wait up to 120 seconds for the protected __text to become readable. */
    for (int i = 0; i < 12000; i++) {
        int result = patch_target();
        if (result != 0) break;
        usleep(10000);
    }
    return NULL;
}

__attribute__((constructor)) static void loaded(void) {
    log_event("loaded", 0);
    if (patch_target() == 0) {
        pthread_t thread;
        if (pthread_create(&thread, NULL, patch_thread, NULL) == 0) {
            pthread_detach(thread);
        } else {
            log_event("pthread_create_failed", 0);
        }
    }
}
