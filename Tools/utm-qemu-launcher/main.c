#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

// UTM ships QEMU, qemu-img and swtpm as frameworks whose Mach-O images are dynamic
// libraries, not executables. This tiny host provides the process entry point and
// forwards argv (without the library path) to the library's own entry point:
//   qemu-*-softmmu.framework: qemu_init / qemu_main_loop / qemu_cleanup
//   swtpm.framework:          swtpm_main
//   qemu-img.framework:       main
typedef void (*qemu_init_fn)(int, char **);
typedef int (*qemu_main_loop_fn)(void);
typedef void (*qemu_cleanup_fn)(int);
typedef int (*main_fn)(int, char **);

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s /path/to/framework-image [arguments...]\n", argv[0]);
        return 64;
    }

    const char *library_path = argv[1];
    void *handle = dlopen(library_path, RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        fprintf(stderr, "utm-qemu-launcher: cannot load %s: %s\n", library_path, dlerror());
        return 66;
    }

    // Hide the library path, retaining the exact argv contract of the tool inside.
    int tool_argc = argc - 1;
    char **tool_argv = &argv[1];

    qemu_init_fn init = (qemu_init_fn)dlsym(handle, "qemu_init");
    if (init != NULL) {
        qemu_main_loop_fn main_loop = (qemu_main_loop_fn)dlsym(handle, "qemu_main_loop");
        qemu_cleanup_fn cleanup = (qemu_cleanup_fn)dlsym(handle, "qemu_cleanup");
        if (main_loop == NULL || cleanup == NULL) {
            fprintf(stderr, "utm-qemu-launcher: incomplete QEMU entry points in %s\n", library_path);
            return 69;
        }
        init(tool_argc, tool_argv);
        int status = main_loop();
        cleanup(status);
        return status;
    }

    main_fn entry = (main_fn)dlsym(handle, "swtpm_main");
    if (entry == NULL) entry = (main_fn)dlsym(handle, "main");
    if (entry == NULL) {
        fprintf(stderr, "utm-qemu-launcher: no known entry point in %s\n", library_path);
        return 69;
    }
    return entry(tool_argc, tool_argv);
}
