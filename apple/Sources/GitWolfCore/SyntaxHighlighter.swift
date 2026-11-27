import Foundation

public enum SyntaxKind: Sendable, Hashable {
    case keyword, type, string, comment, number, function, attribute
}

/// A highlighted span, as character offsets (`[start, end)`) into the line's text.
public struct SyntaxToken: Sendable, Hashable {
    public var start: Int
    public var end: Int
    public var kind: SyntaxKind
}

/// A small, dependency-free tokenizer. It is intentionally approximate (no real parsing): diffs show
/// fragments of files, so the goal is fast, stable colouring of keywords, strings, comments,
/// numbers, types and calls. Pure Swift with no Apple frameworks, so ports can mirror it.
public enum SyntaxHighlighter {
    /// Tokens for every line of a diff, keyed by `DiffLine.id`. Empty for unknown file types.
    public static func tokens(for diff: FileDiff, path: String) -> [Int: [SyntaxToken]] {
        guard let language = Language.forPath(path) else { return [:] }
        var result: [Int: [SyntaxToken]] = [:]
        // Block-comment state is tracked separately for the old and new side of the diff.
        var oldState = State(), newState = State()

        for line in diff.lines {
            switch line.kind {
            case .hunkHeader:
                oldState = State(); newState = State()
            case .note:
                break
            case .deletion:
                result[line.id] = tokenize(line.text, language, &oldState)
            case .addition:
                result[line.id] = tokenize(line.text, language, &newState)
            case .context:
                result[line.id] = tokenize(line.text, language, &newState)
                oldState = newState
            }
        }
        return result.filter { !$0.value.isEmpty }
    }

    // MARK: Languages

    struct State: Equatable { var blockEnd: String? }

    struct Language {
        var keywords: Set<String>
        var lineComments: [String] = []
        var block: (open: String, close: String)?
        var quotes: Set<Character> = ["\"", "'"]
        var caseInsensitive = false
        var attributes = false          // @decorator / @Attribute
        var directives = false          // #include / #if at line start
        var markup = false              // <tag attr="…">
        var types = true                // Capitalised identifiers are types

        static func forPath(_ path: String) -> Language? {
            let name = (path as NSString).lastPathComponent.lowercased()
            if name == "dockerfile" { return table["docker"] }
            if name == "makefile" { return table["make"] }
            let ext = (name as NSString).pathExtension
            guard let key = extensionMap[ext] else { return nil }
            return table[key]
        }

        static let extensionMap: [String: String] = [
            "swift": "swift", "js": "js", "jsx": "js", "mjs": "js", "cjs": "js", "ts": "ts", "tsx": "ts",
            "py": "py", "go": "go", "rs": "rust", "c": "c", "h": "c", "m": "c", "mm": "c", "cc": "c",
            "cpp": "c", "cxx": "c", "hpp": "c", "cs": "java", "java": "java", "kt": "java", "kts": "java",
            "scala": "java", "dart": "java", "php": "php", "rb": "ruby", "sh": "sh", "bash": "sh", "zsh": "sh",
            "fish": "sh", "json": "json", "jsonc": "json", "yml": "yaml", "yaml": "yaml", "toml": "yaml",
            "ini": "yaml", "conf": "yaml", "html": "html", "htm": "html", "xml": "html", "svg": "html",
            "plist": "html", "css": "css", "scss": "css", "less": "css", "sql": "sql", "lua": "lua",
            "mk": "make", "gradle": "java",
        ]

