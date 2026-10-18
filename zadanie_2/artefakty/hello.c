#include <stdio.h>
#include <sys/utsname.h>

int main(void) {
    struct utsname u;
    uname(&u);
#if defined(__aarch64__)
    puts("Skompilowano dla: aarch64 (ARM64)");
#elif defined(__x86_64__)
    puts("Skompilowano dla: x86_64");
#endif
    printf("Uruchomiono na:   %s\n", u.machine);
    return 0;
}
