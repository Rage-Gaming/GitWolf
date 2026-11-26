namespace GitSync.Core;

// Ported from apple/Sources/GitSyncCore/SyntaxHighlighter.swift. A small, dependency-free
// tokenizer. It is intentionally approximate (no real parsing): diffs show fragments of files, so
// the goal is fast, stable colouring of keywords, strings, comments, numbers, types and calls.

public enum SyntaxKind { Keyword, Type, String, Comment, Number, Function, Attribute }

/// <summary>A highlighted span, as character offsets [Start, End) into the line's text.</summary>
public readonly record struct SyntaxToken(int Start, int End, SyntaxKind Kind);

public static class SyntaxHighlighter
{
    /// <summary>Tokens for every line of a diff, keyed by `DiffLine.Id`. Empty for unknown file types.</summary>
    public static Dictionary<int, List<SyntaxToken>> Tokens(FileDiff diff, string path)
    {
        var language = Language.ForPath(path);
        if (language is null) return [];

        var result = new Dictionary<int, List<SyntaxToken>>();
        // Block-comment state is tracked separately for the old and new side of the diff.
        var oldState = new State();
        var newState = new State();

        foreach (var line in diff.Lines)
        {
            switch (line.Kind)
            {
                case DiffLineKind.HunkHeader:
                    oldState = new State();
                    newState = new State();
                    break;
                case DiffLineKind.Note:
                    break;
                case DiffLineKind.Deletion:
                    result[line.Id] = Tokenize(line.Text, language, ref oldState);
                    break;
                case DiffLineKind.Addition:
                    result[line.Id] = Tokenize(line.Text, language, ref newState);
                    break;
                case DiffLineKind.Context:
                    result[line.Id] = Tokenize(line.Text, language, ref newState);
                    oldState = newState;
                    break;
            }
        }

        foreach (var key in result.Where(kv => kv.Value.Count == 0).Select(kv => kv.Key).ToList())
            result.Remove(key);
        return result;
    }

    // MARK: Languages

    public struct State : IEquatable<State>
    {
        public string? BlockEnd;
        public readonly bool Equals(State other) => BlockEnd == other.BlockEnd;
        public override readonly bool Equals(object? obj) => obj is State s && Equals(s);
        public override readonly int GetHashCode() => BlockEnd?.GetHashCode() ?? 0;
    }

    public sealed class Language
    {
        public required HashSet<string> Keywords;
        public List<string> LineComments = [];
        public (string Open, string Close)? Block;
        public HashSet<char> Quotes = ['"', '\''];
        public bool CaseInsensitive;
        public bool Attributes;  // @decorator / @Attribute
        public bool Directives;  // #include / #if at line start
        public bool Markup;      // <tag attr="…">
        public bool Types = true; // Capitalised identifiers are types

        public static Language? ForPath(string path)
        {
            var name = System.IO.Path.GetFileName(path).ToLowerInvariant();
            if (name == "dockerfile") return Table["docker"];
            if (name == "makefile") return Table["make"];
            var ext = System.IO.Path.GetExtension(name).TrimStart('.');
            return ExtensionMap.TryGetValue(ext, out var key) ? Table[key] : null;
        }

        public static readonly Dictionary<string, string> ExtensionMap = new()
        {
            ["swift"] = "swift", ["js"] = "js", ["jsx"] = "js", ["mjs"] = "js", ["cjs"] = "js", ["ts"] = "ts", ["tsx"] = "ts",
            ["py"] = "py", ["go"] = "go", ["rs"] = "rust", ["c"] = "c", ["h"] = "c", ["m"] = "c", ["mm"] = "c", ["cc"] = "c",
            ["cpp"] = "c", ["cxx"] = "c", ["hpp"] = "c", ["cs"] = "java", ["java"] = "java", ["kt"] = "java", ["kts"] = "java",
            ["scala"] = "java", ["dart"] = "java", ["php"] = "php", ["rb"] = "ruby", ["sh"] = "sh", ["bash"] = "sh", ["zsh"] = "sh",
            ["fish"] = "sh", ["json"] = "json", ["jsonc"] = "json", ["yml"] = "yaml", ["yaml"] = "yaml", ["toml"] = "yaml",
            ["ini"] = "yaml", ["conf"] = "yaml", ["html"] = "html", ["htm"] = "html", ["xml"] = "html", ["svg"] = "html",
            ["plist"] = "html", ["css"] = "css", ["scss"] = "css", ["less"] = "css", ["sql"] = "sql", ["lua"] = "lua",
            ["mk"] = "make", ["gradle"] = "java",
        };

