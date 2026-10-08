/*
 * The rules for the Mac's input methods in the VM (omacvm-cocoa-ime-logic.patch,
 * ui/omacvm-ime.h): the guest's lines, when keys go to the input method,
 * where each key goes (with it off: every key QEMU's way, as before), the
 * caret's output, code points. No QEMU, no display, no input method.
 *   test-ime.sh
 */
#include "omacvm-ime.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
#define EXPECT(cond, what)                                              \
    do {                                                                \
        if (cond) {                                                     \
            printf("ok   %s\n", what);                                  \
        } else {                                                        \
            printf("FAIL %s (line %d)\n", what, __LINE__);              \
            failures++;                                                 \
        }                                                               \
    } while (0)

static char got[8][OMACVM_IME_MAX_LINE + 1];
static size_t got_len[8];
static int got_n;
static void collect(const char *line, size_t len, void *opaque)
{
    (void)opaque;
    if (got_n < 8) {
        memcpy(got[got_n], line, len);
        got[got_n][len] = 0;
        got_len[got_n++] = len;
    }
}

static OmacVMImeState on_state(void)
{
    OmacVMImeState s = { 0 };
    s.hello = s.focus = s.source_im = s.window_key = s.switch_keys = true;
    return s;
}

#define SPACE 49
#define KEY_A 0
#define KEY_RETURN 36

