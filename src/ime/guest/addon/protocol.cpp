// OmacVM mac-ime: the port's line protocol (see protocol.h).
#include "protocol.h"

#include <cmath>
#include <cstdio>
#include <cstring>

namespace omacvm_ime {

void LineReader::feed(const char *data, size_t len,
                      const std::function<void(std::string_view)> &line) {
    for (size_t i = 0; i < len; i++) {
        char c = data[i];
        if (c == '\n') {
            if (!skipping_ && !buf_.empty()) {
                line(buf_);
            }
            buf_.clear();
            skipping_ = false;
            continue;
        }
        if (skipping_) {
            continue;
        }
        if (buf_.size() >= kMaxLine) {
            // Too long: dropped up to its newline.
            buf_.clear();
            skipping_ = true;
            continue;
        }
        buf_.push_back(c);
    }
}

const Json *Json::get(std::string_view key) const {
    if (type != Type::Object) {
        return nullptr;
    }
    for (const auto &kv : object) {
        if (kv.first == key) {
            return &kv.second;
        }
    }
    return nullptr;
}

namespace {

class Parser {
public:
    Parser(std::string_view s, size_t maxDepth) : s_(s), maxDepth_(maxDepth) {}

    bool parse(Json &out) {
        skip();
        if (!value(out, 0)) {
            return false;
        }
        skip();
        return i_ == s_.size();
    }

private:
    std::string_view s_;
    size_t i_ = 0;
    size_t maxDepth_;