        public static readonly Dictionary<string, Language> Table = BuildTable();

        private static Dictionary<string, Language> BuildTable()
        {
            var cLike = new List<string> { "//" };
            var slashBlock = ("/*", "*/");
            return new Dictionary<string, Language>
            {
                ["swift"] = new()
                {
                    Keywords = [
                        "let", "var", "func", "class", "struct", "enum", "protocol", "extension", "import", "return",
                        "if", "else", "guard", "switch", "case", "default", "for", "while", "repeat", "in", "do",
                        "try", "catch", "throw", "throws", "rethrows", "async", "await", "public", "private",
                        "fileprivate", "internal", "open", "static", "final", "override", "init", "deinit", "self",
                        "Self", "super", "nil", "true", "false", "where", "as", "is", "break", "continue", "defer",
                        "typealias", "associatedtype", "some", "any", "inout", "mutating", "nonmutating", "lazy",
                        "weak", "unowned", "actor", "nonisolated", "subscript", "operator", "get", "set", "willSet",
                        "didSet", "fallthrough", "macro"],
                    LineComments = cLike, Block = slashBlock, Attributes = true, Directives = true,
                },
                ["js"] = new()
                {
                    Keywords = [
                        "const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch",
                        "case", "default", "break", "continue", "new", "delete", "typeof", "instanceof", "in", "of",
                        "class", "extends", "super", "this", "import", "export", "from", "as", "async", "await",
                        "yield", "try", "catch", "finally", "throw", "null", "undefined", "true", "false", "void",
                        "static", "get", "set"],
                    LineComments = cLike, Block = slashBlock, Quotes = ['"', '\'', '`'],
                },
                ["ts"] = new()
                {
                    Keywords = [
                        "const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch",
                        "case", "default", "break", "continue", "new", "delete", "typeof", "instanceof", "in", "of",
                        "class", "extends", "implements", "interface", "type", "enum", "namespace", "declare",
                        "abstract", "readonly", "public", "private", "protected", "super", "this", "import", "export",
                        "from", "as", "async", "await", "yield", "try", "catch", "finally", "throw", "null",
                        "undefined", "true", "false", "void", "keyof", "satisfies", "static", "get", "set"],
                    LineComments = cLike, Block = slashBlock, Quotes = ['"', '\'', '`'], Attributes = true,
                },
                ["py"] = new()
                {
                    Keywords = [
                        "def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or",
                        "is", "import", "from", "as", "with", "try", "except", "finally", "raise", "pass", "break",
                        "continue", "lambda", "yield", "global", "nonlocal", "assert", "del", "None", "True", "False",
                        "async", "await", "self", "cls", "match", "case"],
                    LineComments = ["#"], Attributes = true,
                },
                ["go"] = new()
                {
                    Keywords = [
                        "func", "package", "import", "return", "if", "else", "for", "range", "switch", "case",
                        "default", "break", "continue", "go", "defer", "select", "chan", "map", "struct", "interface",
                        "type", "var", "const", "fallthrough", "goto", "nil", "true", "false", "iota"],
                    LineComments = cLike, Block = slashBlock, Quotes = ['"', '\'', '`'],
                },
                ["rust"] = new()
                {
                    Keywords = [
                        "fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl", "type", "use", "mod",
                        "pub", "crate", "self", "Self", "super", "return", "if", "else", "match", "for", "while",
                        "loop", "in", "break", "continue", "as", "ref", "move", "where", "async", "await", "dyn",
                        "unsafe", "extern", "true", "false"],
                    LineComments = cLike, Block = slashBlock, Attributes = true,
                },
                ["c"] = new()
                {
                    Keywords = [
                        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return",
                        "goto", "struct", "union", "enum", "typedef", "static", "extern", "const", "volatile", "inline",
                        "void", "int", "char", "short", "long", "float", "double", "unsigned", "signed", "bool",
                        "sizeof", "NULL", "nullptr", "true", "false", "class", "public", "private", "protected",
                        "template", "typename", "namespace", "using", "new", "delete", "virtual", "override", "this",
                        "auto", "constexpr", "@interface", "@implementation", "@end", "@property", "nil", "YES", "NO"],
                    LineComments = cLike, Block = slashBlock, Directives = true,
                },
                ["java"] = new()
                {
                    Keywords = [
                        "class", "interface", "enum", "extends", "implements", "public", "private", "protected",
                        "static", "final", "abstract", "void", "int", "long", "double", "float", "boolean", "char",
                        "byte", "short", "new", "return", "if", "else", "for", "while", "do", "switch", "case",
                        "default", "break", "continue", "try", "catch", "finally", "throw", "throws", "import",
                        "package", "this", "super", "null", "true", "false", "fun", "val", "var", "when", "object",
                        "override", "data", "sealed", "is", "in", "as", "namespace", "using", "async", "await"],
                    LineComments = cLike, Block = slashBlock, Attributes = true,
                },
                ["php"] = new()
                {
                    Keywords = [
                        "function", "class", "interface", "trait", "extends", "implements", "public", "private",
                        "protected", "static", "final", "abstract", "return", "if", "else", "elseif", "foreach", "for",
                        "while", "do", "switch", "case", "default", "break", "continue", "try", "catch", "finally",
                        "throw", "new", "use", "namespace", "echo", "null", "true", "false", "array", "fn", "match"],
                    LineComments = ["//", "#"], Block = slashBlock,
                },
                ["ruby"] = new()
                {
                    Keywords = [
                        "def", "class", "module", "end", "if", "elsif", "else", "unless", "case", "when", "while",
                        "until", "for", "in", "do", "begin", "rescue", "ensure", "raise", "return", "yield", "self",
                        "super", "nil", "true", "false", "require", "include", "extend", "attr_accessor", "attr_reader",
                        "attr_writer", "and", "or", "not", "then", "lambda", "proc"],
                    LineComments = ["#"],
                },
                ["sh"] = new()
                {
                    Keywords = [
                        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in",
                        "function", "return", "exit", "export", "local", "readonly", "set", "unset", "source", "echo",
                        "cd", "true", "false"],
                    LineComments = ["#"], Types = false,
                },
                ["json"] = new() { Keywords = ["true", "false", "null"], Quotes = ['"'], Types = false },
                ["yaml"] = new()
                {
                    Keywords = ["true", "false", "null", "yes", "no", "on", "off"],
                    LineComments = ["#"], Types = false,
                },
                ["html"] = new() { Keywords = [], Block = ("<!--", "-->"), Markup = true, Types = false },
                ["css"] = new()
                {
                    Keywords = ["important", "inherit", "initial", "none", "auto"],
                    Block = slashBlock, Types = false,
                },
                ["sql"] = new()
                {
                    Keywords = [
                        "select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set",
                        "delete", "create", "table", "alter", "drop", "index", "join", "left", "right", "inner",
                        "outer", "on", "group", "by", "order", "having", "limit", "offset", "as", "distinct", "union",
                        "null", "is", "in", "like", "between", "case", "when", "then", "else", "end", "primary", "key",
                        "foreign", "references", "default", "constraint", "unique", "with", "returning"],
                    LineComments = ["--"], Block = slashBlock, CaseInsensitive = true, Types = false,
                },
                ["lua"] = new()
                {
                    Keywords = [
                        "function", "local", "end", "if", "then", "else", "elseif", "for", "while", "do", "repeat",
                        "until", "return", "break", "in", "and", "or", "not", "nil", "true", "false"],
                    LineComments = ["--"], Types = false,
                },
                ["make"] = new()
                {
                    Keywords = ["ifeq", "ifneq", "else", "endif", "include", "define", "endef"],
                    LineComments = ["#"], Types = false,
                },
                ["docker"] = new()
                {
                    Keywords = [
                        "from", "run", "cmd", "label", "expose", "env", "add", "copy", "entrypoint", "volume", "user",
                        "workdir", "arg", "onbuild", "stopsignal", "healthcheck", "shell", "as"],
                    LineComments = ["#"], CaseInsensitive = true, Types = false,
                },
            };
        }
    }

