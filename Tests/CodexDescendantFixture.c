#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>
#include <string.h>
#include <sys/time.h>

/* Disposable timeout fixture: child confirms TERM resistance before readiness. */
static int marker(const char *executable, const char *suffix) {
    size_t length = strlen(executable) + strlen(suffix) + 1;
    char *path = malloc(length);
    if (!path) return 0;
    snprintf(path, length, "%s%s", executable, suffix);
    FILE *file = fopen(path, "w");
    free(path);
    if (!file) return 0;
    fprintf(file, "%d\n", getpid());
    return fclose(file) == 0;
}
int main(int argc, char **argv) {
    (void)argc;
    if (!marker(argv[0], ".parent.pid")) return 91;
    pid_t child = fork();
    if (child < 0) return 92;
    if (child == 0) {
        signal(SIGTERM, SIG_IGN);
        if (!marker(argv[0], ".child.pid")) _exit(93);
        size_t length = strlen(argv[0]) + sizeof(".ready.time");
        char *path = malloc(length);
        if (!path) _exit(94);
        snprintf(path, length, "%s.ready.time", argv[0]);
        FILE *ready = fopen(path, "w");
        free(path);
        if (!ready) _exit(95);
        struct timeval timestamp;
        gettimeofday(&timestamp, NULL);
        fprintf(ready, "%.6f\n", (double)timestamp.tv_sec + (double)timestamp.tv_usec / 1000000.0);
        fclose(ready);
        sleep(30); /* Holds inherited stdout beyond the bounded client deadline. */
        _exit(0);
    }
    waitpid(child, NULL, 0);
    return 0;
}
