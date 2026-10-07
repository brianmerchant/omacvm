// Offline tests for notchcast's pure helpers (notchrule.h). Run: ./test.sh
#include "notchrule.h"

static int failures;
#define CHECK(cond, what) do { if (!(cond)) { failures++; printf("FAIL line %d: %s\n", __LINE__, what); } } while (0)

// `hyprctl -j layers` as Hyprland 0.56 prints it (shortened): the bar on both outputs.
static const char *LAYERS =
    "{\n\"Virtual-1\": {\n    \"levels\": {\n\n        \"0\": [\n                {\n"
    "                    \"address\": \"0xaaaac581bf30\",\n                    \"x\": 0,\n"
    "                    \"y\": 0,\n                    \"w\": 1088,\n                    \"h\": 612,\n"
    "                    \"alpha\": 1,\n                    \"namespace\": \"omarchy-background\",\n"
    "                    \"pid\": 872\n                }\n        ],\n        \"2\": [\n                {\n"
    "                    \"address\": \"0xaaaac58a9770\",\n                    \"x\": 0,\n"
    "                    \"y\": 0,\n                    \"w\": 1088,\n                    \"h\": 26,\n"
    "                    \"alpha\": 1,\n                    \"namespace\": \"omarchy-bar\",\n"
    "                    \"pid\": 872\n                }\n        ]\n    }\n},\"NOTCH\": {\n    \"levels\": {\n\n"
    "        \"3\": [\n                {\n                    \"address\": \"0xaaaac59aba40\",\n"
    "                    \"x\": 0,\n                    \"y\": -33,\n                    \"w\": 1088,\n"
    "                    \"h\": 33,\n                    \"alpha\": 1,\n"
    "                    \"namespace\": \"omarchy-background\",\n                    \"pid\": 872\n"
    "                },                {\n                    \"address\": \"0xaaaac58383e0\",\n"
    "                    \"x\": 0,\n                    \"y\": -33,\n                    \"w\": 1088,\n"
    "                    \"h\": 33,\n                    \"alpha\": 1,\n"
    "                    \"namespace\": \"omarchy-bar\",\n                    \"pid\": 872\n"
    "                }\n        ]\n    }\n}\n}\n";

// NOTCH just made: only the wallpaper copy there yet, the bar on Virtual-1.
static const char *LAYERS_NO_BAR =
    "{\n\"Virtual-1\": {\n    \"levels\": {\n        \"2\": [\n                {\n"
    "                    \"x\": 0,\n                    \"y\": 0,\n                    \"w\": 1470,\n"
    "                    \"h\": 26,\n                    \"namespace\": \"omarchy-bar\"\n                }\n"
    "        ]\n    }\n},\"NOTCH\": {\n    \"levels\": {\n        \"3\": [\n                {\n"
    "                    \"x\": 0,\n                    \"y\": -33,\n                    \"w\": 1470,\n"
    "                    \"h\": 33,\n                    \"namespace\": \"omarchy-background\"\n                }\n"
    "        ]\n    }\n}\n}\n";

// The bar's surface on NOTCH before it has a size.
static const char *LAYERS_UNSIZED =
    "{\n\"NOTCH\": {\n    \"levels\": {\n        \"3\": [\n                {\n"
    "                    \"x\": 0,\n                    \"y\": 0,\n                    \"w\": 0,\n"
    "                    \"h\": 0,\n                    \"namespace\": \"omarchy-bar\"\n                }\n"
    "        ]\n    }\n}\n}\n";

