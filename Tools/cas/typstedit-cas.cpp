// typstedit-cas — a small command-line CAS helper for TypstEdit's Calculator
// mode. It embeds Giac (https://www-fourier.ujf-grenoble.fr/~parisse/giac/),
// the C++ computer-algebra engine behind Xcas and the HP Prime calculator,
// and exposes it as a line-oriented JSON protocol on stdin/stdout so the
// Swift app can drive it as a subprocess (the same way TypstEdit bundles the
// `typst` compiler).
//
// Protocol (one JSON object per line):
//   request  {"v":1,"id":N,"op":"eval","input":"…","approx":bool,
//             "angle":"rad"|"deg","digits":12}
//   request  {"v":1,"id":N,"op":"reset"}
//   request  {"v":1,"id":N,"op":"shutdown"}
//   response {"v":1,"id":N,"ok":true,"inputTree":{…},"resultTree":{…},
//             "resultText":"…"}
//   response {"v":1,"id":N,"ok":false,"error":"…","errorKind":"parse"|"eval"}
//
// Expression trees: {"t":"num","v":"1/2","approx":"0.5"}, {"t":"sym","name":"x"},
// {"t":"cst","name":"pi"}, {"t":"str","v":"…"}, {"t":"op","name":"+"},
// {"t":"func","name":"sin"}, {"t":"seq"/"vect"/"list","args":[…]},
// {"t":"undef"}.
//
// Interrupting a long computation: the parent sends SIGINT (Process.interrupt()
// from Swift). giac::ctrl_c_signal_handler flips giac's ctrl_c flag and the
// running eval throws; we report it as an interruption.
//
// This file is distributed under GPL-3-or-later, matching Giac. It is a
// separate program from TypstEdit (MIT); see THIRD_PARTY_NOTICES.md.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include <signal.h>
#include <unistd.h>

#include <giac/giac.h>

using namespace giac;

// ---------------------------------------------------------------------------
// Minimal JSON support (writer + parser). No external dependencies.
// ---------------------------------------------------------------------------

static std::string jsonEscape(const std::string & s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (size_t i = 0; i < s.size(); ++i) {
        unsigned char c = (unsigned char) s[i];
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\b': out += "\\b"; break;
        case '\f': out += "\\f"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20) {
                char buf[8];
                snprintf(buf, sizeof(buf), "\\u%04x", c);
                out += buf;
            } else {
                out += (char) c;
            }
        }
    }
    return out;
}

static std::string jsonStr(const std::string & s) { return "\"" + jsonEscape(s) + "\""; }

struct JSONValue {
    enum Kind { Object, Array, String, Number, Bool, Null } kind = Null;
    std::map<std::string, JSONValue> object;
    std::vector<JSONValue> array;
    std::string stringValue;
    double numberValue = 0;
    bool boolValue = false;

    bool has(const std::string & key) const {
        return kind == Object && object.count(key) != 0;
    }
    const JSONValue * get(const std::string & key) const {
        if (kind != Object) return nullptr;
        auto it = object.find(key);
        return it == object.end() ? nullptr : &it->second;
    }
    std::string asString(const std::string & fallback = "") const {
        return kind == String ? stringValue : fallback;
    }
    double asNumber(double fallback = 0) const {
        return kind == Number ? numberValue : fallback;
    }
    bool asBool(bool fallback = false) const {
        return kind == Bool ? boolValue : fallback;
    }
};

struct JSONParser {
    const std::string & src;
    size_t pos = 0;

    explicit JSONParser(const std::string & s) : src(s) {}

    [[noreturn]] void fail(const char * message) const {
        throw std::runtime_error(std::string("JSON: ") + message);
    }

    void skipWS() {
        while (pos < src.size()) {
            char c = src[pos];
            if (c == ' ' || c == '\t' || c == '\r' || c == '\n') ++pos;
            else break;
        }
    }

    char peek() {
        skipWS();
        if (pos >= src.size()) fail("unexpected end of input");
        return src[pos];
    }

