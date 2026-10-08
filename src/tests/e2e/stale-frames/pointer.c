/*
 * pointer: a uinput tablet for the test, moved as OmacVM.app moves the guest's
 * pointer (absolute positions, like qemu-virtio-tablet). Reads lines
 * "X0 Y0 X1 Y1 STEPS INTERVAL_US" (0..65535 over the whole layout) and
 * prints "done" after each move.
 */
#include <fcntl.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int fd;

static void ev(int type, int code, int value)
{
    struct input_event e = { .type = type, .code = code, .value = value };
    if (write(fd, &e, sizeof e) != sizeof e) {
        perror("uinput write");
    }
}

int main(void)
{
    fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0) {
        perror("/dev/uinput");
        return 1;
    }
    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    ioctl(fd, UI_SET_KEYBIT, BTN_LEFT);
    ioctl(fd, UI_SET_EVBIT, EV_ABS);
    ioctl(fd, UI_SET_ABSBIT, ABS_X);
    ioctl(fd, UI_SET_ABSBIT, ABS_Y);
    ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT);
    struct uinput_abs_setup a = { .code = ABS_X, .absinfo = { .maximum = 65535 } };
    ioctl(fd, UI_ABS_SETUP, &a);
    a.code = ABS_Y;
    ioctl(fd, UI_ABS_SETUP, &a);
    struct uinput_setup s = { .id = { .bustype = BUS_VIRTUAL, .vendor = 0x1d6b, .product = 0x0167 } };
    strcpy(s.name, "omacvm-e2e-pointer");
    if (ioctl(fd, UI_DEV_SETUP, &s) || ioctl(fd, UI_DEV_CREATE)) {
        perror("uinput setup");
        return 1;
    }
    setvbuf(stdout, NULL, _IOLBF, 0);
    printf("ready\n");
    int x0, y0, x1, y1, n, us;
    while (scanf("%d %d %d %d %d %d", &x0, &y0, &x1, &y1, &n, &us) == 6) {
        if (n < 1) {
            n = 1;
        }
        for (int i = 0; i <= n; i++) {
            ev(EV_ABS, ABS_X, x0 + (x1 - x0) * i / n);
            ev(EV_ABS, ABS_Y, y0 + (y1 - y0) * i / n);
            ev(EV_SYN, SYN_REPORT, 0);
            usleep(us);
        }
        printf("done\n");
    }
    ioctl(fd, UI_DEV_DESTROY);
    return 0;
}