        static let table: [String: Language] = {
            let cLike = ["//"]
            let slashBlock: (String, String) = ("/*", "*/")
            return [
                "swift": Language(keywords: [
                    "let", "var", "func", "class", "struct", "enum", "protocol", "extension", "import", "return",
                    "if", "else", "guard", "switch", "case", "default", "for", "while", "repeat", "in", "do",
                    "try", "catch", "throw", "throws", "rethrows", "async", "await", "public", "private",
                    "fileprivate", "internal", "open", "static", "final", "override", "init", "deinit", "self",
                    "Self", "super", "nil", "true", "false", "where", "as", "is", "break", "continue", "defer",
                    "typealias", "associatedtype", "some", "any", "inout", "mutating", "nonmutating", "lazy",
                    "weak", "unowned", "actor", "nonisolated", "subscript", "operator", "get", "set", "willSet",
                    "didSet", "fallthrough", "macro"],
                    lineComments: cLike, block: slashBlock, attributes: true, directives: true),
                "js": Language(keywords: [
                    "const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch",
                    "case", "default", "break", "continue", "new", "delete", "typeof", "instanceof", "in", "of",
                    "class", "extends", "super", "this", "import", "export", "from", "as", "async", "await",
                    "yield", "try", "catch", "finally", "throw", "null", "undefined", "true", "false", "void",
                    "static", "get", "set"],
                    lineComments: cLike, block: slashBlock, quotes: ["\"", "'", "`"]),
                "ts": Language(keywords: [
                    "const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch",
                    "case", "default", "break", "continue", "new", "delete", "typeof", "instanceof", "in", "of",
                    "class", "extends", "implements", "interface", "type", "enum", "namespace", "declare",
                    "abstract", "readonly", "public", "private", "protected", "super", "this", "import", "export",
                    "from", "as", "async", "await", "yield", "try", "catch", "finally", "throw", "null",
                    "undefined", "true", "false", "void", "keyof", "satisfies", "static", "get", "set"],
                    lineComments: cLike, block: slashBlock, quotes: ["\"", "'", "`"], attributes: true),
                "py": Language(keywords: [
                    "def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or",
                    "is", "import", "from", "as", "with", "try", "except", "finally", "raise", "pass", "break",
                    "continue", "lambda", "yield", "global", "nonlocal", "assert", "del", "None", "True", "False",
                    "async", "await", "self", "cls", "match", "case"],
                    lineComments: ["#"], attributes: true),
                "go": Language(keywords: [
                    "func", "package", "import", "return", "if", "else", "for", "range", "switch", "case",
                    "default", "break", "continue", "go", "defer", "select", "chan", "map", "struct", "interface",
                    "type", "var", "const", "fallthrough", "goto", "nil", "true", "false", "iota"],
                    lineComments: cLike, block: slashBlock, quotes: ["\"", "'", "`"]),
                "rust": Language(keywords: [
                    "fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl", "type", "use", "mod",
                    "pub", "crate", "self", "Self", "super", "return", "if", "else", "match", "for", "while",
                    "loop", "in", "break", "continue", "as", "ref", "move", "where", "async", "await", "dyn",
                    "unsafe", "extern", "true", "false"],
                    lineComments: cLike, block: slashBlock, attributes: true),
                "c": Language(keywords: [
                    "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return",
                    "goto", "struct", "union", "enum", "typedef", "static", "extern", "const", "volatile", "inline",
                    "void", "int", "char", "short", "long", "float", "double", "unsigned", "signed", "bool",
                    "sizeof", "NULL", "nullptr", "true", "false", "class", "public", "private", "protected",
                    "template", "typename", "namespace", "using", "new", "delete", "virtual", "override", "this",
                    "auto", "constexpr", "@interface", "@implementation", "@end", "@property", "nil", "YES", "NO"],
                    lineComments: cLike, block: slashBlock, directives: true),
                "java": Language(keywords: [
                    "class", "interface", "enum", "extends", "implements", "public", "private", "protected",
                    "static", "final", "abstract", "void", "int", "long", "double", "float", "boolean", "char",
                    "byte", "short", "new", "return", "if", "else", "for", "while", "do", "switch", "case",
                    "default", "break", "continue", "try", "catch", "finally", "throw", "throws", "import",
                    "package", "this", "super", "null", "true", "false", "fun", "val", "var", "when", "object",
                    "override", "data", "sealed", "is", "in", "as", "namespace", "using", "async", "await"],
                    lineComments: cLike, block: slashBlock, attributes: true),
                "php": Language(keywords: [
                    "function", "class", "interface", "trait", "extends", "implements", "public", "private",
                    "protected", "static", "final", "abstract", "return", "if", "else", "elseif", "foreach", "for",
                    "while", "do", "switch", "case", "default", "break", "continue", "try", "catch", "finally",
                    "throw", "new", "use", "namespace", "echo", "null", "true", "false", "array", "fn", "match"],
                    lineComments: ["//", "#"], block: slashBlock),
                "ruby": Language(keywords: [
                    "def", "class", "module", "end", "if", "elsif", "else", "unless", "case", "when", "while",
                    "until", "for", "in", "do", "begin", "rescue", "ensure", "raise", "return", "yield", "self",
                    "super", "nil", "true", "false", "require", "include", "extend", "attr_accessor", "attr_reader",
                    "attr_writer", "and", "or", "not", "then", "lambda", "proc"],
                    lineComments: ["#"]),
                "sh": Language(keywords: [
                    "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in",
                    "function", "return", "exit", "export", "local", "readonly", "set", "unset", "source", "echo",
                    "cd", "true", "false"],
                    lineComments: ["#"], types: false),
                "json": Language(keywords: ["true", "false", "null"], quotes: ["\""], types: false),
                "yaml": Language(keywords: ["true", "false", "null", "yes", "no", "on", "off"],
                                 lineComments: ["#"], types: false),
                "html": Language(keywords: [], block: ("<!--", "-->"), markup: true, types: false),
                "css": Language(keywords: ["important", "inherit", "initial", "none", "auto"],
                                block: slashBlock, types: false),
                "sql": Language(keywords: [
                    "select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set",
                    "delete", "create", "table", "alter", "drop", "index", "join", "left", "right", "inner",
                    "outer", "on", "group", "by", "order", "having", "limit", "offset", "as", "distinct", "union",
                    "null", "is", "in", "like", "between", "case", "when", "then", "else", "end", "primary", "key",
                    "foreign", "references", "default", "constraint", "unique", "with", "returning"],
                    lineComments: ["--"], block: slashBlock, caseInsensitive: true, types: false),
                "lua": Language(keywords: [
                    "function", "local", "end", "if", "then", "else", "elseif", "for", "while", "do", "repeat",
                    "until", "return", "break", "in", "and", "or", "not", "nil", "true", "false"],
                    lineComments: ["--"], types: false),
                "make": Language(keywords: ["ifeq", "ifneq", "else", "endif", "include", "define", "endef"],
                                 lineComments: ["#"], types: false),
                "docker": Language(keywords: [
                    "from", "run", "cmd", "label", "expose", "env", "add", "copy", "entrypoint", "volume", "user",
                    "workdir", "arg", "onbuild", "stopsignal", "healthcheck", "shell", "as"],
                    lineComments: ["#"], caseInsensitive: true, types: false),
            ]
        }()
    }

