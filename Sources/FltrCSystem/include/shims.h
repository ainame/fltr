#ifndef FLTR_CSYSTEM_SHIMS_H
#define FLTR_CSYSTEM_SHIMS_H

#include <termios.h>
#include <sys/ioctl.h>
#include <unistd.h>

// Wrapper for ioctl with TIOCGWINSZ to avoid variadic function issues on Linux
static inline int fltr_ioctl_TIOCGWINSZ(int fd, struct winsize *ws) {
    return ioctl(fd, TIOCGWINSZ, ws);
}

#endif /* FLTR_CSYSTEM_SHIMS_H */
