/* SPDX-License-Identifier: GPL-2.0 OR MIT */
/*
 * Protocol between the omacvm-vdec kernel module and its daemon, omacvm-vdecd.
 *
 * The module is a V4L2 stateful video decoder (/dev/videoN) that does no
 * decoding itself. The daemon opens /dev/omacvm-vdec, read()s one message at a
 * time (struct ovd_msg, then `size` bytes of bitstream for OVD_MSG_BITSTREAM)
 * and answers with the ioctls below. Buffers are named by (index, seq): seq is
 * new every time a buffer is queued, so an answer for a buffer the app has
 * since taken back is ignored. Instance ids are not reused (cyclic, 31 bits):
 * a late answer for a closed decoder never lands on a new one.
 */
#ifndef OMACVM_VDEC_H
#define OMACVM_VDEC_H

#include <linux/types.h>
#include <linux/ioctl.h>

#define OVD_MAX_BITSTREAM	(16u << 20)
#define OVD_MAX_WIDTH		4096u
#define OVD_MAX_HEIGHT		2304u
#define OVD_MAX_CAPTURE		24u
#define OVD_MIN_SIZE		64u	/* pictures smaller than this fail */
/* SET_CAPS carries it: a daemon and a module from different builds refuse
 * each other (until the VM restarts with the new module). */
#define OVD_VERSION		2u

/* Codecs the daemon can decode (OVD_IOC_SET_CAPS). */
#define OVD_CODEC_H264		(1u << 0)
#define OVD_CODEC_HEVC		(1u << 1)
#define OVD_CODEC_VP9		(1u << 2)

enum ovd_msg_type {
	OVD_MSG_OPEN = 1,		/* an app opened the device */
	OVD_MSG_CLOSE,			/* ...and closed it */
	OVD_MSG_START,			/* OUTPUT streams: codec (V4L2 fourcc) */
	OVD_MSG_BITSTREAM,		/* index, seq, timestamp, size + data */
	OVD_MSG_FLUSH,			/* OUTPUT stopped (seek): drop input */
	OVD_MSG_DRAIN,			/* decode what is queued, then LAST */
	OVD_MSG_CAPTURE_SETUP,		/* count buffers of width x height:
					 * answer with OVD_IOC_SET_BUFFERS */
	OVD_MSG_CAPTURE_QUEUED,		/* index, seq: free to write into */
	OVD_MSG_CAPTURE_STOP,		/* all CAPTURE buffers taken back */
};

struct ovd_msg {
	__u32 type;
	__u32 inst;
	__u32 codec;
	__u32 index;
	__u64 seq;
	__u64 timestamp;	/* ns, copied to the decoded frame */
	__u32 width;
	__u32 height;
	__u32 count;
	__u32 size;		/* bitstream bytes after this header */
};

struct ovd_caps {
	__u32 codecs;		/* OVD_CODEC_* */
	__u32 max_width;
	__u32 max_height;
	__u32 version;		/* OVD_VERSION */
};

/*
 * The decoded picture size: sent before the first frame and on a change.
 * CAPTURE buffers are single-plane ARGB8888 (V4L2_PIX_FMT_ABGR32): with GL,
 * Chromium on Linux renders only ARGB from a decoder, and a virtio-gpu buffer
 * cannot carry two NV12 planes (an import at an offset is the first plane).
 */
struct ovd_format {
	__u32 inst;
	__u32 width;
	__u32 height;
	__u32 visible_width;
	__u32 visible_height;
	__u32 stride;		/* bytes per row */
	__u32 min_buffers;
	__u32 reserved;
};

/* Answer to OVD_MSG_CAPTURE_SETUP: one dmabuf per buffer. */
struct ovd_buffers {
	__u32 inst;
	__u32 count;		/* 0 = failed */
	__s32 fd[OVD_MAX_CAPTURE];
};

#define OVD_DONE_LAST	(1u << 0)	/* CAPTURE: this buffer goes back empty, flagged LAST */
#define OVD_DONE_EOS	(1u << 1)	/* with LAST: end of a drain */
#define OVD_DONE_ERROR	(1u << 2)
/* CAPTURE_DONE with this index and LAST|EOS: a drain ended while the daemon
 * had no CAPTURE buffer (none set up yet, or CAPTURE stopped). The module
 * sends EOS and hands back the next CAPTURE buffer empty, flagged LAST. */
#define OVD_NO_BUFFER	0xffffffffu

struct ovd_done {
	__u32 inst;
	__u32 index;
	__u64 seq;
	__u64 timestamp;
	__u32 flags;
	__u32 reserved;
};

#define OVD_IOC_SET_CAPS	_IOW('O', 1, struct ovd_caps)
#define OVD_IOC_SET_FORMAT	_IOW('O', 2, struct ovd_format)
#define OVD_IOC_SET_BUFFERS	_IOW('O', 3, struct ovd_buffers)
#define OVD_IOC_OUTPUT_DONE	_IOW('O', 4, struct ovd_done)
#define OVD_IOC_CAPTURE_DONE	_IOW('O', 5, struct ovd_done)
#define OVD_IOC_ERROR		_IOW('O', 6, __u32)

#endif
