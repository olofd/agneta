// Structured results: `pattern` and `patternProperties`, as JSON Schema means them.
//
// JSON Schema's patterns are ECMA-262 regular expressions; Agneta matches with ICU (NSRegularExpression), whose
// dialect differs where it matters most for the patterns apps write: ICU's `$` also matches before a final newline,
// so "^[a-z]+$" would accept "abc\n"; its `\d` and `\w` are Unicode, so "^\d+$" would accept Arabic-Indic digits.
// So a pattern is translated, token by token, into ICU syntax with ECMA's meaning, and ICU-only syntax (inline flags,
// possessive quantifiers, \A and \z, nested classes) is refused rather than given a meaning ECMA doesn't have.
// What can't be translated exactly is listed in docs/APP_PROTOCOL.md, Structured results.
import Foundation

/// A compiled pattern. NSRegularExpression is immutable and documented safe to share across threads.
final class Pattern: @unchecked Sendable {
    /// The pattern as the app wrote it.
    let source: String
    private let regex: NSRegularExpression

    /// Compiles an ECMA-262 pattern, or gives why it can't be.
    static func compile(_ source: String) -> Result<Pattern, PatternRefusal> {
        switch ECMAPattern.translate(source) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let icu):
            guard let regex = try? NSRegularExpression(pattern: icu) else {
                return .failure(PatternRefusal(reason: "it isn't a regular expression Agneta can read"))
            }
            return .success(Pattern(source: source, regex: regex))
        }
    }

    private init(source: String, regex: NSRegularExpression) {
        self.source = source
        self.regex = regex
    }

    /// Whether `string` has a match (anywhere: JSON Schema patterns aren't anchored), or nil when finding out would
    /// run past `deadline` (a pattern that backtracks without end): matching is stopped there, never left to run.
    func matches(_ string: String, deadline: ContinuousClock.Instant) -> Bool? {
        var found = false, timedOut = false
        regex.enumerateMatches(
            in: string, options: [.reportProgress], range: NSRange(string.startIndex..., in: string)
        ) { match, _, stop in
            if match != nil {
                found = true
                stop.pointee = true
            } else if ContinuousClock.now > deadline {
                timedOut = true
                stop.pointee = true
            }
        }
        return found ? true : (timedOut ? nil : false)
    }
}

struct PatternRefusal: Error, Equatable {
    var reason: String
}

/// ECMA-262 patterns (without flags) in ICU's syntax.
enum ECMAPattern {
    /// ECMA's `\w`, `\d` and line terminators, as ICU classes.
    static let word = "A-Za-z0-9_"
    static let digit = "0-9"
    /// `.` matches anything but these in ECMA; ICU's `.` also leaves out U+0085, so it's spelled out.
    static let dot = #"[^\n\r\x{2028}\x{2029}]"#
    static let boundary = "(?:(?<=[\(word)])(?![\(word)])|(?<![\(word)])(?=[\(word)]))"
    static let notBoundary = "(?:(?<=[\(word)])(?=[\(word)])|(?<![\(word)])(?![\(word)]))"

    /// Letters ECMA gives a meaning after `\`; any other letter escape is ICU's own or an error in ECMA's Unicode mode.
    static let letterEscapes: Set<Character> = [
        "d", "D", "w", "W", "s", "S", "b", "B", "t", "n", "v", "f", "r", "c", "x", "u", "k", "p", "P"
    ]

    static func translate(_ source: String) -> Result<String, PatternRefusal> {
        let chars = Array(source)
        var out = "", i = 0, inClass = false
        func refuse(_ reason: String) -> Result<String, PatternRefusal> { .failure(PatternRefusal(reason: reason)) }
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                guard i + 1 < chars.count else { return refuse("it ends with a lone backslash") }
                let e = chars[i + 1]
                i += 2
                if e.isLetter {
                    guard letterEscapes.contains(e) else {
                        return refuse(
                            "\\\(e) isn't an ECMA-262 escape (it means something else to other regex engines)")
                    }
                    switch (e, inClass) {
                    case ("d", false): out += "[\(digit)]"
                    case ("D", false): out += "[^\(digit)]"
                    case ("w", false): out += "[\(word)]"
                    case ("W", false): out += "[^\(word)]"
                    case ("b", false): out += boundary
                    case ("B", false): out += notBoundary
                    case ("d", true): out += digit
                    case ("w", true): out += word
                    case ("D", true), ("W", true):
                        return refuse("\\\(e) inside a character class can't be matched exactly; write the class out")
                    case ("b", true): out += #"\x{08}"# // backspace, in a class
                    case ("B", true): return refuse("\\B isn't allowed inside a character class")
                    case ("v", _): out += #"\x{0B}"# // ECMA's vertical tab; ICU's \v is a class of line breaks
                    case ("u", _):
                        if i < chars.count, chars[i] == "{" {
                            // \u{…} is ICU's \x{…}.
                            guard let close = chars[i...].firstIndex(of: "}") else {
                                return refuse("\\u{ has no closing }")
                            }
                            out += "\\x{" + String(chars[(i + 1)..<close]) + "}"
                            i = close + 1
                        } else {
                            out += "\\u"
                        }
                    default: out += "\\" + String(e) // s S t n f r c x k p P: the same in both
                    }
                } else {
                    out += "\\" + String(e) // digits (back references) and escaped punctuation
                }
                continue
            }
            if inClass {
                switch c {
                case "]": inClass = false; out += "]"
                case "[": out += "\\[" // literal in ECMA; ICU would start a nested set
                case "&": out += "\\&" // ICU reads && as intersection
                default: out.append(c)
                }
                i += 1
                continue
            }
            switch c {
            case "[":
                // ECMA's [] matches nothing and [^] anything; ICU reads a leading ] as a literal.
                let negated = i + 1 < chars.count && chars[i + 1] == "^"
                let after = i + (negated ? 2 : 1)
                if after < chars.count, chars[after] == "]" {
                    out += negated ? #"[\s\S]"# : "(?!)"
                    i = after + 1
                } else {
                    out += negated ? "[^" : "["
                    inClass = true
                    i = after
                }
                continue
            case "]": out += "\\]"
            case "$": out += "\\z" // the end of the input, never before a final newline
            case ".": out += dot
            case "(":
                if i + 1 < chars.count, chars[i + 1] == "?" {
                    let rest = String(chars[(i + 2)...].prefix(2))
                    let named = rest.hasPrefix("<") && rest.count == 2 && rest.last!.isLetter
                    let allowed = named || [":", "=", "!", "<=", "<!"].contains { rest.hasPrefix($0) }
                    guard allowed else {
                        return refuse("(?\(rest.prefix(1)) isn't ECMA-262 syntax (inline flags and the like)")
                    }
                }
                out += "("
            case "*", "+", "?", "}":
                out.append(c)
                if i + 1 < chars.count, chars[i + 1] == "+" {
                    return refuse("\(c)+ is a possessive quantifier, which ECMA-262 doesn't have")
                }
            default: out.append(c)
            }
            i += 1
        }
        if inClass { return refuse("a character class isn't closed") }
        return .success(out)
    }
}
