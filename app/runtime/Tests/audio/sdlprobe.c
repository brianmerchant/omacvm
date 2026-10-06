// sdlprobe.dylib: what QEMU's SDL audio backend really hands CoreAudio.
// For the sound-crackle measurements only (README.md here); never shipped.
//
// Injected with DYLD_INSERT_LIBRARIES into a TEST COPY of the runtime whose
// qemu-system-aarch64 is re-signed with the test identity plus
// com.apple.security.cs.allow-dyld-environment-variables and
// disable-library-validation. Interposes the SDL2 calls QEMU makes:
//   SDLPROBE_PCM=FILE    the playback stream as given to SDL, raw S16 stereo
//                        (truncate it to start a measurement; it is appended)
//   SDLPROBE_STATS=FILE  one line a second: callbacks, callbacks that ran dry
//                        after sound (QEMU had too little), silent frames,
//                        longest gap between callbacks
//   SDLPROBE_LOOPBACK=1  the recording device is fake and hears what playback
//                        played, about one 11.6 ms block later (round trip
//                        in the guest without a microphone)
//   SDLPROBE_MUTE=1      with the loopback: the Mac's speakers stay silent
//
// Build: cc -dynamiclib -O2 -o sdlprobe.dylib sdlprobe.c RUNTIME/lib/libSDL2-2.0.0.dylib
// Threads: playback callback on SDL's audio thread; the fake recording
// device's own thread; the lock calls from QEMU's main loop.
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef void (*cb_t)(void *, uint8_t *, int);
typedef struct {
    int freq; uint16_t format; uint8_t channels; uint8_t silence;
    uint16_t samples; uint16_t padding; uint32_t size; cb_t callback; void *userdata;
} Spec;   // SDL2's SDL_AudioSpec
extern uint32_t SDL_OpenAudioDevice(const char *, int, const Spec *, Spec *, int);
extern void SDL_LockAudioDevice(uint32_t);
extern void SDL_UnlockAudioDevice(uint32_t);
extern void SDL_PauseAudioDevice(uint32_t, int);
extern void SDL_CloseAudioDevice(uint32_t);

static mach_timebase_info_data_t tb;
static uint64_t now_ns(void) { return mach_absolute_time() * tb.numer / tb.denom; }

// ---- playback: record and count ----
static cb_t play_cb;
static FILE *pcm, *stats;
static uint64_t last, sec_start, maxgap, ncb, nunder, nsilent;
static int had_sound;

#define FAKE_ID 0x7ff00001u
#define RING (1 << 18)
static int16_t ring[RING * 2];
static volatile uint64_t ring_w, ring_r;
static volatile int cap_open, cap_paused = 1;
static int mute;

static void play(void *ud, uint8_t *buf, int len) {
    play_cb(ud, buf, len);
    uint64_t t = now_ns() / 1000;
    if (last && t - last > maxgap) maxgap = t - last;
    last = t; ncb++;
    if (pcm) fwrite(buf, 1, len, pcm);
    // QEMU fills what it could not give with silence, at the end
    int16_t *s = (int16_t *)buf;
    int n = len / 4, z = 0;
    while (z < n && s[2 * (n - 1 - z)] == 0 && s[2 * (n - 1 - z) + 1] == 0) z++;
    if (had_sound && (z == n || z >= 8)) { nunder++; nsilent += z; }
    if (z < n) had_sound = 1;
    if (cap_open) {
        for (int i = 0; i < n; i++, ring_w++) {
            ring[2 * (ring_w % RING)] = s[2 * i];
            ring[2 * (ring_w % RING) + 1] = s[2 * i + 1];
        }
        if (ring_w - ring_r > RING / 2) ring_r = ring_w - 4096;
        if (mute) memset(buf, 0, len);
    }
    if (!sec_start) sec_start = t;
    if (t - sec_start >= 1000000) {
        if (stats) {
            fprintf(stats, "%ld cb=%llu under=%llu silent_frames=%llu maxgap_us=%llu\n", (long)time(NULL),
                    (unsigned long long)ncb, (unsigned long long)nunder,
                    (unsigned long long)nsilent, (unsigned long long)maxgap);
            fflush(stats);
        }
        if (pcm) fflush(pcm);
        sec_start = t; ncb = nunder = nsilent = maxgap = 0;
    }
}

