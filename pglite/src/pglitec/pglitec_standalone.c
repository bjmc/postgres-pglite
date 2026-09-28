/*-------------------------------------------------------------------------
 *
 * pglitec_standalone.c
 *	  PGlite support for the standalone (non-JS) build
 *
 *
 *
 * NOTES
 *    The standalone build (see build-pglite-standalone.sh) produces a wasm
 *    module that runs on any WASI runtime (e.g. Wasmtime) without the
 *    emscripten JS glue. This file provides what the JS glue provides in the
 *    regular build: returning control to the host, host I/O, filesystem
 *    population, and stubs for libc functions emscripten implements in JS.
 *
 *    See README-PGLITE-DEV.md for the host interface.
 *
 *-------------------------------------------------------------------------
 */

#if defined(PGLITE_STANDALONE)

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <setjmp.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#include <emscripten/emscripten.h>

/* ========== Returning control to the host ==========
*
* Some code paths (top level longjmp, Terminate message) need to abandon the
* current C stack and hand control back to the host, keeping the instance alive.
* In the regular build, the JS runtime does this by throwing an "unwind"
* exception (see pgl_unwind_to_host in pglitec.c). Here, every host entry point
* sets a jump buffer and we siglongjmp back to it. This relies on native wasm
* exception handling (-sSUPPORT_LONGJMP=wasm).
*/
static sigjmp_buf pgl_host_return;

void pgl_unwind_to_host(void) {
    siglongjmp(pgl_host_return, 1);
}

#define PGL_HOST_ENTRY() \
    if (sigsetjmp(pgl_host_return, 0) != 0) \
        return 1

extern int main(int argc, char *argv[]);
extern void PostgresMainLoopOnce(void);
extern void PostgresMainLongJmp(void);

/*
* Host entry points, wrapping the functions the JS frontend calls directly.
* Each returns 0 if the call completed normally and 1 if it unwound to the
* host; in the latter case the host inspects the exit status (via
* pgl_setPGliteExitStatus), exactly like the JS frontend does after catching
* the emscripten unwind exception.
*/
int EMSCRIPTEN_KEEPALIVE pgl_call_main(int argc, char *argv[]) {
    PGL_HOST_ENTRY();
    main(argc, argv);
    return 0;
}

int EMSCRIPTEN_KEEPALIVE pgl_loop_once(void) {
    PGL_HOST_ENTRY();
    PostgresMainLoopOnce();
    return 0;
}

int EMSCRIPTEN_KEEPALIVE pgl_longjmp_recover(void) {
    PGL_HOST_ENTRY();
    PostgresMainLongJmp();
    return 0;
}

/* ========== Host I/O ==========
*
* The wire protocol read/write callbacks are plain wasm imports from the
* "pglite" module instead of JS functions added to the table.
*/
#define PGL_HOST_IMPORT(name) __attribute__((import_module("pglite"), import_name(#name)))

PGL_HOST_IMPORT(read) extern ssize_t pgl_host_read(void *buffer, size_t max_length);
PGL_HOST_IMPORT(write) extern ssize_t pgl_host_write(void *buffer, size_t length);

typedef ssize_t (*pgl_read_t)(void *buffer, size_t max_length);
typedef ssize_t (*pgl_write_t)(void *buffer, size_t length);
extern void pgl_set_rw_cbs(pgl_read_t read_cb, pgl_write_t write_cb);

__attribute__((constructor))
static void pgl_standalone_init(void) {
    pgl_set_rw_cbs(pgl_host_read, pgl_host_write);
}

/* ========== Filesystem population ==========
*
* The standalone build uses an in-memory filesystem (WASMFS); the host fills it
* (share/ data, PGDATA) before starting Postgres.
* Both return 0 on success and -errno on failure.
*/
int EMSCRIPTEN_KEEPALIVE pgl_fs_mkdir(const char *path, int mode) {
    if (mkdir(path, mode) == 0 || errno == EEXIST)
        return 0;
    return -errno;
}

int EMSCRIPTEN_KEEPALIVE pgl_fs_write_file(const char *path, const void *buf, size_t len, int mode) {
    int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, mode);
    if (fd < 0)
        return -errno;
    while (len > 0) {
        ssize_t n = write(fd, buf, len);
        if (n < 0) {
            int err = errno;
            close(fd);
            return -err;
        }
        buf = (const char *) buf + n;
        len -= n;
    }
    close(fd);
    return 0;
}

/* ========== libc functions emscripten implements in JS ========== */

/*
* There are no signals in the standalone build. Accept and ignore timer
* requests: timeout-based features such as statement_timeout and lock_timeout
* do not fire.
*/
int setitimer(int which, const struct itimerval *new_value, struct itimerval *old_value) {
    if (old_value)
        memset(old_value, 0, sizeof(*old_value));
    return 0;
}

/*
* There is no network, so only numeric addresses are resolved (enough for
* pg_hba.conf parsing).
*/
int getaddrinfo(const char *node, const char *service,
                const struct addrinfo *hints, struct addrinfo **res) {
    struct {
        struct addrinfo ai;
        union {
            struct sockaddr_in in4;
            struct sockaddr_in6 in6;
        } sa;
    } *r;
    int family = hints ? hints->ai_family : AF_UNSPEC;
    int port = service ? atoi(service) : 0;

    if (node == NULL)
        node = (hints && (hints->ai_flags & AI_PASSIVE)) ? "0.0.0.0" : "127.0.0.1";

    r = calloc(1, sizeof(*r));
    if (r == NULL)
        return EAI_MEMORY;

    if ((family == AF_UNSPEC || family == AF_INET) &&
        inet_pton(AF_INET, node, &r->sa.in4.sin_addr) == 1) {
        r->sa.in4.sin_family = AF_INET;
        r->sa.in4.sin_port = htons(port);
        r->ai.ai_family = AF_INET;
        r->ai.ai_addrlen = sizeof(struct sockaddr_in);
    } else if ((family == AF_UNSPEC || family == AF_INET6) &&
               inet_pton(AF_INET6, node, &r->sa.in6.sin6_addr) == 1) {
        r->sa.in6.sin6_family = AF_INET6;
        r->sa.in6.sin6_port = htons(port);
        r->ai.ai_family = AF_INET6;
        r->ai.ai_addrlen = sizeof(struct sockaddr_in6);
    } else {
        free(r);
        return EAI_NONAME;
    }
    r->ai.ai_socktype = hints ? hints->ai_socktype : 0;
    r->ai.ai_protocol = hints ? hints->ai_protocol : 0;
    r->ai.ai_addr = (struct sockaddr *) &r->sa;
    *res = &r->ai;
    return 0;
}

void freeaddrinfo(struct addrinfo *res) {
    /* getaddrinfo above returns a single allocation holding one entry */
    free(res);
}

int getnameinfo(const struct sockaddr *addr, socklen_t addrlen,
                char *host, socklen_t hostlen,
                char *serv, socklen_t servlen, int flags) {
    return EAI_FAIL;
}

#endif /* PGLITE_STANDALONE */