    // MARK: Tokenizer

    /// <summary>Lines longer than this are left plain (minified bundles etc.).</summary>
    public const int MaxLineLength = 800;

    public static List<SyntaxToken> Tokenize(string text, Language lang, ref State state)
    {
        if (text.Length > MaxLineLength) return [];
        var c = text;
        var tokens = new List<SyntaxToken>();
        int i = 0;

        bool Matches(string s, int index)
        {
            if (index + s.Length > c.Length) return false;
            for (int k = 0; k < s.Length; k++) if (c[index + k] != s[k]) return false;
            return true;
        }
        static bool IsIdentStart(char ch) => char.IsLetter(ch) || ch == '_' || ch == '$';
        static bool IsIdent(char ch) => char.IsLetter(ch) || char.IsDigit(ch) || ch == '_' || ch == '$';
        static bool IsHexDigit(char ch) => char.IsDigit(ch) || (ch is >= 'a' and <= 'f') || (ch is >= 'A' and <= 'F');

        // Continue a block comment from a previous line.
        if (state.BlockEnd is { } end)
        {
            int j = 0;
            while (j < c.Length && !Matches(end, j)) j++;
            if (j < c.Length) { j += end.Length; state.BlockEnd = null; }
            tokens.Add(new SyntaxToken(0, Math.Min(j, c.Length), SyntaxKind.Comment));
            i = j;
        }

        int firstNonSpace = 0;
        while (firstNonSpace < c.Length && (c[firstNonSpace] == ' ' || c[firstNonSpace] == '\t')) firstNonSpace++;

        while (i < c.Length)
        {
            var ch = c[i];

            // Comments
            if (lang.LineComments.Any(lc => Matches(lc, i)))
            {
                tokens.Add(new SyntaxToken(i, c.Length, SyntaxKind.Comment));
                return tokens;
            }
            if (lang.Block is { } block && Matches(block.Open, i))
            {
                int j = i + block.Open.Length;
                while (j < c.Length && !Matches(block.Close, j)) j++;
                if (j < c.Length) j += block.Close.Length; else state.BlockEnd = block.Close;
                tokens.Add(new SyntaxToken(i, Math.Min(j, c.Length), SyntaxKind.Comment));
                i = j;
                continue;
            }

            // Markup tags: <name attr="x"> and </name>
            if (lang.Markup && ch == '<' && i + 1 < c.Length
                && (char.IsLetter(c[i + 1]) || c[i + 1] == '/' || c[i + 1] == '?' || c[i + 1] == '!'))
            {
                int j = i + 1;
                while (j < c.Length && (IsIdent(c[j]) || c[j] is '/' or '?' or '!' or '-' or ':')) j++;
                tokens.Add(new SyntaxToken(i, j, SyntaxKind.Keyword));
                i = j;
                continue;
            }

            // Strings
            if (lang.Quotes.Contains(ch))
            {
                int j = i + 1;
                while (j < c.Length && c[j] != ch) j += c[j] == '\\' ? 2 : 1;
                j = Math.Min(j + 1, c.Length);
                tokens.Add(new SyntaxToken(i, j, SyntaxKind.String));
                i = j;
                continue;
            }

            // Attributes / directives
            if (ch == '@' && lang.Attributes && i + 1 < c.Length && IsIdentStart(c[i + 1]))
            {
                int j = i + 1;
                while (j < c.Length && (IsIdent(c[j]) || c[j] == '.')) j++;
                tokens.Add(new SyntaxToken(i, j, SyntaxKind.Attribute));
                i = j;
                continue;
            }
            if (ch == '#' && lang.Directives && i == firstNonSpace && i + 1 < c.Length && IsIdentStart(c[i + 1]))
            {
                int j = i + 1;
                while (j < c.Length && IsIdent(c[j])) j++;
                tokens.Add(new SyntaxToken(i, j, SyntaxKind.Attribute));
                i = j;
                continue;
            }

            // Numbers
            if (char.IsDigit(ch) && (i == 0 || !IsIdent(c[i - 1])))
            {
                int j = i + 1;
                while (j < c.Length && (IsHexDigit(c[j]) || c[j] is '.' or '_' or 'x' or 'X')) j++;
                if (j < c.Length && char.IsLetter(c[j]) && !lang.Markup) while (j < c.Length && IsIdent(c[j])) j++;
                tokens.Add(new SyntaxToken(i, j, SyntaxKind.Number));
                i = j;
                continue;
            }

            // Identifiers
            if (IsIdentStart(ch))
            {
                int j = i + 1;
                while (j < c.Length && (IsIdent(c[j]) || (lang.Markup && c[j] is '-' or ':'))) j++;
                var word = c[i..j];
                var key = lang.CaseInsensitive ? word.ToLowerInvariant() : word;
                int next = j;
                while (next < c.Length && c[next] == ' ') next++;

                if (lang.Keywords.Contains(key))
                {
                    tokens.Add(new SyntaxToken(i, j, SyntaxKind.Keyword));
                }
                else if (next < c.Length && c[next] == '(' && !lang.Markup)
                {
                    tokens.Add(new SyntaxToken(i, j, SyntaxKind.Function));
                }
                else if (lang.Types && char.IsUpper(ch) && word.Length > 1 && word.Any(char.IsLower))
                {
                    tokens.Add(new SyntaxToken(i, j, SyntaxKind.Type));
                }
                i = j;
                continue;
            }

            i++;
        }
        return tokens;
    }
}