// ---- the fake recording device (SDLPROBE_LOOPBACK) ----
static pthread_mutex_t fake_mu = PTHREAD_MUTEX_INITIALIZER;
static cb_t cap_cb; static void *cap_ud; static int cap_samples, cap_freq;

static void *capture(void *unused) {
    (void)unused;
    static uint8_t buf[65536];
    uint64_t period = (uint64_t)cap_samples * 1000000000ull / cap_freq, next = 0;
    while (cap_open) {
        uint64_t t = now_ns();
        if (!next) next = t;
        if (t < next) {
            struct timespec ts = { 0, (long)(next - t) };
            nanosleep(&ts, NULL);
            continue;
        }
        next += period;
        if (cap_paused) { ring_r = ring_w; continue; }
        int16_t *o = (int16_t *)buf;
        for (int i = 0; i < cap_samples; i++) {
            if (ring_r < ring_w) {
                o[2 * i] = ring[2 * (ring_r % RING)];
                o[2 * i + 1] = ring[2 * (ring_r % RING) + 1];
                ring_r++;
            } else {
                o[2 * i] = o[2 * i + 1] = 0;
            }
        }
        pthread_mutex_lock(&fake_mu);
        cap_cb(cap_ud, buf, cap_samples * 4);
        pthread_mutex_unlock(&fake_mu);
    }
    return NULL;
}

static uint32_t my_open(const char *dev, int rec, const Spec *want, Spec *have, int allow) {
    if (!tb.denom) mach_timebase_info(&tb);
    if (rec && want && want->samples && getenv("SDLPROBE_LOOPBACK")) {
        if (want->samples * 4 > 65536) return 0;
        if (have) { *have = *want; have->format = 0x8010; have->channels = 2; have->size = want->samples * 4; }
        cap_cb = want->callback; cap_ud = want->userdata;
        cap_samples = want->samples; cap_freq = want->freq;
        mute = getenv("SDLPROBE_MUTE") != NULL;
        cap_paused = 1; cap_open = 1;
        pthread_t th;
        pthread_create(&th, NULL, capture, NULL);
        pthread_detach(th);
        return FAKE_ID;
    }
    if (rec || !want || !want->callback) return SDL_OpenAudioDevice(dev, rec, want, have, allow);
    const char *p = getenv("SDLPROBE_PCM"), *st = getenv("SDLPROBE_STATS");
    if (p && !pcm) pcm = fopen(p, "ab");
    if (st && !stats) stats = fopen(st, "a");
    Spec w = *want;
    play_cb = want->callback;
    w.callback = play;
    uint32_t id = SDL_OpenAudioDevice(dev, rec, &w, have, allow);
    if (stats && have) {
        fprintf(stats, "open freq=%d fmt=0x%x ch=%u samples=%u\n", have->freq, have->format,
                have->channels, have->samples);
        fflush(stats);
    }
    return id;
}
static void my_lock(uint32_t id) { if (id == FAKE_ID) pthread_mutex_lock(&fake_mu); else SDL_LockAudioDevice(id); }
static void my_unlock(uint32_t id) { if (id == FAKE_ID) pthread_mutex_unlock(&fake_mu); else SDL_UnlockAudioDevice(id); }
static void my_pause(uint32_t id, int on) { if (id == FAKE_ID) cap_paused = on; else SDL_PauseAudioDevice(id, on); }
static void my_close(uint32_t id) { if (id == FAKE_ID) cap_open = 0; else SDL_CloseAudioDevice(id); }

__attribute__((used, section("__DATA,__interpose")))
static struct { const void *with, *what; } interpose[] = {
    { (const void *)my_open, (const void *)SDL_OpenAudioDevice },
    { (const void *)my_lock, (const void *)SDL_LockAudioDevice },
    { (const void *)my_unlock, (const void *)SDL_UnlockAudioDevice },
    { (const void *)my_pause, (const void *)SDL_PauseAudioDevice },
    { (const void *)my_close, (const void *)SDL_CloseAudioDevice },
};
