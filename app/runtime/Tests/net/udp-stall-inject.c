/*
 * Test only (DYLD_INSERT_LIBRARIES): sendto() to one destination behaves as
 * macOS does when it cannot queue a datagram at once (XNU sosend: send space
 * held back, e.g. by a network filter). Nothing is sent for real.
 *
 *   UDP_STALL_DEST=192.0.2.1:9   the destination (IPv4 address:port)
 *   UDP_STALL_MODE=kernel        blocking socket: wait UDP_STALL_SECS, then
 *                                "sent"; non-blocking: -1/EAGAIN at once
 *   UDP_STALL_MODE=always        wait UDP_STALL_SECS on any socket (a stall the
 *                                fix cannot avoid: for the watchdog test)
 *   UDP_STALL_SECS=15            how long a waiting call waits (bounded)
 *   UDP_STALL_LOG=path           one line per call: "wait" or "eagain"
 *
 * Other destinations go to the real sendto().
 */
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static void note(const char *what)
{
    const char *path = getenv("UDP_STALL_LOG");
    if (path) {
        int fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0644);
        if (fd >= 0) {
            (void)write(fd, what, strlen(what));
            close(fd);
        }
    }
}

static int matches(const struct sockaddr *to)
{
    const char *dest = getenv("UDP_STALL_DEST");
    char host[64];
    const char *colon;
    struct in_addr addr;
    const struct sockaddr_in *sin = (const struct sockaddr_in *)to;

    if (!dest || !to || to->sa_family != AF_INET) {
        return 0;
    }
    colon = strrchr(dest, ':');
    if (!colon || (size_t)(colon - dest) >= sizeof(host)) {
        return 0;
    }
    memcpy(host, dest, colon - dest);
    host[colon - dest] = 0;
    if (inet_pton(AF_INET, host, &addr) != 1) {
        return 0;
    }
    return sin->sin_addr.s_addr == addr.s_addr &&
           ntohs(sin->sin_port) == atoi(colon + 1);
}

static ssize_t stall_sendto(int fd, const void *buf, size_t len, int flags,
                            const struct sockaddr *to, socklen_t tolen)
{
    const char *mode = getenv("UDP_STALL_MODE");
    const char *secs = getenv("UDP_STALL_SECS");
    int nonblocking = (fcntl(fd, F_GETFL) & O_NONBLOCK) != 0;

    if (!matches(to)) {
        return sendto(fd, buf, len, flags, to, tolen);
    }
    if (mode && !strcmp(mode, "kernel") &&
        (nonblocking || (flags & MSG_DONTWAIT))) {
        note("eagain\n");
        errno = EAGAIN;
        return -1;
    }
    note("wait\n");
    sleep(secs ? (unsigned)atoi(secs) : 15);
    return (ssize_t)len;
}

__attribute__((used, section("__DATA,__interpose")))
static const struct {
    const void *replacement;
    const void *original;
} interpose[] = { { (const void *)stall_sendto, (const void *)sendto } };
