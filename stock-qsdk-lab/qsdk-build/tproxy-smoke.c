/* Bounded loopback-only TPROXY smoke test, run in an isolated network namespace.
 * server listens transparently at 45001; client connects to loopback:45002.
 * No external host, credentials or production proxy configuration is used.
 */
#include <arpa/inet.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static void fail(const char *what) { perror(what); exit(1); }

int main(int argc, char **argv)
{
    const char message[] = "SBE-TPROXY-SMOKE";
    char buffer[sizeof(message)];
    struct sockaddr_storage address = {0}, peer = {0};
    socklen_t length, peer_length = sizeof(peer);
    int server, family, type, fd, yes = 1;
    ssize_t count;
    if (argc != 4 || (strcmp(argv[1], "server") && strcmp(argv[1], "client")) ||
        (strcmp(argv[2], "4") && strcmp(argv[2], "6")) ||
        (strcmp(argv[3], "tcp") && strcmp(argv[3], "udp"))) {
        fputs("usage: tproxy-smoke server|client 4|6 tcp|udp\n", stderr);
        return 2;
    }
    alarm(10);
    server = !strcmp(argv[1], "server");
    family = !strcmp(argv[2], "4") ? AF_INET : AF_INET6;
    type = !strcmp(argv[3], "tcp") ? SOCK_STREAM : SOCK_DGRAM;
    fd = socket(family, type, 0);
    if (fd < 0) fail("socket");
    if (family == AF_INET) {
        struct sockaddr_in *a = (struct sockaddr_in *)&address;
        a->sin_family = family;
        a->sin_port = htons(server ? 45001 : 45002);
        inet_pton(family, server ? "0.0.0.0" : "127.0.0.2", &a->sin_addr);
        length = sizeof(*a);
    } else {
        struct sockaddr_in6 *a = (struct sockaddr_in6 *)&address;
        a->sin6_family = family;
        a->sin6_port = htons(server ? 45001 : 45002);
        inet_pton(family, server ? "::" : "::2", &a->sin6_addr);
        length = sizeof(*a);
    }
    if (server) {
        if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes))) fail("reuseaddr");
        if (setsockopt(fd, family == AF_INET ? SOL_IP : SOL_IPV6,
                       family == AF_INET ? IP_TRANSPARENT : IPV6_TRANSPARENT,
                       &yes, sizeof(yes))) fail("transparent");
        if (bind(fd, (struct sockaddr *)&address, length)) fail("bind");
        if (type == SOCK_STREAM && listen(fd, 1)) fail("listen");
        puts("READY"); fflush(stdout);
        if (type == SOCK_STREAM) {
            int child = accept(fd, (struct sockaddr *)&peer, &peer_length);
            if (child < 0) fail("accept");
            close(fd); fd = child;
        }
        count = recvfrom(fd, buffer, sizeof(buffer), 0, (struct sockaddr *)&peer, &peer_length);
        if (count != sizeof(message) || memcmp(buffer, message, sizeof(message))) fail("payload");
        /* UDP source-port preservation needs an original-destination reply
         * socket. Receipt is the bounded test here; TCP also tests the reply. */
        if (type == SOCK_STREAM && send(fd, message, sizeof(message), 0) != sizeof(message)) fail("reply");
    } else {
        if (connect(fd, (struct sockaddr *)&address, length)) fail("connect");
        if (send(fd, message, sizeof(message), 0) != sizeof(message)) fail("send");
        if (type == SOCK_STREAM) {
            count = recv(fd, buffer, sizeof(buffer), MSG_WAITALL);
            if (count != sizeof(message) || memcmp(buffer, message, sizeof(message))) fail("echo");
        }
    }
    close(fd);
    printf("PASS %s IPv%s %s\n", argv[1], argv[2], argv[3]);
    return 0;
}