    void expect(char c) {
        if (peek() != c) fail("expected character");
        ++pos;
    }

    bool consume(char c) {
        if (pos < src.size() && src[pos] == c) { ++pos; return true; }
        return false;
    }

    JSONValue parse() {
        JSONValue v = parseValue();
        skipWS();
        if (pos != src.size()) fail("trailing characters");
        return v;
    }

    JSONValue parseValue() {
        char c = peek();
        switch (c) {
        case '{': return parseObject();
        case '[': return parseArray();
        case '"': {
            JSONValue v; v.kind = JSONValue::String; v.stringValue = parseString(); return v;
        }
        case 't': case 'f': return parseBool();
        case 'n': return parseNull();
        default: return parseNumber();
        }
    }

    JSONValue parseObject() {
        JSONValue v; v.kind = JSONValue::Object;
        expect('{');
        if (consume('}')) return v;
        for (;;) {
            skipWS();
            if (peek() != '"') fail("expected key string");
            std::string key = parseString();
            expect(':');
            v.object[key] = parseValue();
            if (consume(',')) continue;
            expect('}');
            break;
        }
        return v;
    }

    JSONValue parseArray() {
        JSONValue v; v.kind = JSONValue::Array;
        expect('[');
        if (consume(']')) return v;
        for (;;) {
            v.array.push_back(parseValue());
            if (consume(',')) continue;
            expect(']');
            break;
        }
        return v;
    }

    std::string parseString() {
        expect('"');
        std::string out;
        while (pos < src.size()) {
            char c = src[pos++];
            if (c == '"') return out;
            if (c == '\\') {
                if (pos >= src.size()) fail("bad escape");
                char e = src[pos++];
                switch (e) {
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                case '/': out += '/'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case 'u': {
                    if (pos + 4 > src.size()) fail("bad \\u escape");
                    std::string hex = src.substr(pos, 4);
                    pos += 4;
                    unsigned long code = strtoul(hex.c_str(), nullptr, 16);
                    // Encode as UTF-8 (surrogate pairs unsupported — the
                    // protocol never sends them).
                    if (code < 0x80) {
                        out += (char) code;
                    } else if (code < 0x800) {
                        out += (char) (0xC0 | (code >> 6));
                        out += (char) (0x80 | (code & 0x3F));
                    } else {
                        out += (char) (0xE0 | (code >> 12));
                        out += (char) (0x80 | ((code >> 6) & 0x3F));
                        out += (char) (0x80 | (code & 0x3F));
                    }
                    break;
                }
                default: fail("bad escape");
                }
            } else {
                out += c;
            }
        }
        fail("unterminated string");
    }

    JSONValue parseBool() {
        if (src.compare(pos, 4, "true") == 0) { pos += 4; JSONValue v; v.kind = JSONValue::Bool; v.boolValue = true; return v; }
        if (src.compare(pos, 5, "false") == 0) { pos += 5; JSONValue v; v.kind = JSONValue::Bool; v.boolValue = false; return v; }
        fail("bad literal");
    }

    JSONValue parseNull() {
        if (src.compare(pos, 4, "null") != 0) fail("bad literal");
        pos += 4;
        return JSONValue();
    }

