#include <ghostty/vt.h>
#include <errno.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

struct Pty {
    int fd;
    bool write_failed;
};

static void reply(GhosttyTerminal terminal, void *userdata,
                  const uint8_t *data, size_t len) {
    (void)terminal;
    struct Pty *pty = userdata;
    while (len > 0) {
        ssize_t n = write(pty->fd, data, len);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) {
            pty->write_failed = true;
            return;
        }
        data += n;
        len -= (size_t)n;
    }
}

int main(int argc, char **argv) {
    if (argc < 4) return 2;
    GhosttyTerminal terminal = NULL;
    struct Pty pty = { .fd = -1 };
    struct winsize size = { .ws_col = 80, .ws_row = 24 };
    if (ghostty_terminal_new(NULL, &terminal, size.ws_col, size.ws_row) != GHOSTTY_SUCCESS) {
        fputs("could not allocate libghostty-vt terminal\n", stderr);
        return 1;
    }
    if (ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, &pty) != GHOSTTY_SUCCESS ||
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, (const void *)reply) != GHOSTTY_SUCCESS) {
        fputs("could not configure libghostty-vt pty replies\n", stderr);
        ghostty_terminal_free(terminal);
        return 1;
    }
    fprintf(stderr, "libghostty-vt %s, 80×24, headless pty\n", ghostty_version());
    pid_t pid = forkpty(&pty.fd, NULL, NULL, &size);
    if (pid < 0) {
        perror("forkpty");
        ghostty_terminal_free(terminal);
        return 1;
    }
    if (pid == 0) {
        execv(argv[1], argv + 1);
        _exit(127);
    }

    uint8_t buf[64 * 1024];
    bool read_failed = false;
    while (!pty.write_failed) {
        ssize_t n = read(pty.fd, buf, sizeof buf);
        if (n < 0 && errno == EINTR) continue;
        if (n == 0 || (n < 0 && errno == EIO)) break;
        if (n < 0) {
            perror("read pty");
            read_failed = true;
            break;
        }
        ghostty_terminal_vt_write(terminal, buf, (size_t)n);
    }
    if (read_failed || pty.write_failed) kill(pid, SIGTERM);
    close(pty.fd);
    int status;
    pid_t waited;
    do {
        waited = waitpid(pid, &status, 0);
    } while (waited < 0 && errno == EINTR);
    ghostty_terminal_free(terminal);
    if (read_failed || pty.write_failed || waited < 0 ||
        !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fputs("libghostty-vt pty benchmark failed\n", stderr);
        return 1;
    }
    return 0;
}