    // MARK: Tokenizer

    /// Lines longer than this are left plain (minified bundles etc.).
    static let maxLineLength = 800

    static func tokenize(_ text: String, _ lang: Language, _ state: inout State) -> [SyntaxToken] {
        guard text.count <= maxLineLength else { return [] }
        let c = Array(text)
        var tokens: [SyntaxToken] = []
        var i = 0

        func matches(_ s: String, at index: Int) -> Bool {
            let sc = Array(s)
            guard index + sc.count <= c.count else { return false }
            for k in 0..<sc.count where c[index + k] != sc[k] { return false }
            return true
        }
        func isIdentStart(_ ch: Character) -> Bool { ch.isLetter || ch == "_" || ch == "$" }
        func isIdent(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber || ch == "_" || ch == "$" }

        // Continue a block comment from a previous line.
        if let end = state.blockEnd {
            var j = 0
            while j < c.count, !matches(end, at: j) { j += 1 }
            if j < c.count { j += end.count; state.blockEnd = nil }
            tokens.append(SyntaxToken(start: 0, end: min(j, c.count), kind: .comment))
            i = j
        }

        let firstNonSpace = c.firstIndex { $0 != " " && $0 != "\t" } ?? c.count

        while i < c.count {
            let ch = c[i]

            // Comments
            if lang.lineComments.contains(where: { matches($0, at: i) }) {
                tokens.append(SyntaxToken(start: i, end: c.count, kind: .comment))
                return tokens
            }
            if let block = lang.block, matches(block.open, at: i) {
                var j = i + block.open.count
                while j < c.count, !matches(block.close, at: j) { j += 1 }
                if j < c.count { j += block.close.count } else { state.blockEnd = block.close }
                tokens.append(SyntaxToken(start: i, end: min(j, c.count), kind: .comment))
                i = j
                continue
            }

            // Markup tags: <name attr="x"> and </name>
            if lang.markup, ch == "<", i + 1 < c.count, c[i + 1].isLetter || c[i + 1] == "/" || c[i + 1] == "?" || c[i + 1] == "!" {
                var j = i + 1
                while j < c.count, isIdent(c[j]) || c[j] == "/" || c[j] == "?" || c[j] == "!" || c[j] == "-" || c[j] == ":" { j += 1 }
                tokens.append(SyntaxToken(start: i, end: j, kind: .keyword))
                i = j
                continue
            }

            // Strings
            if lang.quotes.contains(ch) {
                var j = i + 1
                while j < c.count, c[j] != ch { j += c[j] == "\\" ? 2 : 1 }
                j = min(j + 1, c.count)
                tokens.append(SyntaxToken(start: i, end: j, kind: .string))
                i = j
                continue
            }

            // Attributes / directives
            if ch == "@", lang.attributes, i + 1 < c.count, isIdentStart(c[i + 1]) {
                var j = i + 1
                while j < c.count, isIdent(c[j]) || c[j] == "." { j += 1 }
                tokens.append(SyntaxToken(start: i, end: j, kind: .attribute))
                i = j
                continue
            }
            if ch == "#", lang.directives, i == firstNonSpace, i + 1 < c.count, isIdentStart(c[i + 1]) {
                var j = i + 1
                while j < c.count, isIdent(c[j]) { j += 1 }
                tokens.append(SyntaxToken(start: i, end: j, kind: .attribute))
                i = j
                continue
            }

            // Numbers
            if ch.isNumber, i == 0 || !isIdent(c[i - 1]) {
                var j = i + 1
                while j < c.count, c[j].isHexDigit || c[j] == "." || c[j] == "_" || c[j] == "x" || c[j] == "X" { j += 1 }
                if j < c.count, c[j].isLetter, !lang.markup { while j < c.count, isIdent(c[j]) { j += 1 } }
                tokens.append(SyntaxToken(start: i, end: j, kind: .number))
                i = j
                continue
            }

            // Identifiers
            if isIdentStart(ch) {
                var j = i + 1
                while j < c.count, isIdent(c[j]) || (lang.markup && (c[j] == "-" || c[j] == ":")) { j += 1 }
                let word = String(c[i..<j])
                let key = lang.caseInsensitive ? word.lowercased() : word
                var next = j
                while next < c.count, c[next] == " " { next += 1 }

                if lang.keywords.contains(key) {
                    tokens.append(SyntaxToken(start: i, end: j, kind: .keyword))
                } else if next < c.count, c[next] == "(", !lang.markup {
                    tokens.append(SyntaxToken(start: i, end: j, kind: .function))
                } else if lang.types, ch.isUppercase, word.count > 1, word.contains(where: \.isLowercase) {
                    tokens.append(SyntaxToken(start: i, end: j, kind: .type))
                }
                i = j
                continue
            }

            i += 1
        }
        return tokens
    }
}
