#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

typedef pid_t (*responsible_pid_fn)(pid_t);

// Record "<pid> <responsible pid>" beside the .app bundle so the end-to-end
// test can prove the updater launched us through LaunchServices: a process
// that is its own responsible process gets its own TCC (microphone,
// accessibility) grants, while a child of the helper would inherit the old
// app's.
static void record_launch_identity(void) {
    char executable[4096];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0) {
        return;
    }
    // <root>/WhisprStream.app/Contents/MacOS/<exe> -> <root>
    for (int depth = 0; depth < 4; depth += 1) {
        char *slash = strrchr(executable, '/');
        if (slash == NULL) {
            return;
        }
        *slash = '\0';
    }
    char path[4096];
    snprintf(path, sizeof(path), "%s/launch-identity", executable);

    pid_t responsible = -1;
    responsible_pid_fn lookup =
        (responsible_pid_fn)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
    if (lookup != NULL) {
        responsible = lookup(getpid());
    }
    FILE *file = fopen(path, "w");
    if (file == NULL) {
        return;
    }
    fprintf(file, "%d %d\n", (int)getpid(), (int)responsible);
    fclose(file);
}

int main(int argc, char *argv[]) {
    const char *health_file = NULL;
    const char *health_token = NULL;
    record_launch_identity();
    for (int index = 1; index + 1 < argc; index += 1) {
        if (strcmp(argv[index], "--whispr-update-health-file") == 0) {
            health_file = argv[index + 1];
        } else if (strcmp(argv[index], "--whispr-update-health-token") == 0) {
            health_token = argv[index + 1];
        }
    }
    if (health_file == NULL || health_token == NULL) {
        return 0;
    }
    int descriptor = open(health_file, O_WRONLY | O_TRUNC);
    if (descriptor < 0) {
        return 1;
    }
    size_t length = strlen(health_token);
    ssize_t written = write(descriptor, health_token, length);
    close(descriptor);
    if (written != (ssize_t)length) {
        return 1;
    }
    sleep(4);
    return 0;
}