int main(void)
{
    /* ---------- lines from the guest ---------- */
    {
        OmacVMImeLines l = { 0 };
        const char *a = "{\"t\":\"hello\",\"v\":1}\n{\"t\":\"fo", *b = "cus\",\"on\":false}\n\n";
        got_n = 0;
        omacvm_ime_lines_feed(&l, a, strlen(a), collect, NULL);
        omacvm_ime_lines_feed(&l, b, strlen(b), collect, NULL);
        EXPECT(got_n == 2 && !strcmp(got[0], "{\"t\":\"hello\",\"v\":1}") &&
               !strcmp(got[1], "{\"t\":\"focus\",\"on\":false}"),
               "lines split across reads, an empty one ignored");
        static char big[OMACVM_IME_MAX_LINE + 64];
        memset(big, 'x', sizeof(big));
        got_n = 0;
        omacvm_ime_lines_feed(&l, big, sizeof(big), collect, NULL);
        omacvm_ime_lines_feed(&l, "\n{}\n", 4, collect, NULL);
        EXPECT(got_n == 1 && !strcmp(got[0], "{}"), "a line over 4 KiB is dropped whole, the next one kept");
        got_n = 0;
        omacvm_ime_lines_feed(&l, big, OMACVM_IME_MAX_LINE, collect, NULL);
        omacvm_ime_lines_feed(&l, "\n", 1, collect, NULL);
        EXPECT(got_n == 1 && got_len[0] == OMACVM_IME_MAX_LINE, "a line of exactly 4 KiB is kept");
        got_n = 0;
        omacvm_ime_lines_feed(&l, "{\"half", 6, collect, NULL);
        omacvm_ime_lines_reset(&l);
        omacvm_ime_lines_feed(&l, "{}\n", 3, collect, NULL);
        EXPECT(got_n == 1 && !strcmp(got[0], "{}"), "a reset (the guest went) forgets half a line");
    }

    /* ---------- the guest's numbers ---------- */
    EXPECT(omacvm_ime_rect_ok(-1920, 30.5, 2, 18) && omacvm_ime_rect_ok(0, 0, 0, 0),
           "a caret box: negative places (outputs left or above), zero sizes");
    EXPECT(!omacvm_ime_rect_ok(NAN, 0, 1, 1) && !omacvm_ime_rect_ok(0, INFINITY, 1, 1) &&
           !omacvm_ime_rect_ok(1e7, 0, 1, 1) && !omacvm_ime_rect_ok(0, 0, -1, 1) &&
           !omacvm_ime_rect_ok(0, 0, 1, -0.5) && !omacvm_ime_rect_ok(0, 0, 1e300, 1),
           "NaN, infinity, huge numbers and negative sizes are refused");

    /* ---------- when keys go to the input method ---------- */
    {
        int active = 0, focus = 0;
        for (int m = 0; m < 32; m++) {
            OmacVMImeState s = { 0 };
            s.hello = m & 1; s.focus = m & 2; s.password = m & 4; s.source_im = m & 8; s.window_key = m & 16;
            active += omacvm_ime_active(&s);
            focus += omacvm_ime_text_focus(&s);
            if (omacvm_ime_active(&s) != (s.hello && s.focus && !s.password && s.source_im && s.window_key)) {
                active = -100;
            }
        }
        EXPECT(active == 1, "keys go to the input method only with: hello, a text field, no password, the VM's keyboard, an input method on the Mac");
        EXPECT(focus == 2, "a text field with the keyboard: whatever the Mac's input source");
    }

    /* ---------- off, or not in a text field: every key QEMU's way ---------- */
    {
        OmacVMImeKeys k = { 0 };
        k.prev = (OmacVMImeHotKey){ true, SPACE, OMACVM_IME_CONTROL };
        k.next = (OmacVMImeHotKey){ true, SPACE, OMACVM_IME_CONTROL | OMACVM_IME_OPTION };
        const uint32_t mods[] = { 0, OMACVM_IME_SHIFT, OMACVM_IME_CONTROL, OMACVM_IME_OPTION, OMACVM_IME_COMMAND,
                                  OMACVM_IME_CONTROL | OMACVM_IME_OPTION, OMACVM_IME_CONTROL | OMACVM_IME_SHIFT,
                                  OMACVM_IME_COMMAND | OMACVM_IME_SHIFT, 1u << 23 /* fn */, 1u << 16 /* caps */ };
        int other = 0;
        for (int m = 0; m < 32; m++) {
            OmacVMImeState s = { 0 };
            s.hello = m & 1; s.focus = m & 2; s.password = m & 4; s.source_im = m & 8; s.window_key = m & 16;
            s.switch_keys = true;
            if (omacvm_ime_text_focus(&s)) {
                continue;
            }
            for (int t = 0; t < 3; t++) {
                for (int kc = -1; kc <= 128; kc++) {
                    for (size_t i = 0; i < sizeof(mods) / sizeof(mods[0]); i++) {
                        other += omacvm_ime_route(&k, &s, (OmacVMImeKeyType)t, kc, mods[i]) != OMACVM_IME_PASS;
                    }
                }
            }
        }
        EXPECT(other == 0, "outside a text field every key, release and modifier goes the VM's way (also Control-Space)");
    }

    /* ---------- in a text field with an input method ---------- */
    {
        OmacVMImeState s = on_state();
        OmacVMImeKeys k = { 0 };
        k.prev = (OmacVMImeHotKey){ true, SPACE, OMACVM_IME_CONTROL };
        k.next = (OmacVMImeHotKey){ true, SPACE, OMACVM_IME_CONTROL | OMACVM_IME_OPTION };
        EXPECT(omacvm_ime_route(&k, &s, OMACVM_IME_DOWN, KEY_A, 0) == OMACVM_IME_TO_IM, "a letter: the input method");
        EXPECT(omacvm_ime_route(&k, &s, OMACVM_IME_DOWN, KEY_A, OMACVM_IME_SHIFT) == OMACVM_IME_TO_IM &&
               omacvm_ime_route(&k, &s, OMACVM_IME_DOWN, KEY_A, OMACVM_IME_OPTION) == OMACVM_IME_TO_IM,
               "Shift and Option: the input method");
        EXPECT(omacvm_ime_route(&k, &s, OMACVM_IME_DOWN, KEY_A, OMACVM_IME_COMMAND) == OMACVM_IME_PASS &&
               omacvm_ime_route(&k, &s, OMACVM_IME_DOWN, KEY_A, OMACVM_IME_CONTROL) == OMACVM_IME_PASS &&
               omacvm_ime_route(&k, &s, OMACVM_IME_DOWN, KEY_A, OMACVM_IME_COMMAND | OMACVM_IME_SHIFT) == OMACVM_IME_PASS,
               "Cmd and Control chords: the VM (shortcuts, Hyprland's binds)");
        EXPECT(omacvm_ime_route(&k, &s, OMACVM_IME_FLAGS, 56, OMACVM_IME_SHIFT) == OMACVM_IME_PASS,
               "a modifier change: the VM");
        EXPECT(omacvm_ime_route(&k, &s, OMACVM_IME_UP, KEY_A, 0) == OMACVM_IME_PASS,
               "the release of a key the input method did not use: the VM");
        omacvm_ime_take(&k, KEY_A);
        EXPECT(omacvm_ime_route(&k, &s, OMACVM_IME_UP, KEY_A, 0) == OMACVM_IME_DROP &&
               omacvm_ime_route(&k, &s, OMACVM_IME_UP, KEY_A, 0) == OMACVM_IME_PASS,
               "the release of a key it used: dropped once");
        omacvm_ime_take(&k, KEY_RETURN);
        s.focus = false;
        EXPECT(omacvm_ime_route(&k, &s, OMACVM_IME_UP, KEY_RETURN, 0) == OMACVM_IME_DROP,
               "... also after the focus went (the VM never saw it go down)");
        s = on_state();
        omacvm_ime_take(&k, 5);
        omacvm_ime_release_all(&k);
        EXPECT(omacvm_ime_route(&k, &s, OMACVM_IME_UP, 5, 0) == OMACVM_IME_PASS, "release_all forgets them");
        omacvm_ime_take(&k, 200);
        omacvm_ime_take(&k, -1);
        EXPECT(omacvm_ime_route(&k, &s, OMACVM_IME_DOWN, 200, 0) == OMACVM_IME_PASS,
               "key codes out of range: the VM, never an index past the table");

        /* macOS's input source shortcuts */
        EXPECT(omacvm_ime_route(&k, &s, OMACVM_IME_DOWN, SPACE, OMACVM_IME_CONTROL) == OMACVM_IME_SWITCH_PREV &&
               omacvm_ime_route(&k, &s, OMACVM_IME_UP, SPACE, OMACVM_IME_CONTROL) == OMACVM_IME_DROP,
               "Control-Space in a text field: the Mac's previous input source, release dropped");
        EXPECT(omacvm_ime_route(&k, &s, OMACVM_IME_DOWN, SPACE, OMACVM_IME_CONTROL | OMACVM_IME_OPTION) == OMACVM_IME_SWITCH_NEXT,
               "Control-Option-Space: the next one");
        EXPECT(omacvm_ime_route(&k, &s, OMACVM_IME_DOWN, SPACE, OMACVM_IME_CONTROL | OMACVM_IME_SHIFT) == OMACVM_IME_PASS,
               "Control-Shift-Space is not the shortcut: the VM");
        s.source_im = false;
        EXPECT(omacvm_ime_route(&k, &s, OMACVM_IME_DOWN, SPACE, OMACVM_IME_CONTROL) == OMACVM_IME_SWITCH_PREV &&
               omacvm_ime_route(&k, &s, OMACVM_IME_DOWN, KEY_A, 0) == OMACVM_IME_PASS,
               "on a plain layout: the shortcut still switches (to the input method), letters go to the VM");
        s = on_state();
        s.switch_keys = false;
        EXPECT(omacvm_ime_route(&k, &s, OMACVM_IME_DOWN, SPACE, OMACVM_IME_CONTROL) == OMACVM_IME_PASS,
               "macOS keeps its own shortcuts: it switches itself, the key is the VM's as before");
        s = on_state();
        s.password = true;
        EXPECT(omacvm_ime_route(&k, &s, OMACVM_IME_DOWN, SPACE, OMACVM_IME_CONTROL) == OMACVM_IME_PASS &&
               omacvm_ime_route(&k, &s, OMACVM_IME_DOWN, KEY_A, 0) == OMACVM_IME_PASS,
               "a password field: plain keys, no switch");
        s = on_state();
        k.prev.enabled = false;
        EXPECT(omacvm_ime_route(&k, &s, OMACVM_IME_DOWN, SPACE, OMACVM_IME_CONTROL) == OMACVM_IME_PASS,
               "the shortcut switched off in System Settings: the VM");
        k.prev = (OmacVMImeHotKey){ true, 50, OMACVM_IME_COMMAND };
        EXPECT(omacvm_ime_route(&k, &s, OMACVM_IME_DOWN, 50, OMACVM_IME_COMMAND | (1u << 23)) == OMACVM_IME_SWITCH_PREV,
               "a shortcut set to another key: that key (fn and other flags ignored)");
    }

    /* ---------- the caret on the Mac's screens ---------- */
    {
        OmacVMImeBox outs[3] = { { 0, 0, 1512, 945 }, { 1512, -300, 2560, 1440 }, { 0, 0, 0, 0 } };
        EXPECT(omacvm_ime_output_for(outs, 3, 100, 100) == 0 && omacvm_ime_output_for(outs, 3, 2000, -100) == 1,
               "the output the caret is on");
        EXPECT(omacvm_ime_output_for(outs, 3, 1511.9, 944) == 0 && omacvm_ime_output_for(outs, 3, 1512, 0) == 1,
               "edges: right and bottom belong to the next output");
        EXPECT(omacvm_ime_output_for(outs, 3, -5, 2000) == 0, "just off every output: the nearest");
        EXPECT(omacvm_ime_output_for(outs, 0, 1, 1) == -1 && omacvm_ime_output_for(outs + 2, 1, 0, 0) == -1,
               "no output known (or only empty ones): none");
        double u0, v0, u1, v1;
        omacvm_ime_fractions(outs[1], 1512 + 256, -300 + 144, 2, 36, &u0, &v0, &u1, &v1);
        EXPECT(u0 > 0.0999 && u0 < 0.1001 && v0 > 0.0999 && v0 < 0.1001 && v1 > 0.1249 && v1 < 0.1251,
               "the caret as fractions of its output");
        omacvm_ime_fractions(outs[0], -50, 900, 3000, 400, &u0, &v0, &u1, &v1);
        EXPECT(u0 == 0 && u1 == 1 && v1 == 1, "a box past the output's edges is cut to it");
    }

    /* ---------- code points ---------- */
    {
        const uint16_t s[] = { 'a', 0xD83D, 0xDE00, 0x65E5, 'b' };   /* a 😀 日 b */
        EXPECT(omacvm_ime_code_points(s, 5, 0) == 0 && omacvm_ime_code_points(s, 5, 1) == 1 &&
               omacvm_ime_code_points(s, 5, 3) == 2 && omacvm_ime_code_points(s, 5, 5) == 4,
               "UTF-16 positions as code points (a surrogate pair is one)");
        EXPECT(omacvm_ime_code_points(s, 5, 2) == 2, "an index inside a pair counts the pair");
        EXPECT(omacvm_ime_code_points(s, 5, 99) == 4, "past the end: all of it");
        const uint16_t lone[] = { 0xD83D, 'x' };
        EXPECT(omacvm_ime_code_points(lone, 2, 2) == 2, "a lone surrogate counts as one");
    }

    printf(failures ? "%d FAILED\n" : "all passed\n", failures);
    return failures ? 1 : 0;
}
