// Comprehensive certificate-verification bypass for the Firestorm macOS
// client 12.0.7.68974 (arm64).
//
// The client has several TLS implementations:
//   * Blizzard "DarwinSSL" (SecureTransport + Security framework)
//   * "cross_ssl" (SecureTransport + Security framework)
//   * statically linked OpenSSL 3.5.6.3
//   * bundled curl (uses the same OpenSSL build)
//
// This dylib bypasses the client-side verification in all of them:
//   - interposes SecTrustEvaluate / SecTrustEvaluateWithError /
//     SecTrustGetTrustResult / SecTrustEvaluateAsync* so every trust
//     evaluation succeeds;
//   - keeps SecureTransport handshakes moving on errSSLServerAuthCompleted;
//   - patches the game's internal DarwinSSL wrapper to return 0 immediately
//     (the exact analogue of the Windows RVA 0x2641250 patch);
//   - patches OpenSSL's verify callback and chain-verifier wrapper to
//     return success.
//
// The on-disk __text is protected, so the internal patches are applied in
// memory after the loader decrypts the code.  The patcher verifies the
// original instruction words before writing.

#include <Security/Security.h>
#include <Security/SecureTransport.h>
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
#include <stdatomic.h>
#include <dispatch/dispatch.h>
#include <Network/Network.h>
#include <Security/SecProtocolOptions.h>

static pthread_once_t scope_once = PTHREAD_ONCE_INIT;
static int in_scope;

static void identify_process(void) {
    const char *image = _dyld_get_image_name(0);
    in_scope = image != NULL && strstr(image, "World of Warcraft") != NULL;
}

static int test_process(void) {
    pthread_once(&scope_once, identify_process);
    return in_scope;
}

static void record_event(const char *event, long status) {
    if (!test_process()) return;
    const char *path = getenv("FIRESTORM_BYPASS_LOG");
    if (path == NULL || *path == '\0') path = "/tmp/FirestormCertBypass.log";
    char message[256];
    int length = snprintf(message, sizeof(message), "%s status=%ld\n", event, status);
    if (length <= 0 || length >= (int)sizeof(message)) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (fd >= 0) {
        (void)write(fd, message, (size_t)length);
        close(fd);
    }
}

/* ------------------------------------------------------------------ */
/* Security framework interposition                                    */
/* ------------------------------------------------------------------ */

static Boolean test_evaluate(SecTrustRef trust, CFErrorRef *error) {
    if (!test_process() || !trust) return SecTrustEvaluateWithError(trust, error);
    if (error) *error = NULL;
    record_event("SecTrustEvaluateWithError_bypassed", 0);
    return true;
}

static OSStatus test_evaluate_legacy(SecTrustRef trust, SecTrustResultType *result) {
    if (!test_process() || !trust || !result) return SecTrustEvaluate(trust, result);
    *result = kSecTrustResultProceed;
    record_event("SecTrustEvaluate_bypassed", 0);
    return errSecSuccess;
}

static OSStatus test_trust_result(SecTrustRef trust, SecTrustResultType *result) {
    if (!test_process() || !trust || !result) return SecTrustGetTrustResult(trust, result);
    *result = kSecTrustResultProceed;
    record_event("SecTrustGetTrustResult_bypassed", 0);
    return errSecSuccess;
}

static OSStatus test_evaluate_async(SecTrustRef trust, dispatch_queue_t queue,
                                    SecTrustWithErrorCallback callback) {
    if (!test_process() || !trust || !queue || !callback)
        return SecTrustEvaluateAsyncWithError(trust, queue, callback);
    CFRetain(trust);
    dispatch_async(queue, ^{
        record_event("SecTrustEvaluateAsyncWithError_bypassed", 0);
        callback(trust, true, NULL);
        CFRelease(trust);
    });
    return errSecSuccess;
}

static OSStatus test_evaluate_async_legacy(SecTrustRef trust, dispatch_queue_t queue,
                                           SecTrustCallback callback) {
    if (!test_process() || !trust || !callback) return SecTrustEvaluateAsync(trust, queue, callback);
    CFRetain(trust);
    dispatch_async(queue ? queue : dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        record_event("SecTrustEvaluateAsync_bypassed", 0);
        callback(trust, kSecTrustResultProceed);
        CFRelease(trust);
    });
    return errSecSuccess;
}

static SSLContextRef test_create(CFAllocatorRef allocator, SSLProtocolSide side,
                                 SSLConnectionType type) {
    SSLContextRef context = SSLCreateContext(allocator, side, type);
    if (context && test_process() && side == kSSLClientSide) {
        OSStatus status = SSLSetSessionOption(context, kSSLSessionOptionBreakOnServerAuth, true);
        record_event("SecureTransport_automatic_verification_disabled", status);
    }
    return context;
}

static OSStatus test_option(SSLContextRef context, SSLSessionOption option, Boolean value) {
    if (test_process() && option == kSSLSessionOptionBreakOnServerAuth) value = true;
    return SSLSetSessionOption(context, option, value);
}

static OSStatus test_handshake(SSLContextRef context) {
    OSStatus status = SSLHandshake(context);
    if (!test_process()) return status;
    if (status == errSSLServerAuthCompleted) {
        record_event("SecureTransport_server_certificate_bypassed", status);
        status = SSLHandshake(context);
    }
    if (status != errSSLWouldBlock) record_event("SSLHandshake_result", status);
    return status;
}

static void modern_verifier(sec_protocol_options_t options, dispatch_queue_t queue) {
    sec_protocol_options_set_verify_block(options,
        ^(sec_protocol_metadata_t metadata, sec_trust_t trust,
          sec_protocol_verify_complete_t complete) {
            (void)metadata;
            (void)trust;
            record_event("Network_TLS_certificate_bypassed", 0);
            complete(true);
        }, queue);
}

