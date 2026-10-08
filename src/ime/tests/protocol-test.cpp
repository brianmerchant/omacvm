// The mac-ime port protocol, guest side (src/ime/guest/addon/protocol.cpp),
// without Fcitx5 or a VM: framing, the Mac's messages (also broken and
// hostile ones), code points to bytes, the lines the guest sends, the caret.
//   src/ime/tests/run.sh   (builds and runs this; CI and on the Mac)
#include "../guest/addon/protocol.h"

#include <cstdio>
#include <cstdlib>
#include <random>
#include <string>
#include <vector>

using namespace omacvm_ime;

static int failures = 0;
#define EXPECT(cond, what)                                                       \
    do {                                                                         \
        if (cond) {                                                              \
            std::printf("ok   %s\n", what);                                      \
        } else {                                                                 \
            std::printf("FAIL %s (line %d)\n", what, __LINE__);                  \
            failures++;                                                          \
        }                                                                        \
    } while (0)

static std::vector<std::string> lines(const std::vector<std::string> &chunks) {
    LineReader r;
    std::vector<std::string> out;
    for (const auto &c : chunks) {
        r.feed(c.data(), c.size(), [&](std::string_view l) { out.emplace_back(l); });
    }
    return out;
}

int main() {
    // ---------- framing ----------
    {
        auto l = lines({"{\"a\":1}\n{\"b\"", ":2}\n\n", "tail"});
        EXPECT(l.size() == 2 && l[0] == "{\"a\":1}" && l[1] == "{\"b\":2}",
               "lines split across reads; empty lines and an unfinished one ignored");
        std::string big(kMaxLine + 1, 'x');
        l = lines({big.substr(0, 3000), big.substr(3000) + "\n{\"ok\":1}\n"});
        EXPECT(l.size() == 1 && l[0] == "{\"ok\":1}", "a line over 4 KiB is dropped whole, the next one kept");
        std::string fits(kMaxLine, 'y');
        l = lines({fits + "\n"});
        EXPECT(l.size() == 1 && l[0].size() == kMaxLine, "a line of exactly 4 KiB is kept");
    }

    // ---------- JSON ----------
    {
        Json j;
        EXPECT(parseJson(" {\"t\":\"x\",\"n\":[1,2.5,-3e2],\"b\":true,\"z\":null} ", j) &&
                   j.get("n")->array.size() == 3 && j.get("n")->array[2].number == -300,
               "JSON: object, array, numbers, literals");
        EXPECT(parseJson("\"\\u65e5\\u672c\\ud83d\\ude00\"", j) && j.string == "日本😀",
               "JSON: \\u escapes and a surrogate pair");
        EXPECT(!parseJson("\"\\ud83d\"", j), "JSON: a lone surrogate is refused");
        EXPECT(!parseJson("\"a\\u0000b\"", j), "JSON: NUL in a string is refused");
        EXPECT(!parseJson("{\"a\":1,}", j) && !parseJson("[1 2]", j) && !parseJson("{a:1}", j) &&
                   !parseJson("01", j) && !parseJson("1.", j) && !parseJson("\"x", j) &&
                   !parseJson("{} {}", j) && !parseJson("nan", j) && !parseJson("1e999", j),
               "JSON: malformed input is refused");
        std::string deep(20, '[');
        deep += std::string(20, ']');
        EXPECT(!parseJson(deep, j), "JSON: nesting is limited");
        EXPECT(!parseJson(std::string("\"\xff\""), j), "JSON: invalid UTF-8 in a string is refused");
    }

    // ---------- the Mac's messages ----------
    {
        MacMessage m = parseMac("{\"t\":\"hello\",\"v\":1}");
        EXPECT(m.kind == MacMessage::Kind::Hello && m.version == 1, "hello");
        EXPECT(parseMac("{\"t\":\"hello\"}").kind == MacMessage::Kind::Invalid, "hello without a version: dropped");
        EXPECT(parseMac("{\"t\":\"cancel\"}").kind == MacMessage::Kind::Cancel, "cancel");
        m = parseMac("{\"t\":\"commit\",\"text\":\"日本\"}");
        EXPECT(m.kind == MacMessage::Kind::Commit && m.text == "日本", "commit");
        EXPECT(parseMac("{\"t\":\"commit\",\"text\":\"\"}").kind == MacMessage::Kind::Invalid,
               "an empty commit: dropped");
        EXPECT(parseMac("{\"t\":\"commit\",\"text\":5}").kind == MacMessage::Kind::Invalid,
               "a commit whose text is no string: dropped");

        // にほn: 3 code points, 7 bytes (3+3+1); cursor 3 = byte 7.
        m = parseMac("{\"t\":\"preedit\",\"text\":\"にほn\",\"cursor\":3,\"segs\":[[0,2,1],[2,3,0]]}");
        EXPECT(m.kind == MacMessage::Kind::Preedit && m.cursor == 7 && m.segments.size() == 2 &&
                   m.segments[0].start == 0 && m.segments[0].end == 6 && m.segments[0].active &&
                   m.segments[1].start == 6 && m.segments[1].end == 7 && !m.segments[1].active,
               "preedit: code points become UTF-8 bytes for Fcitx5");
        m = parseMac("{\"t\":\"preedit\",\"text\":\"😀a\",\"cursor\":1}");
        EXPECT(m.kind == MacMessage::Kind::Preedit && m.cursor == 4, "preedit: an emoji is one code point, four bytes");
        m = parseMac("{\"t\":\"preedit\",\"text\":\"ab\"}");
        EXPECT(m.kind == MacMessage::Kind::Preedit && m.cursor == 2 && m.segments.empty(),
               "preedit without cursor: at the end");
        m = parseMac("{\"t\":\"preedit\",\"text\":\"\"}");
        EXPECT(m.kind == MacMessage::Kind::Preedit && m.text.empty(), "an empty preedit (the guest clears it)");

        const char *bad[] = {
            "{\"t\":\"preedit\",\"text\":\"ab\",\"cursor\":3}",              // past the end
            "{\"t\":\"preedit\",\"text\":\"ab\",\"cursor\":-1}",
            "{\"t\":\"preedit\",\"text\":\"ab\",\"cursor\":1.5}",
            "{\"t\":\"preedit\",\"text\":\"ab\",\"cursor\":1e300}",
            "{\"t\":\"preedit\",\"text\":\"ab\",\"cursor\":\"1\"}",
            "{\"t\":\"preedit\",\"text\":\"ab\",\"segs\":[[0,3,0]]}",        // past the end
            "{\"t\":\"preedit\",\"text\":\"ab\",\"segs\":[[1,1,0]]}",        // empty
            "{\"t\":\"preedit\",\"text\":\"abc\",\"segs\":[[0,2,0],[1,3,0]]}",  // overlapping
            "{\"t\":\"preedit\",\"text\":\"abc\",\"segs\":[[1,2,0],[0,1,0]]}",  // out of order
            "{\"t\":\"preedit\",\"text\":\"ab\",\"segs\":[[0,1,2]]}",        // unknown kind
            "{\"t\":\"preedit\",\"text\":\"ab\",\"segs\":[[0,1]]}",
            "{\"t\":\"preedit\",\"text\":\"ab\",\"segs\":{}}",
            "{\"t\":\"preedit\"}",
            "{\"t\":\"focus\",\"on\":true}",                                 // the guest's own message
            "{\"t\":7}",
            "[]",
            "\"preedit\"",
            "",
        };
        bool all = true;
        for (const char *b : bad) {
            all = all && parseMac(b).kind == MacMessage::Kind::Invalid;
        }
        EXPECT(all, "wrong types, positions, segments and messages: all dropped");
        std::string many = "{\"t\":\"preedit\",\"text\":\"" + std::string(100, 'a') + "\",\"segs\":[";
        for (int i = 0; i < 65; i++) {
            many += (i ? "," : "") + std::string("[") + std::to_string(i) + "," + std::to_string(i + 1) + ",0]";
        }
        many += "]}";
        EXPECT(parseMac(many).kind == MacMessage::Kind::Invalid, "more than 64 segments: dropped");
        std::string longText = "{\"t\":\"commit\",\"text\":\"" + std::string(kMaxLine, 'a') + "\"}";
        EXPECT(parseMac(longText).kind == MacMessage::Kind::Invalid, "a line over 4 KiB: dropped");
    }

    // ---------- the guest's lines ----------
    {
        EXPECT(helloLine() == "{\"t\":\"hello\",\"v\":1}", "hello line");
        EXPECT(focusOffLine() == "{\"t\":\"focus\",\"on\":false}", "focus off line");
        EXPECT(focusLine(false, Rect{10, 20.5, 2, 18}, true) ==
                   "{\"t\":\"focus\",\"on\":true,\"kind\":\"text\",\"rect\":[10,20.5,2,18],\"exact\":true}",
               "focus line with a caret");
        EXPECT(focusLine(true, std::nullopt, false) == "{\"t\":\"focus\",\"on\":true,\"kind\":\"password\"}",
               "focus line: a password field, no caret");
        EXPECT(rectLine(Rect{-1920, 0, 1, 1}, false) == "{\"t\":\"rect\",\"rect\":[-1920,0,1,1],\"exact\":false}",
               "rect line (outputs left of the main one have negative x)");
        EXPECT(resetLine() == "{\"t\":\"reset\"}", "reset line");
        Json j;
        EXPECT(jsonString("a\"b\\c\n\x01") == "\"a\\\"b\\\\c\\n\\u0001\"" &&
                   parseJson(jsonString(std::string("x\xff" "y")), j) && j.string == "x\xef\xbf\xbdy",
               "strings escaped; invalid UTF-8 becomes U+FFFD");
    }

    // ---------- the caret ----------
    {
        Rect win{100, 50, 800, 600};
        Caret c = caretFor(Rect{40, 60, 4, 36}, 2.0, true, win);
        EXPECT(c.rect && c.exact && c.rect->x == 120 && c.rect->y == 80 && c.rect->w == 2 && c.rect->h == 18,
               "relative caret at scale 2: window origin + caret / 2, exact");
        c = caretFor(Rect{0, 0, 0, 0}, 1.0, true, win);
        EXPECT(c.rect && !c.exact && c.rect->x == 100 && c.rect->w == 800, "no caret (Wayland IM v2): the window, not exact");
        c = caretFor(Rect{500, 400, 2, 20}, 1.0, false, win);
        EXPECT(c.rect && !c.exact && c.rect->x == 100, "an absolute caret (XIM): the window, not exact");
        c = caretFor(Rect{40, 60, 4, 36}, 0.0, true, win);
        EXPECT(c.rect && c.rect->x == 140, "scale 0 counts as 1");
        c = caretFor(Rect{40, 60, 4, 36}, 1.0, true, std::nullopt);
        EXPECT(!c.rect, "no window known: no caret");
        auto w = parseHyprWindow("{\"address\":\"0x1\",\"at\":[12, -40],\"size\":[1900,1018],\"title\":\"x\"}");
        EXPECT(w && w->x == 12 && w->y == -40 && w->w == 1900 && w->h == 1018, "Hyprland's j/activewindow");
        EXPECT(!parseHyprWindow("{}") && !parseHyprWindow("{\"at\":[1],\"size\":[1,1]}") &&
                   !parseHyprWindow("{\"at\":[0,0],\"size\":[0,10]}") && !parseHyprWindow("not json"),
               "no window, or a broken answer: nothing");
    }

    // ---------- fuzz: random and mutated input never crashes ----------
    {
        std::mt19937 rng(273);
        const std::vector<std::string> seeds = {
            "{\"t\":\"preedit\",\"text\":\"にほn\",\"cursor\":3,\"segs\":[[0,2,1],[2,3,0]]}",
            "{\"t\":\"commit\",\"text\":\"日本\"}", "{\"t\":\"hello\",\"v\":1}", "{\"t\":\"cancel\"}"};
        size_t valid = 0;
        LineReader r;
        for (int i = 0; i < 200000; i++) {
            std::string s = seeds[size_t(i) % seeds.size()];
            int edits = 1 + int(rng() % 4);
            for (int k = 0; k < edits; k++) {
                size_t at = rng() % (s.size() + 1);
                switch (rng() % 3) {
                case 0: s.insert(at, 1, char(rng() % 256)); break;
                case 1: if (at < s.size()) s.erase(at, 1); break;
                default: if (at < s.size()) s[at] = char(rng() % 256); break;
                }
            }
            MacMessage m = parseMac(s);
            if (m.kind == MacMessage::Kind::Preedit) {
                // Whatever got through is consistent.
                bool ok = m.cursor <= m.text.size() && validUtf8(m.text);
                size_t last = 0;
                for (const auto &seg : m.segments) {
                    ok = ok && seg.start >= last && seg.start < seg.end && seg.end <= m.text.size();
                    last = seg.end;
                }
                if (!ok) {
                    EXPECT(false, "fuzz: a preedit that got through is consistent");
                    break;
                }
            }
            valid += m.kind != MacMessage::Kind::Invalid;
            s += '\n';
            r.feed(s.data(), s.size(), [](std::string_view l) { (void)parseMac(l); });
        }
        std::printf("ok   fuzz: 200000 mutated lines, %zu still valid, every one handled\n", valid);
    }

    std::printf(failures ? "%d FAILED\n" : "all passed\n", failures);
    return failures ? 1 : 0;
}
