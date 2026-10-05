/*
 * macOS's shortcuts while the VM has the keyboard (omacvm-cocoa-shortcuts-logic.patch):
 * every shortcut in macOS's list reaches the VM as keys (or is named as one
 * that cannot), and macOS's own are off exactly while the VM has the keyboard.
 *   test-shortcuts LIST.tsv [LIVE.tsv]         check (LIVE: this Mac's own table)
 *   test-shortcuts --qcodes LIST.tsv           print each enabled chord's QEMU keys
 * LIST/LIVE rows: id, enabled, Mac key code, modifiers (CGEventFlags), name.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "omacvm-shortcuts.h"

/* Mac key code -> Linux key code and QEMU qcode, from QEMU's keycodemapdb
 * (f5772a62, data/keymaps.csv: the table QEMU's Cocoa UI uses). */
static const struct { int linux_code; const char *qcode; const char *name; } osx_keys[128] = {
    [0x00] = { 30, "a", "ANSI_A" },
    [0x01] = { 31, "s", "ANSI_S" },
    [0x02] = { 32, "d", "ANSI_D" },
    [0x03] = { 33, "f", "ANSI_F" },
    [0x04] = { 35, "h", "ANSI_H" },
    [0x05] = { 34, "g", "ANSI_G" },
    [0x06] = { 44, "z", "ANSI_Z" },
    [0x07] = { 45, "x", "ANSI_X" },
    [0x08] = { 46, "c", "ANSI_C" },
    [0x09] = { 47, "v", "ANSI_V" },
    [0x0a] = { 86, "less", "ISO_Section" },
    [0x0b] = { 48, "b", "ANSI_B" },
    [0x0c] = { 16, "q", "ANSI_Q" },
    [0x0d] = { 17, "w", "ANSI_W" },
    [0x0e] = { 18, "e", "ANSI_E" },
    [0x0f] = { 19, "r", "ANSI_R" },
    [0x10] = { 21, "y", "ANSI_Y" },
    [0x11] = { 20, "t", "ANSI_T" },
    [0x12] = { 2, "1", "ANSI_1" },
    [0x13] = { 3, "2", "ANSI_2" },
    [0x14] = { 4, "3", "ANSI_3" },
    [0x15] = { 5, "4", "ANSI_4" },
    [0x16] = { 7, "6", "ANSI_6" },
    [0x17] = { 6, "5", "ANSI_5" },
    [0x18] = { 13, "equal", "ANSI_Equal" },
    [0x19] = { 10, "9", "ANSI_9" },
    [0x1a] = { 8, "7", "ANSI_7" },
    [0x1b] = { 12, "minus", "ANSI_Minus" },
    [0x1c] = { 9, "8", "ANSI_8" },
    [0x1d] = { 11, "0", "ANSI_0" },
    [0x1e] = { 27, "bracket_right", "ANSI_RightBracket" },
    [0x1f] = { 24, "o", "ANSI_O" },
    [0x20] = { 22, "u", "ANSI_U" },
    [0x21] = { 26, "bracket_left", "ANSI_LeftBracket" },
    [0x22] = { 23, "i", "ANSI_I" },
    [0x23] = { 25, "p", "ANSI_P" },
    [0x24] = { 28, "ret", "Return" },
    [0x25] = { 38, "l", "ANSI_L" },
    [0x26] = { 36, "j", "ANSI_J" },
    [0x27] = { 40, "apostrophe", "ANSI_Quote" },
    [0x28] = { 37, "k", "ANSI_K" },
    [0x29] = { 39, "semicolon", "ANSI_Semicolon" },
    [0x2a] = { 43, "backslash", "ANSI_Backslash" },
    [0x2b] = { 51, "comma", "ANSI_Comma" },
    [0x2c] = { 53, "slash", "ANSI_Slash" },
    [0x2d] = { 49, "n", "ANSI_N" },
    [0x2e] = { 50, "m", "ANSI_M" },
    [0x2f] = { 52, "dot", "ANSI_Period" },
    [0x30] = { 15, "tab", "Tab" },
    [0x31] = { 57, "spc", "Space" },
    [0x32] = { 41, "grave_accent", "ANSI_Grave" },
    [0x33] = { 14, "backspace", "Delete" },
    [0x35] = { 1, "esc", "Escape" },
    [0x36] = { 126, "meta_r", "RightCommand" },
    [0x37] = { 125, "meta_l", "Command" },
    [0x38] = { 42, "shift", "Shift" },
    [0x39] = { 58, "caps_lock", "CapsLock" },
    [0x3a] = { 56, "alt", "Option" },
    [0x3b] = { 29, "ctrl", "Control" },
    [0x3c] = { 54, "shift_r", "RightShift" },
    [0x3d] = { 100, "alt_r", "RightOption" },
    [0x3e] = { 97, "ctrl_r", "RightControl" },
    [0x3f] = { 464, "", "Function" },
    [0x40] = { 187, "f17", "F17" },
    [0x41] = { 83, "kp_decimal", "ANSI_KeypadDecimal" },
    [0x43] = { 55, "asterisk", "ANSI_KeypadMultiply" },
    [0x45] = { 78, "kp_add", "ANSI_KeypadPlus" },
    [0x47] = { 69, "num_lock", "ANSI_KeypadClear" },
    [0x48] = { 115, "volumeup", "VolumeUp" },
    [0x49] = { 114, "volumedown", "VolumeDown" },
    [0x4a] = { 113, "audiomute", "Mute" },
    [0x4b] = { 98, "kp_divide", "ANSI_KeypadDivide" },
    [0x4c] = { 96, "kp_enter", "ANSI_KeypadEnter" },
    [0x4e] = { 74, "kp_subtract", "ANSI_KeypadMinus" },
    [0x4f] = { 188, "f18", "F18" },
    [0x50] = { 189, "f19", "F19" },
    [0x51] = { 117, "kp_equals", "ANSI_KeypadEquals" },
    [0x52] = { 82, "kp_0", "ANSI_Keypad0" },
    [0x53] = { 79, "kp_1", "ANSI_Keypad1" },
    [0x54] = { 80, "kp_2", "ANSI_Keypad2" },
    [0x55] = { 81, "kp_3", "ANSI_Keypad3" },
    [0x56] = { 75, "kp_4", "ANSI_Keypad4" },
    [0x57] = { 76, "kp_5", "ANSI_Keypad5" },
    [0x58] = { 77, "kp_6", "ANSI_Keypad6" },
    [0x59] = { 71, "kp_7", "ANSI_Keypad7" },
    [0x5a] = { 190, "f20", "F20" },
    [0x5b] = { 72, "kp_8", "ANSI_Keypad8" },
    [0x5c] = { 73, "kp_9", "ANSI_Keypad9" },
    [0x5d] = { 124, "yen", "JIS_Yen" },
    [0x5e] = { 89, "ro", "JIS_Underscore" },
    [0x5f] = { 95, "", "JIS_KeypadComma" },
    [0x60] = { 63, "f5", "F5" },
    [0x61] = { 64, "f6", "F6" },
    [0x62] = { 65, "f7", "F7" },
    [0x63] = { 61, "f3", "F3" },
    [0x64] = { 66, "f8", "F8" },
    [0x65] = { 67, "f9", "F9" },
    [0x66] = { 123, "lang2", "JIS_Eisu" },
    [0x67] = { 87, "f11", "F11" },
    [0x68] = { 122, "lang1", "JIS_Kana" },
    [0x69] = { 183, "f13", "F13" },
    [0x6a] = { 186, "f16", "F16" },
    [0x6b] = { 184, "f14", "F14" },
    [0x6d] = { 68, "f10", "F10" },
    [0x6e] = { 127, "compose", "KEY_COMPOSE" },
    [0x6f] = { 88, "f12", "F12" },
    [0x71] = { 185, "f15", "F15" },
    [0x72] = { 138, "help", "Help" },
    [0x73] = { 102, "home", "Home" },
    [0x74] = { 104, "pgup", "PageUp" },
    [0x75] = { 111, "delete", "ForwardDelete" },
    [0x76] = { 62, "f4", "F4" },
    [0x77] = { 107, "end", "End" },
    [0x78] = { 60, "f2", "F2" },
    [0x79] = { 109, "pgdn", "PageDown" },
    [0x7a] = { 59, "f1", "F1" },
    [0x7b] = { 105, "left", "LeftArrow" },
    [0x7c] = { 106, "right", "RightArrow" },
    [0x7d] = { 108, "down", "DownArrow" },
    [0x7e] = { 103, "up", "UpArrow" },
};

