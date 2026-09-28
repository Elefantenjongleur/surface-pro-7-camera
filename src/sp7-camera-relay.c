// SPDX-License-Identifier: GPL-2.0-or-later
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <linux/videodev2.h>

static volatile sig_atomic_t running = 1;

static void handler(int sig)
{
    (void)sig;
    running = 0;
}

static int xioctl(int fd, unsigned long req, void *arg)
{
    int r;

    do {
        r = ioctl(fd, req, arg);
    } while (r < 0 && errno == EINTR);

    return r;
}

static void fill_black(unsigned char *p, size_t size)
{
    size_t i;

    for (i = 0; i + 3 < size; i += 4) {
        p[i + 0] = 16;
        p[i + 1] = 128;
        p[i + 2] = 16;
        p[i + 3] = 128;
    }
}

static int write_full_frame(
    int fd,
    const unsigned char *p,
    size_t size)
{
    ssize_t n;

    do {
        n = write(fd, p, size);
    } while (n < 0 && errno == EINTR);

    if (n < 0) {
        perror("video write");
        return -1;
    }

    if ((size_t)n != size) {
        fprintf(stderr,
                "short video write: %zd statt %zu\n",
                n, size);
        return -1;
    }

    return 0;
}

int main(int argc, char **argv)
{
    const char *dev;
    const char *fifo;

    unsigned int width;
    unsigned int height;
    unsigned int fps_num;
    unsigned int fps_den;

    int vfd = -1;
    int rfd = -1;
    int dummyfd = -1;

    struct v4l2_format fmt;
    struct v4l2_streamparm parm;
    struct pollfd pfd;

    unsigned char *frame = NULL;
    unsigned char *black = NULL;

    size_t frame_size;
    size_t have = 0;

    unsigned long frames = 0;
    unsigned long errors = 0;

    if (argc != 7) {
        fprintf(stderr,
                "usage: %s /dev/videoN fifo width height fps_num fps_den\n",
                argv[0]);
        return 1;
    }

    dev = argv[1];
    fifo = argv[2];

    width   = (unsigned int)strtoul(argv[3], NULL, 10);
    height  = (unsigned int)strtoul(argv[4], NULL, 10);
    fps_num = (unsigned int)strtoul(argv[5], NULL, 10);
    fps_den = (unsigned int)strtoul(argv[6], NULL, 10);

    if (!width || !height || !fps_num || !fps_den) {
        fprintf(stderr, "ungueltige Geometrie/FPS\n");
        return 1;
    }

    signal(SIGTERM, handler);
    signal(SIGINT, handler);

    vfd = open(dev, O_RDWR);

    if (vfd < 0) {
        perror("open video");
        return 2;
    }

    memset(&fmt, 0, sizeof(fmt));

    fmt.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    fmt.fmt.pix.width = width;
    fmt.fmt.pix.height = height;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
    fmt.fmt.pix.field = V4L2_FIELD_NONE;

    if (xioctl(vfd, VIDIOC_S_FMT, &fmt) < 0) {
        perror("VIDIOC_S_FMT");
        close(vfd);
        return 3;
    }

    memset(&parm, 0, sizeof(parm));

    parm.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    parm.parm.output.timeperframe.numerator = fps_den;
    parm.parm.output.timeperframe.denominator = fps_num;

    if (xioctl(vfd, VIDIOC_S_PARM, &parm) < 0) {
        perror("VIDIOC_S_PARM");
        close(vfd);
        return 4;
    }

    frame_size = fmt.fmt.pix.sizeimage;

    printf("S_FMT OK: %ux%u YUYV sizeimage=%zu fps=%u/%u\n",
           fmt.fmt.pix.width,
           fmt.fmt.pix.height,
           frame_size,
           fps_num,
           fps_den);
    fflush(stdout);

    frame = malloc(frame_size);
    black = malloc(frame_size);

    if (!frame || !black) {
        fprintf(stderr, "malloc fehlgeschlagen\n");
        free(frame);
        free(black);
        close(vfd);
        return 5;
    }

    fill_black(black, frame_size);

    /*
     * Genau ein Initialframe hält das exclusive_caps-
     * Loopback als Capture-Gerät sichtbar.
     */
    if (write_full_frame(vfd, black, frame_size) < 0) {
        free(frame);
        free(black);
        close(vfd);
        return 6;
    }

    printf("INITIAL BLACK FRAME OK\n");
    fflush(stdout);

    /*
     * FIFO nonblocking öffnen.
     * Dummy-Writer verhindert EOF im Idle.
     */
    rfd = open(fifo, O_RDONLY | O_NONBLOCK);

    if (rfd < 0) {
        perror("open fifo read");
        free(frame);
        free(black);
        close(vfd);
        return 7;
    }

    dummyfd = open(fifo, O_WRONLY | O_NONBLOCK);

    if (dummyfd < 0) {
        perror("open fifo dummy write");
        close(rfd);
        free(frame);
        free(black);
        close(vfd);
        return 8;
    }

    printf("FIFO READY\n");
    printf("RELAY IDLE – warte auf echte YUYV-Frames\n");
    fflush(stdout);

    memset(&pfd, 0, sizeof(pfd));
    pfd.fd = rfd;
    pfd.events = POLLIN;

    while (running) {
        int pr = poll(&pfd, 1, 500);

        if (pr < 0) {
            if (errno == EINTR)
                continue;

            perror("poll");
            errors++;
            break;
        }

        if (pr == 0)
            continue;

        if (pfd.revents & POLLIN) {
            ssize_t n;

            n = read(rfd,
                     frame + have,
                     frame_size - have);

            if (n > 0) {
                have += (size_t)n;

                if (have == frame_size) {
                    if (write_full_frame(
                            vfd,
                            frame,
                            frame_size) < 0) {
                        errors++;
                        break;
                    }

                    frames++;

                    if (frames == 1 ||
                        frames % 30 == 0) {
                        printf("REAL FRAME %lu\n", frames);
                        fflush(stdout);
                    }

                    have = 0;
                }
            } else if (n < 0 &&
                       errno != EAGAIN &&
                       errno != EWOULDBLOCK &&
                       errno != EINTR) {
                perror("fifo read");
                errors++;
                break;
            }
        }
    }

    printf("Stopping relay – frames=%lu errors=%lu partial=%zu\n",
           frames, errors, have);
    fflush(stdout);

    close(dummyfd);
    close(rfd);

    free(frame);
    free(black);

    close(vfd);

    return errors ? 9 : 0;
}