    void skip() {
        while (i_ < s_.size() &&
               (s_[i_] == ' ' || s_[i_] == '\t' || s_[i_] == '\n' || s_[i_] == '\r')) {
            i_++;
        }
    }
    bool literal(std::string_view w) {
        if (s_.substr(i_, w.size()) != w) {
            return false;
        }
        i_ += w.size();
        return true;
    }
    static void put(std::string &out, uint32_t cp) {
        if (cp < 0x80) {
            out.push_back(char(cp));
        } else if (cp < 0x800) {
            out.push_back(char(0xC0 | (cp >> 6)));
            out.push_back(char(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            out.push_back(char(0xE0 | (cp >> 12)));
            out.push_back(char(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(char(0x80 | (cp & 0x3F)));
        } else {
            out.push_back(char(0xF0 | (cp >> 18)));
            out.push_back(char(0x80 | ((cp >> 12) & 0x3F)));
            out.push_back(char(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(char(0x80 | (cp & 0x3F)));
        }
    }
    bool hex4(uint32_t &v) {
        if (i_ + 4 > s_.size()) {
            return false;
        }
        v = 0;
        for (int k = 0; k < 4; k++) {
            char c = s_[i_++];
            v <<= 4;
            if (c >= '0' && c <= '9') v |= uint32_t(c - '0');
            else if (c >= 'a' && c <= 'f') v |= uint32_t(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') v |= uint32_t(c - 'A' + 10);
            else return false;
        }
        return true;
    }
    bool str(std::string &out) {
        if (i_ >= s_.size() || s_[i_] != '"') {
            return false;
        }
        i_++;
        size_t start = i_;
        while (i_ < s_.size()) {
            unsigned char c = (unsigned char)s_[i_];
            if (c == '"') {
                i_++;
                return validUtf8(out);
            }
            if (c < 0x20) {
                return false;
            }
            if (c != '\\') {
                out.push_back(char(c));
                i_++;
                continue;
            }
            i_++;
            if (i_ >= s_.size()) {
                return false;
            }
            char e = s_[i_++];
            switch (e) {
            case '"': out.push_back('"'); break;
            case '\\': out.push_back('\\'); break;
            case '/': out.push_back('/'); break;
            case 'b': out.push_back('\b'); break;
            case 'f': out.push_back('\f'); break;
            case 'n': out.push_back('\n'); break;
            case 'r': out.push_back('\r'); break;
            case 't': out.push_back('\t'); break;
            case 'u': {
                uint32_t cp;
                if (!hex4(cp)) return false;
                if (cp >= 0xD800 && cp <= 0xDBFF) {
                    uint32_t lo;
                    if (!literal("\\u") || !hex4(lo) || lo < 0xDC00 || lo > 0xDFFF) {
                        return false;
                    }
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                    return false;
                }
                if (cp == 0) return false;   // no NUL in text
                put(out, cp);
                break;
            }
            default:
                return false;
            }
        }
        (void)start;
        return false;
    }
    bool num(double &out) {
        size_t start = i_;
        if (i_ < s_.size() && s_[i_] == '-') i_++;
        if (i_ >= s_.size()) return false;
        if (s_[i_] == '0') {
            i_++;
        } else if (s_[i_] >= '1' && s_[i_] <= '9') {
            while (i_ < s_.size() && s_[i_] >= '0' && s_[i_] <= '9') i_++;
        } else {
            return false;
        }
        if (i_ < s_.size() && s_[i_] == '.') {
            i_++;
            size_t d = i_;
            while (i_ < s_.size() && s_[i_] >= '0' && s_[i_] <= '9') i_++;
            if (i_ == d) return false;
        }
        if (i_ < s_.size() && (s_[i_] == 'e' || s_[i_] == 'E')) {
            i_++;
            if (i_ < s_.size() && (s_[i_] == '+' || s_[i_] == '-')) i_++;
            size_t d = i_;
            while (i_ < s_.size() && s_[i_] >= '0' && s_[i_] <= '9') i_++;
            if (i_ == d) return false;
        }
        if (i_ - start > 32) return false;
        std::string t(s_.substr(start, i_ - start));
        char *end = nullptr;
        out = std::strtod(t.c_str(), &end);
        return end && *end == '\0' && std::isfinite(out);
    }
    bool value(Json &out, size_t depth) {
        if (depth > maxDepth_ || i_ >= s_.size()) {
            return false;
        }
        char c = s_[i_];
        if (c == '{') {
            out.type = Json::Type::Object;
            i_++;
            skip();
            if (i_ < s_.size() && s_[i_] == '}') {
                i_++;
                return true;
            }
            for (;;) {
                skip();
                std::string key;
                if (!str(key)) return false;
                skip();
                if (i_ >= s_.size() || s_[i_] != ':') return false;
                i_++;
                skip();
                Json v;
                if (!value(v, depth + 1)) return false;
                out.object.emplace_back(std::move(key), std::move(v));
                skip();
                if (i_ < s_.size() && s_[i_] == ',') { i_++; continue; }
                if (i_ < s_.size() && s_[i_] == '}') { i_++; return true; }
                return false;
            }
        }
        if (c == '[') {
            out.type = Json::Type::Array;
            i_++;
            skip();
            if (i_ < s_.size() && s_[i_] == ']') {
                i_++;
                return true;
            }
            for (;;) {
                skip();
                Json v;
                if (!value(v, depth + 1)) return false;
                out.array.push_back(std::move(v));
                skip();
                if (i_ < s_.size() && s_[i_] == ',') { i_++; continue; }
                if (i_ < s_.size() && s_[i_] == ']') { i_++; return true; }
                return false;
            }
        }
        if (c == '"') {
            out.type = Json::Type::String;
            return str(out.string);
        }
        if (literal("true")) { out.type = Json::Type::Bool; out.boolean = true; return true; }
        if (literal("false")) { out.type = Json::Type::Bool; out.boolean = false; return true; }
        if (literal("null")) { out.type = Json::Type::Null; return true; }
        out.type = Json::Type::Number;
        return num(out.number);
    }
};

// One code point at s[i]: its length in bytes, or 0 when the UTF-8 is bad
// (overlong forms, surrogates and values past U+10FFFF included).
size_t utf8Len(std::string_view s, size_t i) {
    unsigned char c = (unsigned char)s[i];
    size_t n;
    uint32_t cp, min;
    if (c < 0x80) return 1;
    if ((c & 0xE0) == 0xC0) { n = 2; cp = c & 0x1F; min = 0x80; }
    else if ((c & 0xF0) == 0xE0) { n = 3; cp = c & 0x0F; min = 0x800; }
    else if ((c & 0xF8) == 0xF0) { n = 4; cp = c & 0x07; min = 0x10000; }
    else return 0;
    if (i + n > s.size()) return 0;
    for (size_t k = 1; k < n; k++) {
        unsigned char d = (unsigned char)s[i + k];
        if ((d & 0xC0) != 0x80) return 0;
        cp = (cp << 6) | (d & 0x3F);
    }
    if (cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return 0;
    return n;
}

bool count(const Json *v, double &out) {
    if (!v || v->type != Json::Type::Number || v->number < 0 || v->number > 1e6 ||
        v->number != std::floor(v->number)) {
        return false;
    }
    out = v->number;
    return true;
}

std::string num(double v) {
    char b[64];
    std::snprintf(b, sizeof b, "%.10g", v);
    return b;
}

std::string rectJson(const Rect &r) {
    return "[" + num(r.x) + "," + num(r.y) + "," + num(r.w) + "," + num(r.h) + "]";
}

} // namespace

bool parseJson(std::string_view text, Json &out, size_t maxDepth) {
    out = Json();
    Parser p(text, maxDepth);
    return p.parse(out);
}

bool validUtf8(std::string_view text) {
    for (size_t i = 0; i < text.size();) {
        size_t n = utf8Len(text, i);
        if (!n) return false;
        i += n;
    }
    return true;
}

size_t codePoints(std::string_view text) {
    size_t n = 0;
    for (size_t i = 0; i < text.size(); n++) {
        size_t l = utf8Len(text, i);
        if (!l) return 0;
        i += l;
    }
    return n;
}

size_t byteOffset(std::string_view text, size_t index) {
    size_t i = 0;
    for (size_t k = 0; k < index && i < text.size(); k++) {
        size_t l = utf8Len(text, i);
        if (!l) return text.size();
        i += l;
    }
    return i;
}

std::string jsonString(std::string_view text) {
    std::string out = "\"";
    for (size_t i = 0; i < text.size();) {
        size_t n = utf8Len(text, i);
        if (!n) {
            out += "\\ufffd";
            i++;
            continue;
        }
        unsigned char c = (unsigned char)text[i];
        if (n == 1) {
            switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20 || c == 0x7F) {
                    char b[8];
                    std::snprintf(b, sizeof b, "\\u%04x", c);
                    out += b;
                } else {
                    out.push_back(char(c));
                }
            }
        } else {
            out.append(text.substr(i, n));
        }
        i += n;
    }
    out += "\"";
    return out;
}

MacMessage parseMac(std::string_view line) {
    MacMessage m;
    Json j;
    if (line.size() > kMaxLine || !parseJson(line, j) || j.type != Json::Type::Object) {
        return m;
    }
    const Json *t = j.get("t");
    if (!t || t->type != Json::Type::String) {
        return m;
    }
    if (t->string == "hello") {
        double v;
        if (!count(j.get("v"), v) || v < 1) return m;
        m.version = int(v);
        m.kind = MacMessage::Kind::Hello;
        return m;
    }
    if (t->string == "cancel") {
        m.kind = MacMessage::Kind::Cancel;
        return m;
    }
    const Json *text = j.get("text");
    if (!text || text->type != Json::Type::String) {
        return m;
    }
    if (t->string == "commit") {
        if (text->string.empty()) return m;
        m.text = text->string;
        m.kind = MacMessage::Kind::Commit;
        return m;
    }
    if (t->string != "preedit") {
        return m;
    }
    m.text = text->string;
    size_t cps = codePoints(m.text);
    double cursor = double(cps);
    if (const Json *c = j.get("cursor")) {
        if (!count(c, cursor) || cursor > double(cps)) return m;
    }
    m.cursor = byteOffset(m.text, size_t(cursor));
    if (const Json *segs = j.get("segs")) {
        if (segs->type != Json::Type::Array || segs->array.size() > kMaxSegments) return m;
        size_t last = 0;
        for (const Json &s : segs->array) {
            double a, b, k;
            if (s.type != Json::Type::Array || s.array.size() != 3 ||
                !count(&s.array[0], a) || !count(&s.array[1], b) || !count(&s.array[2], k) ||
                a >= b || b > double(cps) || size_t(a) < last || k > 1) {
                return m;
            }
            last = size_t(b);
            m.segments.push_back({byteOffset(m.text, size_t(a)), byteOffset(m.text, size_t(b)), k == 1});
        }
    }
    m.kind = MacMessage::Kind::Preedit;
    return m;
}

std::string helloLine() {
    return "{\"t\":\"hello\",\"v\":" + std::to_string(kVersion) + "}";
}

std::string focusOffLine() {
    return "{\"t\":\"focus\",\"on\":false}";
}

std::string focusLine(bool password, const std::optional<Rect> &rect, bool exact) {
    std::string s = "{\"t\":\"focus\",\"on\":true,\"kind\":\"";
    s += password ? "password" : "text";
    s += "\"";
    if (rect) {
        s += ",\"rect\":" + rectJson(*rect) + ",\"exact\":" + (exact ? "true" : "false");
    }
    return s + "}";
}

std::string rectLine(const Rect &rect, bool exact) {
    return "{\"t\":\"rect\",\"rect\":" + rectJson(rect) + ",\"exact\":" + (exact ? "true" : "false") + "}";
}

std::string resetLine() {
    return "{\"t\":\"reset\"}";
}

Caret caretFor(const Rect &cursor, double scale, bool relative,
               const std::optional<Rect> &window) {
    Caret c;
    if (!window) {
        return c;
    }
    if (!(scale > 0) || !std::isfinite(scale)) {
        scale = 1;
    }
    bool none = cursor.x == 0 && cursor.y == 0 && cursor.w == 0 && cursor.h == 0;
    if (relative && !none) {
        c.rect = Rect{window->x + cursor.x / scale, window->y + cursor.y / scale,
                      cursor.w / scale, cursor.h / scale};
        c.exact = true;
        return c;
    }
    c.rect = *window;
    c.exact = false;
    return c;
}

std::optional<Rect> parseHyprWindow(std::string_view json) {
    Json j;
    if (json.size() > 256 * 1024 || !parseJson(json, j, 16) || j.type != Json::Type::Object) {
        return std::nullopt;
    }
    const Json *at = j.get("at"), *size = j.get("size");
    auto pair = [](const Json *v, double &a, double &b) {
        if (!v || v->type != Json::Type::Array || v->array.size() != 2 ||
            v->array[0].type != Json::Type::Number || v->array[1].type != Json::Type::Number) {
            return false;
        }
        a = v->array[0].number;
        b = v->array[1].number;
        return std::fabs(a) < 1e7 && std::fabs(b) < 1e7;
    };
    Rect r;
    if (!pair(at, r.x, r.y) || !pair(size, r.w, r.h) || r.w <= 0 || r.h <= 0) {
        return std::nullopt;
    }
    return r;
}

} // namespace omacvm_ime