static int fails, checks;
#define CHECK(cond, ...) do { checks++; if (!(cond)) { fails++; printf("FAIL "); printf(__VA_ARGS__); printf("\n"); } } while (0)

enum { SHIFT = 0x20000, CONTROL = 0x40000, OPTION = 0x80000, COMMAND = 0x100000, FN = 0x800000 };

/* The keys the VM gets for a chord: modifiers first, then the key. 0 keys: none for the guest. */
static int guest_keys(int keycode, unsigned flags, const char *qcodes[8], int *key_linux)
{
    int n = 0;
    if (flags & CONTROL) qcodes[n++] = "ctrl";
    if (flags & SHIFT) qcodes[n++] = "shift";
    if (flags & OPTION) qcodes[n++] = "alt";
    if (flags & COMMAND) qcodes[n++] = "meta_l";
    int special = omacvm_special_key(keycode);
    *key_linux = special >= 0 ? special
               : keycode >= 0 && keycode < 128 ? osx_keys[keycode].linux_code : 0;
    if (special > 0) {
        static const char *f[] = { "f3", "f4", "f5", "f6" };
        qcodes[n++] = f[special - 61];
    } else if (special < 0 && *key_linux) {
        qcodes[n++] = osx_keys[keycode].qcode;
    }
    return n;
}

/* Keys that reach the VM as nothing on purpose (omacvm-shortcuts.h). */
static int no_guest_key(int keycode)
{
    return keycode == 0x7f || keycode == 0x90 || keycode == 0x91 || keycode == 0xb3;
}

