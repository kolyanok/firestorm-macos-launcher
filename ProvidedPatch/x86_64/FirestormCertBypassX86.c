// Comprehensive certificate-verification bypass for the Firestorm macOS
// client 12.0.7.68974 (x86_64 / Intel).
//
// This is the x86_64 counterpart of the arm64 patch.  It covers:
//   * Blizzard DarwinSSL (SecureTransport + Security framework)
//   * cross_ssl (SecureTransport + Security framework)
//   * statically linked OpenSSL 3.5.6.3
//   * bundled curl (uses the same OpenSSL build)
//
// The client's x86_64 slice has an anti-tamper int3 that fires when the
// binary is modified/re-signed.  A SIGTRAP handler skips that int3 so the
// game can continue; the patch is applied after the loader decrypts __text.

#define _XOPEN_SOURCE 700

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
#include <signal.h>
#include <ucontext.h>
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
    if (path == NULL || *path == '\0') path = "/tmp/FirestormCertBypassX86.log";
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
    uint8_t original[8];
    size_t original_len;
    uint8_t patch[8];
    size_t patch_len;
    const char *name;
} patch_t;

static const patch_t patches[] = {
    /* DarwinSSL wrapper (x86_64 counterpart of arm64 0x1023BF420).
     * Original: push rbp ; mov rbp,rsp ; push r14 ; push rbx
     * Patch:    xor eax,eax ; ret
     */
    { 0x1026BC3C0ULL,
      {0x55,0x48,0x89,0xe5,0x41,0x56}, 6,
      {0x31,0xc0,0xc3}, 3,
      "DarwinSSL_wrapper" },

    /* OpenSSL ssl_verify_internal / verify callback.
     * Original: push rbp ; mov rbp,rsp ; push r15 ; push r14
     * Patch:    mov eax,1 ; ret
     */
    { 0x1029A5690ULL,
      {0x55,0x48,0x89,0xe5,0x41,0x57}, 6,
      {0xb8,0x01,0x00,0x00,0x00,0xc3}, 6,
      "OpenSSL_verify_callback" },

    /* OpenSSL chain-verifier wrapper used by tls_post_process_server_certificate.
     * Original: push rbp ; mov rbp,rsp ; push r15 ; push r14
     * Patch:    mov eax,1 ; ret
     */
    { 0x1029A69C0ULL,
      {0x55,0x48,0x89,0xe5,0x41,0x57}, 6,
      {0xb8,0x01,0x00,0x00,0x00,0xc3}, 6,
      "OpenSSL_chain_verifier" },
};

static int patch_one(const patch_t *p) {
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    uint8_t *target = (uint8_t *)(p->va + (uint64_t)slide);

    if (memcmp(target, p->patch, p->patch_len) == 0) {
        record_event(p->name, 1);
        return 1;
    }
    if (memcmp(target, p->original, p->original_len) != 0) {
        return 0;
    }

    mach_vm_address_t start =
        (mach_vm_address_t)target & ~((mach_vm_address_t)vm_page_size - 1);
    mach_vm_size_t span =
        ((mach_vm_address_t)target + p->patch_len - start + vm_page_size - 1) &
        ~((mach_vm_size_t)vm_page_size - 1);

    kern_return_t kr = mach_vm_protect(mach_task_self(), start, span, false,
                                       VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        record_event("mach_vm_protect_failed", (long)kr);
        return 0;
    }

    memcpy(target, p->patch, p->patch_len);
    sys_icache_invalidate(target, p->patch_len);

    kr = mach_vm_protect(mach_task_self(), start, span, false,
                         VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) record_event("restore_protect_failed", (long)kr);

    record_event(p->name, (long)(uintptr_t)target);
    return 1;
}

static void *patch_thread(void *argument) {
    (void)argument;
    int remaining = (int)(sizeof(patches) / sizeof(patches[0]));
    int done[8] = {0};
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

/* The x86_64 slice has an anti-tamper int3 that fires when the binary is
 * modified.  The saved RIP points past the int3, so returning resumes the
 * game at the next instruction. */
static void trap_handler(int signal_number, siginfo_t *info, void *context) {
    (void)signal_number;
    (void)info;
    ucontext_t *uc = (ucontext_t *)context;
    uint64_t rip = uc->uc_mcontext->__ss.__rip;
    const unsigned char *p = (const unsigned char *)rip;
    if (p[-1] == 0xCC) {
        record_event("antitamper_int3_skipped", (long)rip);
        return;
    }
    if (p[0] == 0xCC) {
        uc->uc_mcontext->__ss.__rip = rip + 1;
        record_event("antitamper_int3_skipped", (long)rip);
        return;
    }
    if (p[0] == 0x0F && p[1] == 0x0B) {
        uc->uc_mcontext->__ss.__rip = rip + 2;
        record_event("antitamper_ud2_skipped", (long)rip);
        return;
    }
    record_event("unexpected_sigtrap", (long)rip);
}

__attribute__((constructor)) static void loaded(void) {
    record_event("loaded", 0);
    if (!test_process()) return;

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = trap_handler;
    action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);
    sigaction(SIGTRAP, &action, NULL);

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
