// Test host only. Required dependency; deny app-process networking before startup.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <dlfcn.h>
#include <errno.h>
#include <unistd.h>
#include <sys/socket.h>
#include <arpa/inet.h>

static int denied(int family, int type) {
    int fd = socket(family, type, 0);
    int rc = -1;
    int error = errno;
    if (fd >= 0) {
        if (family == AF_INET6) {
            struct sockaddr_in6 address = {
                .sin6_len = sizeof(address), .sin6_family = AF_INET6,
                .sin6_port = htons(9), .sin6_addr = IN6ADDR_LOOPBACK_INIT
            };
            rc = connect(fd, (struct sockaddr *)&address, sizeof(address));
        } else {
            struct sockaddr_in address = {
                .sin_len = sizeof(address), .sin_family = AF_INET,
                .sin_port = htons(9), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)
            };
            rc = connect(fd, (struct sockaddr *)&address, sizeof(address));
        }
        error = errno;
        close(fd);
    }
    if (rc == -1 && (error == EPERM || error == EACCES)) return 1;
    fprintf(stderr, "COMPOSER_TEST_ISOLATION_VERIFY_FAILED family=%s protocol=%s rc=%d errno=%d\n",
            family == AF_INET6 ? "IPv6" : "IPv4",
            type == SOCK_STREAM ? "TCP" : "UDP", rc, error);
    return 0;
}

static int installed = 0;
// Referenced by the iOS host: removing this translation unit is a link error.
int composer_test_isolation_status(void) { return installed; }

__attribute__((constructor)) static void guard(void) {
    typedef int (*Apply)(const char *, int, void *);
    Apply apply = (Apply)dlsym(RTLD_DEFAULT, "__sandbox_ms");
    struct { const char *builtin; const char *storage; size_t size; } args = {"no-network", NULL, 0};
    if (!apply) {
        fprintf(stderr, "COMPOSER_TEST_ISOLATION_INSTALL_FAILED reason=interface-unavailable\n");
        _exit(90);
    }
    if (apply("Sandbox", 1, &args) != 0) {
        fprintf(stderr, "COMPOSER_TEST_ISOLATION_INSTALL_FAILED reason=installation-rejected errno=%d\n", errno);
        _exit(90);
    }
    if (!denied(AF_INET, SOCK_STREAM) || !denied(AF_INET, SOCK_DGRAM)
        || !denied(AF_INET6, SOCK_STREAM) || !denied(AF_INET6, SOCK_DGRAM)) {
        _exit(91);
    }
    installed = 1;
    fprintf(stderr, "COMPOSER_TEST_ISOLATION_INSTALLED pid=%d IPv4_IPv6_TCP_UDP_DENIED\n", getpid());
}
