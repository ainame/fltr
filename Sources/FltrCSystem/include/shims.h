#ifndef FLTR_CSYSTEM_SHIMS_H
#define FLTR_CSYSTEM_SHIMS_H

#include <termios.h>
#include <sys/ioctl.h>
#include <unistd.h>

// Wrapper for ioctl with TIOCGWINSZ to avoid variadic function issues on Linux
static inline int fltr_ioctl_TIOCGWINSZ(int fd, struct winsize *ws) {
    return ioctl(fd, TIOCGWINSZ, ws);
}

// Portable VMIN/VTIME setters.
// On macOS c_cc is a 20-element tuple (VMIN=16, VTIME=17); on Linux
// glibc/musl it is a 32-element array (VMIN=6, VTIME=5).  These helpers
// let Swift callers avoid platform-specific tuple-index access.
static inline void fltr_termios_setVMIN(struct termios *t, cc_t value) {
    t->c_cc[VMIN] = value;
}
static inline void fltr_termios_setVTIME(struct termios *t, cc_t value) {
    t->c_cc[VTIME] = value;
}

#endif /* FLTR_CSYSTEM_SHIMS_H */