static void test_verify_block(sec_protocol_options_t options, sec_protocol_verify_t verifier,
                              dispatch_queue_t queue) {
    if (!test_process()) {
        sec_protocol_options_set_verify_block(options, verifier, queue);
        return;
    }
    record_event("Network_TLS_verification_configured", 0);
    modern_verifier(options, queue);
}

static nw_protocol_options_t test_tls_options(void) {
    nw_protocol_options_t options = nw_tls_create_options();
    if (options && test_process()) {
        sec_protocol_options_t security = nw_tls_copy_sec_protocol_options(options);
        if (security) {
            modern_verifier(security, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0));
            record_event("Network_TLS_options_created", 0);
            os_release(security);
        }
    }
    return options;
}

/* ------------------------------------------------------------------ */
/* In-memory instruction patches                                       */
/* ------------------------------------------------------------------ */

typedef struct {
    uint64_t va;
    uint32_t original0;
    uint32_t original1;
    uint32_t patch0;
    uint32_t patch1;
    const char *name;
} patch_t;

static const patch_t patches[] = {
    /* DarwinSSL wrapper: the exact analogue of Windows RVA 0x2641250.
     * Original: sub sp, sp, #0x50 ; stp x22, x21, [sp, #0x20]
     * Patch:    mov w0, #0 ; ret
     */
    { 0x1023BF420ULL, 0xd10143ffU, 0xa90257f6U, 0x52800000U, 0xd65f03c0U,
      "DarwinSSL_wrapper" },

    /* OpenSSL ssl_verify_internal / verify callback.
     * Original: stp x24, x23, [sp, #-0x40]! ; stp x22, x21, [sp, #0x10]
     * Patch:    mov w0, #1 ; ret
     */
    { 0x1025D968CULL, 0xa9bc5ff8U, 0xa90157f6U, 0x52800020U, 0xd65f03c0U,
      "OpenSSL_verify_callback" },

    /* OpenSSL chain-verifier wrapper used by tls_post_process_server_certificate.
     * Original: mov x2, #0 ; b ssl_verify_internal
     * Patch:    mov w0, #1 ; ret
     */
    { 0x1025D998CULL, 0xd2800002U, 0x17ffff3fU, 0x52800020U, 0xd65f03c0U,
      "OpenSSL_chain_verifier" },
};

static int patch_one(const patch_t *p) {
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    uint32_t *target = (uint32_t *)(p->va + (uint64_t)slide);
    uint32_t w0, w1;
    memcpy(&w0, target, sizeof(w0));
    memcpy(&w1, target + 1, sizeof(w1));

    if (w0 == p->patch0 && w1 == p->patch1) {
        record_event(p->name, 1);
        return 1;
    }
    if (w0 != p->original0 || w1 != p->original1) {
        return 0;
    }

    mach_vm_address_t start =
        (mach_vm_address_t)target & ~((mach_vm_address_t)vm_page_size - 1);
    mach_vm_size_t span =
        ((mach_vm_address_t)target + 8 - start + vm_page_size - 1) &
        ~((mach_vm_size_t)vm_page_size - 1);

    kern_return_t kr = mach_vm_protect(mach_task_self(), start, span, false,
                                       VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        record_event("mach_vm_protect_failed", (long)kr);
        return 0;
    }

    target[0] = p->patch0;
    target[1] = p->patch1;
    sys_icache_invalidate(target, 8);

    kr = mach_vm_protect(mach_task_self(), start, span, false,
                         VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) record_event("restore_protect_failed", (long)kr);

    record_event(p->name, (long)(uintptr_t)target);
    return 1;
}

static void *patch_thread(void *argument) {
    (void)argument;
    int remaining = (int)(sizeof(patches) / sizeof(patches[0]));
    int done[16] = {0};
    for (int i = 0; i < 12000 && remaining > 0; i++) {
        for (int j = 0; j < (int)(sizeof(patches) / sizeof(patches[0])); j++) {
            if (done[j]) continue;
            if (patch_one(&patches[j]) == 1) {
                done[j] = 1;
                remaining--;
            }
        }
        if (remaining > 0) usleep(10000);
    }
    if (remaining > 0) record_event("patch_timeout", remaining);
    return NULL;
}

__attribute__((constructor)) static void loaded(void) {
    record_event("loaded", 0);
    if (!test_process()) return;
    pthread_t thread;
    if (pthread_create(&thread, NULL, patch_thread, NULL) == 0) {
        pthread_detach(thread);
    } else {
        record_event("pthread_create_failed", 0);
    }
}

/* ------------------------------------------------------------------ */
/* Interpose table                                                     */
/* ------------------------------------------------------------------ */

#define INTERPOSE(replacement, original) \
    __attribute__((used, section("__DATA,__interpose"))) \
    static const struct { const void *replacement_address; const void *original_address; } \
    interpose_##original = { (const void *)&replacement, (const void *)&original }

INTERPOSE(test_evaluate, SecTrustEvaluateWithError);
INTERPOSE(test_evaluate_legacy, SecTrustEvaluate);
INTERPOSE(test_trust_result, SecTrustGetTrustResult);
INTERPOSE(test_evaluate_async, SecTrustEvaluateAsyncWithError);
INTERPOSE(test_evaluate_async_legacy, SecTrustEvaluateAsync);
INTERPOSE(test_create, SSLCreateContext);
INTERPOSE(test_option, SSLSetSessionOption);
INTERPOSE(test_handshake, SSLHandshake);
INTERPOSE(test_verify_block, sec_protocol_options_set_verify_block);
INTERPOSE(test_tls_options, nw_tls_create_options);
