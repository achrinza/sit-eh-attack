#define _POSIX_C_SOURCE 200112L

#include <arpa/inet.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define HOST "127.0.0.1"
#define PORT 3333

#define MAGIC        "XOXO"
#define MAGIC_LEN    4
#define CMD_BOTH     3
#define COMMAND_SIZE 64
#define CRC_SIZE     4

/*
 * Wire layout, in bytes:
 *
 *   [ 0.. 4)  magic
 *   [ 4.. 8)  command id, network byte order
 *   [ 8..72)  "127.0.0.1:8000;<cmd>;", NUL-padded to COMMAND_SIZE
 *   [72..76)  CRC-32 over everything before it, network byte order
 */
#define OFF_COMMAND (MAGIC_LEN)
#define OFF_PAYLOAD (OFF_COMMAND + 4)
#define OFF_CRC     (OFF_PAYLOAD + COMMAND_SIZE)
#define PACKET_SIZE (OFF_CRC + CRC_SIZE)

static uint32_t crc32(const uint8_t *data, size_t len)
{
    uint32_t crc = ~0u;

    for (size_t i = 0; i < len; i++) {
        crc ^= data[i];

        for (int bit = 0; bit < 8; bit++)
            crc = (crc >> 1) ^ (0xedb88320u & -(crc & 1u));
    }

    return ~crc;
}

/* Fill in a zeroed PACKET_SIZE buffer. Returns -1 if the command doesn't fit. */
static int build_packet(uint8_t *packet, const char *command)
{
    memcpy(packet, MAGIC, MAGIC_LEN);

    uint32_t cmd = htonl(CMD_BOTH);
    memcpy(packet + OFF_COMMAND, &cmd, sizeof(cmd));

    int n = snprintf((char *)packet + OFF_PAYLOAD, COMMAND_SIZE,
                     "127.0.0.1:8000;%s;", command);
    if (n < 0 || n >= COMMAND_SIZE) {
        fprintf(stderr, "command too long\n");
        return -1;
    }

    /* CRC covers magic + command + the padded payload field, zeros included. */
    uint32_t crc = htonl(crc32(packet, OFF_CRC));
    memcpy(packet + OFF_CRC, &crc, sizeof(crc));

    return 0;
}

/* Returns a connected fd, or -1 (fd already closed on failure). */
static int connect_to_server(void)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        perror("socket");
        return -1;
    }

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port   = htons(PORT),
    };

    if (inet_pton(AF_INET, HOST, &addr.sin_addr) != 1) {
        fprintf(stderr, "invalid address\n");
        close(fd);
        return -1;
    }

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("connect");
        close(fd);
        return -1;
    }

    return fd;
}

/* send(2) may write short; keep going until the whole buffer is out. */
static int send_all(int fd, const uint8_t *buf, size_t len)
{
    size_t sent = 0;

    while (sent < len) {
        ssize_t n = send(fd, buf + sent, len - sent, 0);

        if (n < 0) {
            if (errno == EINTR)
                continue;

            perror("send");
            return -1;
        }

        sent += (size_t)n;
    }

    return 0;
}

/* Dump the server's reply to stdout verbatim until it hangs up. */
static int recv_to_stdout(int fd)
{
    uint8_t buf[4096];

    for (;;) {
        ssize_t n = recv(fd, buf, sizeof(buf), 0);

        if (n == 0)
            return 0;

        if (n < 0) {
            if (errno == EINTR)
                continue;

            perror("recv");
            return -1;
        }

        fwrite(buf, 1, (size_t)n, stdout);
    }
}

static int send_command(const char *command)
{
    uint8_t packet[PACKET_SIZE] = {0};

    if (build_packet(packet, command) < 0)
        return 1;

    int fd = connect_to_server();
    if (fd < 0)
        return 1;

    int ret = 1;

    if (send_all(fd, packet, sizeof(packet)) == 0 &&
        recv_to_stdout(fd) == 0)
        ret = 0;

    close(fd);
    return ret;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s [cmd]\n", argv[0]);
        return 1;
    }

    return send_command(argv[1]);
}
