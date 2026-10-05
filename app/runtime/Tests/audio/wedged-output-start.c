// Test for qemu-sdl-audio-playback-thread.patch: a Mac audio device that does
// not answer, as on the Mac mini on 2026-10-05 (coreaudiod up for days, a USB
// interface as the default output): every AudioQueueStart() blocked for good.
//
// Injected with DYLD_INSERT_LIBRARIES, it makes AudioQueueStart() block:
//   AQHANG_AFTER=N    let the first N starts through, block the later ones
//                     (the device dies while the VM runs); default 0
//   AQHANG_UNTIL=FILE block only until FILE exists, then start for real (the
//                     device answers again); without it, block forever
//   AQHANG_FAIL=1     with AQHANG_UNTIL: a start that was blocked then fails
//                     with 268435460 (coreaudiod killed); later ones work
//
//   clang -dynamiclib -o aqhang.dylib wedged-output-start.c -framework AudioToolbox
//
// Load it into a runtime that dyld lets take DYLD_INSERT_LIBRARIES (ad hoc
// signed, or re-signed with allow-dyld-environment-variables and
// disable-library-validation; see slow-capture-start.c) and start a headless
// test VM. Expected: QMP answers within a second or two and the guest boots;
// pw-play/pacat in the guest finish in their own time plus at most 3 s;
// qemu.log says "the Mac's audio device does not answer", and with
// AQHANG_UNTIL "works again" once FILE is there. The VM powers off as usual.
// Without the library: sound as before. Before the patch the VM hung in
// qemu_init (hda_audio_init -> sdl_init_out -> COREAUDIO_OpenDevice).
#include <AudioToolbox/AudioToolbox.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <unistd.h>

static atomic_int starts;

static OSStatus wedged_start(AudioQueueRef queue, const AudioTimeStamp *time)
{
    const char *after = getenv("AQHANG_AFTER");
    const char *until = getenv("AQHANG_UNTIL");

    int waited = 0;

    if (atomic_fetch_add(&starts, 1) >= (after ? atoi(after) : 0)) {
        while (!until || access(until, F_OK) != 0) {
            waited = 1;
            usleep(100 * 1000);
        }
    }
    if (waited && getenv("AQHANG_FAIL")) {
        return 268435460;
    }
    return AudioQueueStart(queue, time);
}

__attribute__((used)) static const struct {
    const void *replacement, *original;
} interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)wedged_start, (const void *)AudioQueueStart },
};