    JSONValue parseNumber() {
        skipWS();
        size_t start = pos;
        while (pos < src.size()) {
            char c = src[pos];
            if ((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.' ||
                c == 'e' || c == 'E') ++pos;
            else break;
        }
        if (start == pos) fail("bad number");
        JSONValue v; v.kind = JSONValue::Number;
        v.numberValue = strtod(src.substr(start, pos - start).c_str(), nullptr);
        return v;
    }
};

// giac's TI mode prints the approximate imaginary unit as the single byte
// 0xA1 (the HP Prime glyph); the rest of the app is UTF-8, so rewrite it to
// "i" and coerce any other invalid UTF-8 byte before it reaches JSON.
static std::string sanitizeText(const std::string & s) {
    static const std::string tiImaginary(1, '\xa1');
    std::string replaced = s;
    size_t pos = 0;
    while ((pos = replaced.find(tiImaginary, pos)) != std::string::npos) {
        replaced.replace(pos, tiImaginary.size(), "i");
        pos += 1;
    }
    // Validate UTF-8; replace any broken byte with '?'.
    std::string out;
    out.reserve(replaced.size());
    size_t i = 0;
    while (i < replaced.size()) {
        unsigned char c = (unsigned char) replaced[i];
        size_t len = 0;
        if (c < 0x80) len = 1;
        else if ((c & 0xE0) == 0xC0) len = 2;
        else if ((c & 0xF0) == 0xE0) len = 3;
        else if ((c & 0xF8) == 0xF0) len = 4;
        bool ok = len > 0 && i + len <= replaced.size();
        for (size_t j = 1; ok && j < len; ++j)
            if (((unsigned char) replaced[i + j] & 0xC0) != 0x80) ok = false;
        if (!ok) { out += '?'; i += 1; continue; }
        out.append(replaced, i, len);
        i += len;
    }
    return out;
}

// ---------------------------------------------------------------------------
// giac gen → protocol JSON tree
// ---------------------------------------------------------------------------

static bool isConstantName(const std::string & name) {
    static const char * constants[] = {
        "pi", "e", "i", "infinity", "inf", "undef", "true", "false",
        "euler_gamma", "_pi", "_e"
    };
    for (const char * c : constants)
        if (name == c) return true;
    return false;
}

// Heads whose symbolic form is an operator; everything else renders as a
// function application.
static bool isOperatorName(const std::string & name) {
    static const char * ops[] = {
        "+", "-", "*", "/", "^", "=", "<", ">", "<=", ">=", "!=", "==",
        "!","|", "and", "or", "not", "xor", ":", ":=", "sto", "=>"
    };
    for (const char * o : ops)
        if (name == o) return true;
    return false;
}

// Approximate numeric expressions while preserving equations and logical
// solution sets. Evaluating an `or` of equations would return a boolean.
static gen approximateTree(const gen & g, GIAC_CONTEXT) {
    switch (g.type) {
    case _INT_: case _ZINT: case _FRAC: case _DOUBLE_: case _REAL:
    case _CPLX: case _FLOAT_: case _IDNT:
        return evalf(g, 1, contextptr);
    case _VECT: {
        vecteur v = *g._VECTptr;
        for (size_t i = 0; i < v.size(); ++i)
            v[i] = approximateTree(v[i], contextptr);
        return gen(v, g.subtype);
    }
    case _SYMB: {
        const char * raw = g._SYMBptr->sommet.ptr()->s;
        std::string name = raw ? std::string(raw) : std::string();
        static const char * relational[] = {"=", "==", "<", ">", "<=", ">=", "!=", "or", "and"};
        bool keepStructure = false;
        for (const char * r : relational)
            if (name == r) { keepStructure = true; break; }
        gen feuille = g._SYMBptr->feuille;
        if (keepStructure) {
            if (feuille.type == _VECT) {
                vecteur v = *feuille._VECTptr;
                for (size_t i = 0; i < v.size(); ++i)
                    v[i] = approximateTree(v[i], contextptr);
                return symbolic(g._SYMBptr->sommet, gen(v, feuille.subtype));
            }
            return symbolic(g._SYMBptr->sommet, approximateTree(feuille, contextptr));
        }
        try {
            return evalf(g, 1, contextptr);
        } catch (std::exception &) {
            return g;
        }
    }
    default:
        return g;
    }
}

static std::string genToJSON(const gen & g, GIAC_CONTEXT) {
    switch (g.type) {
    case _INT_: case _DOUBLE_: case _ZINT: case _REAL: case _CPLX: case _FRAC: case _FLOAT_: {
        std::string exact = sanitizeText(g.print(contextptr));
        std::string node = "{\"t\":\"num\",\"v\":" + jsonStr(exact);
        if (g.type == _ZINT || g.type == _FRAC || g.type == _CPLX) {
            gen approx = evalf(g, 1, contextptr);
            if (approx.type == _DOUBLE_ || approx.type == _REAL || approx.type == _CPLX) {
                std::string approxStr = sanitizeText(approx.print(contextptr));
                if (approxStr != exact && approxStr.find("inf") == std::string::npos)
                    node += ",\"approx\":" + jsonStr(approxStr);
            }
        }
        return node + "}";
    }
    case _IDNT: {
        std::string name = g._IDNTptr->id_name;
        if (isConstantName(name))
            return "{\"t\":\"cst\",\"name\":" + jsonStr(name) + "}";
        return "{\"t\":\"sym\",\"name\":" + jsonStr(name) + "}";
    }
    case _STRNG:
        return "{\"t\":\"str\",\"v\":" + jsonStr(*g._STRNGptr) + "}";
    case _SYMB: {
        const char * raw = g._SYMBptr->sommet.ptr()->s;
        std::string name = raw ? std::string(raw) : std::string();
        // Program/function-definition echoes are not math. Send their printed
        // form as text so the app shows it verbatim instead of typesetting a
        // meaningless call.
        if (name == "program" || name == "lastprog") {
            return "{\"t\":\"str\",\"v\":" + jsonStr(sanitizeText(g.print(contextptr))) + "}";
        }
        gen feuille = g._SYMBptr->feuille;
        std::string args;
        // Multi-argument heads carry their args in a _SEQ__VECT vecteur;
        // a plain (_subtype 0) vector as feuille is a single argument
        // (e.g. det of a matrix), and must not be flattened.
        if (feuille.type == _VECT && feuille.subtype == _SEQ__VECT) {
            const vecteur & v = *feuille._VECTptr;
            for (size_t i = 0; i < v.size(); ++i) {
                if (i) args += ",";
                args += genToJSON(v[i], contextptr);
            }
        } else if (!(feuille.type == _INT_ && feuille.val == 0)) {
            args = genToJSON(feuille, contextptr);
        }
        const char * tag = isOperatorName(name) ? "op" : "func";
        return std::string("{\"t\":\"") + tag + "\",\"name\":" + jsonStr(name) +
               ",\"args\":[" + args + "]}";
    }
    case _VECT: {
        std::string tag = (g.subtype == _SET__VECT || g.subtype == _MAPLE_LIST) ? "list" : "vect";
        std::string args;
        const vecteur & v = *g._VECTptr;
        for (size_t i = 0; i < v.size(); ++i) {
            if (i) args += ",";
            args += genToJSON(v[i], contextptr);
        }
        return "{\"t\":\"" + tag + "\",\"args\":[" + args + "]}";
    }
    case _FUNC:
        // Function objects are rare in results; print them as text.
        return "{\"t\":\"str\",\"v\":" + jsonStr(sanitizeText(g.print(contextptr))) + "}";
    default: {
        // Polynomials, modulo objects, user types… print them as text.
        return "{\"t\":\"str\",\"v\":" + jsonStr(sanitizeText(g.print(contextptr))) + "}";
    }
    }
}

// ---------------------------------------------------------------------------
// Protocol handling
// ---------------------------------------------------------------------------

static std::string makeReply(long id, bool ok, const std::string & inputTree,
                             const std::string & resultTree,
                             const std::string & resultText,
                             const std::string & error,
                             const std::string & errorKind) {
    std::string out = "{\"v\":1,\"id\":" + std::to_string(id) + ",\"ok\":";
    out += ok ? "true" : "false";
    if (ok) {
        if (!inputTree.empty()) out += ",\"inputTree\":" + inputTree;
        if (!resultTree.empty()) out += ",\"resultTree\":" + resultTree;
        if (!resultText.empty()) out += ",\"resultText\":" + jsonStr(resultText);
    } else {
        out += ",\"error\":" + jsonStr(error);
        out += ",\"errorKind\":" + jsonStr(errorKind);
    }
    out += "}";
    return out;
}

static void writeLine(const std::string & line) {
    std::cout << line << "\n";
    std::cout.flush();
}

// Parse + evaluate one input line. Returns the reply line.
static std::string handleEval(const JSONValue & req, context * ctx) {
    long id = (long) req.get("id")->asNumber(0);
    std::string input = req.get("input") ? req.get("input")->asString() : "";
    bool approx = req.get("approx") ? req.get("approx")->asBool() : false;
    std::string angle = req.get("angle") ? req.get("angle")->asString("rad") : "rad";
    long digits = (long) (req.get("digits") ? req.get("digits")->asNumber(12) : 12);

    if (input.empty()) {
        return makeReply(id, false, "", "", "", "Empty input", "parse");
    }

    // Apply the session modes (TI-89 compatibility, angle unit, precision).
    xcas_mode(ctx) = 3;                 // TI-89 style parsing/printing
    angle_radian(angle != "deg", ctx);
    decimal_digits((int) digits, ctx);
    complex_mode(ctx) = true;

    // Start from a clean interruption state (see global.h: the flag must be
    // cleared before eval).
    ctrl_c = false;
    interrupted = false;
    kbd_interrupted = false;

    try {
        // 1. Parse the raw input — kept unevaluated for the input tree.
        gen e(input, ctx);
        if (e.type == _STRNG && e.subtype == -1) {
            return makeReply(id, false, "", "", "", "Syntax error", "parse");
        }
        std::string inputTree = genToJSON(e, ctx);

        // 2. Evaluate. giac's eval already normalizes rationals and roots
        // (1/3+1/6 → 1/2, sqrt(8) → 2*sqrt(2)), matching the TI-89's AUTO
        // simplification, so no extra cleanup pass is needed here — one that
        // re-parses output would evaluate `x=-2 or x=2` solution forms as
        // booleans.
        gen r = e.eval(20, ctx);
        if (approx)
            r = approximateTree(r, ctx);
        std::string resultTree = genToJSON(r, ctx);
        std::string resultText = sanitizeText(r.print(ctx));
        return makeReply(id, true, inputTree, resultTree, resultText, "", "");
    } catch (const std::exception & err) {
        std::string message = sanitizeText(err.what());
        if (ctrl_c || interrupted || kbd_interrupted ||
            message.find("interruption") != std::string::npos)
            return makeReply(id, false, "", "", "", "Interrupted", "interrupt");
        return makeReply(id, false, "", "", "", message, "eval");
    }
}

int main() {
    // SIGINT (from Swift's Process.interrupt()) flips giac's interrupt flag.
    signal(SIGINT, ctrl_c_signal_handler);
    // giac's handler may forward SIGINT to a child; make sure we don't kill
    // our own process group.
    child_id = 0;

    context * ctx = new context;
    xcas_mode(ctx) = 3;                 // TI-89 compatibility by default
    angle_radian(true, ctx);
    decimal_digits(12, ctx);
    complex_mode(ctx) = true;

    std::string line;
    while (std::getline(std::cin, line)) {
        if (line.empty()) continue;
        try {
            JSONParser parser(line);
            JSONValue req = parser.parse();
            long id = req.get("id") ? (long) req.get("id")->asNumber(0) : 0;
            std::string op = req.get("op") ? req.get("op")->asString() : "";

            if (op == "eval") {
                writeLine(handleEval(req, ctx));
            } else if (op == "reset") {
                // Drop every stored variable by starting from a fresh context.
                delete ctx;
                ctx = new context;
                xcas_mode(ctx) = 3;
                angle_radian(true, ctx);
                decimal_digits(12, ctx);
                complex_mode(ctx) = true;
                writeLine(makeReply(id, true, "", "", "ok", "", ""));
            } else if (op == "shutdown") {
                writeLine(makeReply(id, true, "", "", "bye", "", ""));
                break;
            } else {
                writeLine(makeReply(id, false, "", "", "", "Unknown op '" + op + "'", "protocol"));
            }
        } catch (const std::exception & err) {
            writeLine(makeReply(0, false, "", "", "", err.what(), "protocol"));
        }
    }
    delete ctx;
    return 0;
}