static int check_list(const char *path, int print_qcodes, int *enabled_out)
{
    FILE *f = fopen(path, "r");
    if (!f) { printf("FAIL cannot read %s\n", path); fails++; return 0; }
    char line[512];
    int rows = 0, enabled = 0;
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        int id, en, kc; unsigned flags; char name[256] = "";
        if (sscanf(line, "%d\t%d\t%d\t%x\t%255[^\n]", &id, &en, &kc, &flags, name) < 4) continue;
        if (kc == 65535) continue;                /* no key bound */
        rows++;
        enabled += en;
        const char *q[8]; int lnx;
        int n = guest_keys(kc, flags, q, &lnx);
        if (print_qcodes) {
            if (!en || !lnx) continue;
            printf("%d", id);
            for (int i = 0; i < n; i++) printf(" %s", q[i]);
            printf("\t%s\n", name);
            continue;
        }
        /* Never our escape combo: macOS would lose it to the VM's way out. */
        CHECK(!omacvm_is_escape_combo(kc, flags & CONTROL, flags & OPTION, flags & COMMAND),
              "%s: shortcut %d (%s) is the escape combo", path, id, name);
        if (no_guest_key(kc)) {
            CHECK(lnx == 0, "%s: shortcut %d (%s): key 0x%x should give the guest nothing", path, id, name, kc);
        } else {
            CHECK(lnx > 0, "%s: shortcut %d (%s): Mac key 0x%x has no key in the VM", path, id, name, kc);
            CHECK(n >= 1 && q[n - 1] && q[n - 1][0], "%s: shortcut %d (%s): no QEMU key name", path, id, name);
        }
    }
    fclose(f);
    if (enabled_out) *enabled_out = enabled;
    return rows;
}

int main(int argc, char **argv)
{
    if (argc >= 3 && !strcmp(argv[1], "--qcodes")) {
        check_list(argv[2], 1, NULL);
        return fails != 0;
    }
    if (argc < 2) { fprintf(stderr, "usage: test-shortcuts LIST.tsv [LIVE.tsv]\n"); return 2; }

    /* When macOS's own shortcuts are off: only while the VM has the keyboard. */
    CHECK(omacvm_shortcuts_to_vm(1, 1, 1, 0, 0), "captured VM: shortcuts should go to the VM");
    CHECK(!omacvm_shortcuts_to_vm(0, 1, 1, 0, 0), "no full grab: macOS keeps its shortcuts");
    CHECK(!omacvm_shortcuts_to_vm(1, 0, 1, 0, 0), "another app in front: macOS keeps its shortcuts");
    CHECK(!omacvm_shortcuts_to_vm(1, 1, 0, 0, 0), "our window not key (a sheet, the start window): macOS keeps them");
    CHECK(!omacvm_shortcuts_to_vm(1, 1, 1, 1, 0), "OMACVM_MAC_SHORTCUTS=1: macOS keeps them");
    CHECK(!omacvm_shortcuts_to_vm(1, 1, 1, 0, 1), "hung VM window: macOS gets them back");

    /* The escape combo: exactly Control+Option+Command+Esc. */
    CHECK(omacvm_is_escape_combo(53, 1, 1, 1), "Ctrl+Opt+Cmd+Esc is the escape combo");
    CHECK(!omacvm_is_escape_combo(53, 0, 1, 1), "Opt+Cmd+Esc (Force Quit) is not the escape combo");
    CHECK(!omacvm_is_escape_combo(53, 1, 0, 1), "Ctrl+Cmd+Esc is not the escape combo");
    CHECK(!omacvm_is_escape_combo(48, 1, 1, 1), "Ctrl+Opt+Cmd+Tab is not the escape combo");

    /* Apple's own key codes: the F-key they sit on. */
    CHECK(omacvm_special_key(0xa0) == 61, "Mission Control key -> F3");
    CHECK(omacvm_special_key(0xb1) == 62, "Spotlight key -> F4");
    CHECK(omacvm_special_key(0xb0) == 63, "Dictation key -> F5");
    CHECK(omacvm_special_key(0xb2) == 64, "Do Not Disturb key -> F6");
    CHECK(omacvm_special_key(0x83) == 62, "Launchpad key -> F4");
    CHECK(omacvm_special_key(0x67) == -1, "F11 uses QEMU's table");

    int enabled = 0, live_enabled = 0;
    int rows = check_list(argv[1], 0, &enabled);
    CHECK(rows > 100, "%s: only %d shortcuts", argv[1], rows);
    int live = argc >= 3 ? check_list(argv[2], 0, &live_enabled) : 0;
    if (fails) { printf("%d of %d checks failed\n", fails, checks); return 1; }
    printf("ok   %d shortcuts (%d enabled) from the list reach the VM as keys; macOS's own are off only while it has the keyboard\n",
           rows, enabled);
    if (argc >= 3) printf("ok   this Mac's own list: %d shortcuts (%d enabled), each reaches the VM\n", live, live_enabled);
    printf("ok   %d checks\n", checks);
    return 0;
}
