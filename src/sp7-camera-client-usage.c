// SPDX-License-Identifier: GPL-2.0-or-later
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define V4L2_EVENT_PRI_CLIENT_USAGE \
    (V4L2_EVENT_PRIVATE_START + 0x08E00000 + 1)

static volatile sig_atomic_t running = 1;

struct camera {
    const char *dev;
    const char *name;
    int fd;
    unsigned int count;
};

static void stop_handler(int sig)
{
    (void)sig;
    running = 0;
}

static long long now_ms(void)
{
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);

    return ((long long)ts.tv_sec * 1000LL) +
           (ts.tv_nsec / 1000000LL);
}

int main(void)
{
    struct camera cams[3] = {
        { "/dev/video80", "Rear Standard", -1, 0 },
        { "/dev/video81", "Rear HQ",       -1, 0 },
        { "/dev/video82", "Rear Fast",     -1, 0 },
    };

    struct pollfd pfds[3];
    struct v4l2_event_subscription sub;
    int i;

    signal(SIGINT, stop_handler);
    signal(SIGTERM, stop_handler);

    memset(&sub, 0, sizeof(sub));
    sub.type = V4L2_EVENT_PRI_CLIENT_USAGE;
    sub.flags = V4L2_EVENT_SUB_FL_SEND_INITIAL;

    for (i = 0; i < 3; i++) {
        cams[i].fd = open(cams[i].dev, O_RDWR | O_NONBLOCK);

        if (cams[i].fd < 0) {
            perror(cams[i].dev);
            return 2;
        }

        if (ioctl(cams[i].fd, VIDIOC_SUBSCRIBE_EVENT, &sub) < 0) {
            perror("VIDIOC_SUBSCRIBE_EVENT");
            return 3;
        }

        pfds[i].fd = cams[i].fd;
        pfds[i].events = POLLPRI;
        pfds[i].revents = 0;
    }

    printf("TIMELINE READY\n");
    fflush(stdout);

    while (running) {
        int rc = poll(pfds, 3, 1000);

        if (rc < 0) {
            if (errno == EINTR)
                continue;

            perror("poll");
            break;
        }

        if (rc == 0)
            continue;

        for (i = 0; i < 3; i++) {
            if (pfds[i].revents & POLLPRI) {
                struct v4l2_event ev;

                while (ioctl(cams[i].fd, VIDIOC_DQEVENT, &ev) == 0) {
                    uint32_t count = 0;

                    memcpy(&count, ev.u.data, sizeof(count));
                    cams[i].count = count;

                    printf(
                        "%lld ms | %-13s | count=%u"
                        " | STATE: Standard=%u HQ=%u Fast=%u\n",
                        now_ms(),
                        cams[i].name,
                        count,
                        cams[0].count,
                        cams[1].count,
                        cams[2].count
                    );

                    fflush(stdout);
                }
            }
        }
    }

    for (i = 0; i < 3; i++)
        if (cams[i].fd >= 0)
            close(cams[i].fd);

    return 0;
}