int main(void) {
    int w, h, lh;
    char buf[256];

    // The Air (1470x923 pt at scale 2, strip 33 pt): 2940x66 px.
    lh = notch_mode(2940, 2, 33, &w, &h);
    CHECK(w == 2940 && h == 66 && lh == 33, "air: 2940x66");
    // Fractional scale 1.6: 26 logical px is 41.6 px, so 30 (48 px).
    lh = notch_mode(2048, 1.6, 26, &w, &h);
    CHECK(lh == 30 && h == 48, "scale 1.6: whole pixels");
    // A strip height a hair over a whole number does not grow by one.
    lh = notch_mode(2940, 2, 33.0000001, &w, &h);
    CHECK(lh == 33, "rounding noise");

    notch_rule_lua(buf, sizeof buf, "NOTCH", 2940, 66, 0, 0, 2);
    CHECK(!strcmp(buf, "hl.monitor({ output = \"NOTCH\", mode = \"2940x66@60\", position = \"0x0\", scale = 2.000000 })"),
          "monitor rule");

    CHECK(layer_on_output(LAYERS, "NOTCH", "omarchy-bar"), "bar on NOTCH");
    CHECK(layer_on_output(LAYERS, "Virtual-1", "omarchy-bar"), "bar on Virtual-1");
    CHECK(!layer_on_output(LAYERS_NO_BAR, "NOTCH", "omarchy-bar"), "only the wallpaper on NOTCH");
    CHECK(layer_on_output(LAYERS_NO_BAR, "NOTCH", "omarchy-background"), "the wallpaper on NOTCH");
    CHECK(!layer_on_output(LAYERS_UNSIZED, "NOTCH", "omarchy-bar"), "no size yet");
    CHECK(!layer_on_output(LAYERS, "NOTCH2", "omarchy-bar"), "other output");
    CHECK(!layer_on_output("{}", "NOTCH", "omarchy-bar"), "no outputs");
    CHECK(!layer_on_output(NULL, "NOTCH", "omarchy-bar"), "no reply");
    CHECK(layer_height_on_output(LAYERS, "NOTCH", "omarchy-bar") == 33, "bar height on NOTCH");
    CHECK(layer_height_on_output(LAYERS, "Virtual-1", "omarchy-bar") == 26, "bar height on Virtual-1");
    CHECK(layer_height_on_output(LAYERS_UNSIZED, "NOTCH", "omarchy-bar") == 0, "no size: 0");
    CHECK(layer_height_on_output(LAYERS_NO_BAR, "NOTCH", "omarchy-bar") == 0, "no bar: 0");

    geom_line(buf, sizeof buf, "646", "825", "33", "0");
    CHECK(!strcmp(buf, "646 825 33 0\n"), "geom line");
    geom_line(buf, sizeof buf, "646", "825", "", "");
    CHECK(!strcmp(buf, "646 825 0 0\n"), "geom line, strip and bar not known");

    // The keeper's rule: a new one at once; the same one at once after NOTCH
    // took it and something moved NOTCH; one Hyprland never took, after 30 s.
    NotchRuleState st = {.sent_ms = -1e9};
    const char *a = "hl.monitor({ output = \"NOTCH\", position = \"0x-33\" })";
    const char *b = "hl.monitor({ output = \"NOTCH\", position = \"0x-40\" })";
    CHECK(notch_rule_due(&st, a, 0), "the first rule goes at once");
    notch_rule_sent(&st, a, 1000);
    CHECK(!notch_rule_due(&st, a, 3000), "the same rule, NOTCH not seen as it wants yet: wait");
    CHECK(!notch_rule_due(&st, a, 30999), "... up to 30 s");
    CHECK(notch_rule_due(&st, a, 31001), "... then again (Hyprland kept refusing it)");
    CHECK(notch_rule_due(&st, b, 3000), "a changed rule goes at once");
    notch_rule_seen(&st, a);   // the keeper's next look: NOTCH as the rule wants
    CHECK(notch_rule_due(&st, a, 5000), "NOTCH took it, then was moved (a reload, another eval): again at once");
    notch_rule_sent(&st, a, 5000);
    CHECK(!notch_rule_due(&st, a, 7000), "sent again and not taken this time: wait again");
    notch_rule_seen(&st, b);   // NOTCH as another rule wants: not this one's
    CHECK(!notch_rule_due(&st, a, 9000), "seen as another rule wants: still waiting for this one");

    printf(failures ? "%d failed\n" : "all passed\n", failures);
    return failures != 0;
}
