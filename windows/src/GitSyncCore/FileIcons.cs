namespace GitSync.Core;

public enum IconGlyph
{
    /// <summary>Short letters on a coloured rounded square, e.g. "TS".</summary>
    Letters,
    /// <summary>A symbol, named as in SF Symbols; each platform draws the nearest icon.</summary>
    Symbol,
    /// <summary>The React atom: three ellipses and a dot.</summary>
    React,
    /// <summary>A folder in the brand colour, with an optional small symbol on it.</summary>
    Folder,
}

/// <summary>Which icon to show. This is data only; the app draws it (flat colour, no gradients).</summary>
/// <param name="Value">The letters, the symbol name, or the symbol on a folder.</param>
/// <param name="Color">Brand colour as 0xRRGGBB.</param>
/// <param name="DarkText">Use dark text on the tile, for light colours such as JavaScript yellow.</param>
public sealed record FileIcon(string Name, IconGlyph Glyph, string? Value, uint Color, bool DarkText = false);

/// <summary>Icons for files, folders and branches. Ported from FileIcons.swift.</summary>
public static class FileIcons
{
    private static readonly FileIcon Generic = Symbol("File", "doc", 0x8E8E93);
    private static readonly FileIcon Env = Symbol("Environment", "key.fill", 0xECD53F);
    private static readonly FileIcon License = Symbol("License", "checkmark.seal.fill", 0xD0B64B);
    private static readonly FileIcon Minified = Symbol("Minified", "arrow.down.right.and.arrow.up.left", 0x8E8E93);
    private static readonly FileIcon React = new("React", IconGlyph.React, null, 0x61DAFB);
    private static readonly FileIcon BranchDefault = Branch("Branch", "arrow.triangle.branch", 0x8E8E93);

    private static readonly HashSet<string> Containers =
    [
        "node_modules", "vendor", "third_party", "pods", ".github", ".gitlab", ".circleci", ".git",
        "dist", "build", "out", "target", ".build", "deriveddata"
    ];

    // Declared after the icons above: static fields are initialised in order.
    public static IReadOnlyDictionary<string, FileIcon> Names { get; } = new Dictionary<string, FileIcon>
    {
        ["package.json"] = Letters("npm", "npm", 0xCB3837),
        ["package-lock.json"] = Symbol("Lockfile", "lock.fill", 0xCB3837),
        ["yarn.lock"] = Symbol("Lockfile", "lock.fill", 0x2C8EBB),
        ["pnpm-lock.yaml"] = Symbol("Lockfile", "lock.fill", 0xF69220),
        ["cargo.toml"] = Letters("Cargo", "RS", 0xDEA584, dark: true),
        ["cargo.lock"] = Symbol("Lockfile", "lock.fill", 0xDEA584),
        ["go.mod"] = Letters("Go", "GO", 0x00ADD8),
        ["go.sum"] = Symbol("Lockfile", "lock.fill", 0x00ADD8),
        ["package.swift"] = Symbol("Swift package", "swift", 0xF05138),
        ["package.resolved"] = Symbol("Lockfile", "lock.fill", 0xF05138),
        ["tsconfig.json"] = Letters("TypeScript config", "TS", 0x3178C6),
        ["jsconfig.json"] = Letters("JavaScript config", "JS", 0xF7DF1E, dark: true),
        ["gemfile"] = Letters("Ruby", "RB", 0xCC342D),
        ["gemfile.lock"] = Symbol("Lockfile", "lock.fill", 0xCC342D),
        ["podfile"] = Letters("CocoaPods", "CP", 0xEE3322),
        ["podfile.lock"] = Symbol("Lockfile", "lock.fill", 0xEE3322),
        ["requirements.txt"] = Letters("Python", "PY", 0x3776AB),
        ["pyproject.toml"] = Letters("Python", "PY", 0x3776AB),
        ["pipfile"] = Letters("Python", "PY", 0x3776AB),
        ["dockerfile"] = Symbol("Docker", "shippingbox.fill", 0x2496ED),
        ["docker-compose.yml"] = Symbol("Docker", "shippingbox.fill", 0x2496ED),
        ["docker-compose.yaml"] = Symbol("Docker", "shippingbox.fill", 0x2496ED),
        [".dockerignore"] = Symbol("Docker", "shippingbox.fill", 0x2496ED),
        ["makefile"] = Symbol("Makefile", "wrench.and.screwdriver.fill", 0x6D8086),
        ["cmakelists.txt"] = Symbol("CMake", "wrench.and.screwdriver.fill", 0x064F8C),
        ["readme.md"] = Symbol("Readme", "book.fill", 0x42A5F5),
        [".gitignore"] = Symbol("Git", "arrow.triangle.branch", 0xF05032),
        [".gitattributes"] = Symbol("Git", "arrow.triangle.branch", 0xF05032),
        [".gitmodules"] = Symbol("Git", "arrow.triangle.branch", 0xF05032),
        [".gitkeep"] = Symbol("Git", "arrow.triangle.branch", 0xF05032),
        [".editorconfig"] = Symbol("Editor config", "gearshape.fill", 0x8E8E93),
        [".eslintrc"] = Letters("ESLint", "ES", 0x4B32C3),
        [".prettierrc"] = Letters("Prettier", "PR", 0x56B3B4),
        [".ds_store"] = Symbol("macOS", "apple.logo", 0x8E8E93),
        ["info.plist"] = Letters("XML", "</>", 0xE37933),
    };

    public static IReadOnlyDictionary<string, FileIcon> Extensions { get; } = BuildExtensions();
    public static IReadOnlyDictionary<string, FileIcon> Folders { get; } = BuildFolders();
    public static IReadOnlyDictionary<string, FileIcon> BranchNames { get; } = BuildBranchNames();
    public static IReadOnlyDictionary<string, FileIcon> BranchPrefixes { get; } = BuildBranchPrefixes();

    /// <summary>The icon for a path (only the file name matters).</summary>
    public static FileIcon ForPath(string path)
    {
        var lower = path[(path.TrimEnd('/').LastIndexOf('/') + 1)..].TrimEnd('/').ToLowerInvariant();
        if (Names.TryGetValue(lower, out var byName)) return byName;
        if (StartsWith(lower, ".env")) return Env;
        if (StartsWith(lower, "readme")) return Names["readme.md"];
        if (StartsWith(lower, "license") || StartsWith(lower, "licence") || lower == "copying") return License;
        if (StartsWith(lower, "dockerfile")) return Names["dockerfile"];
        // Compound extensions first, then the last one.
        if (EndsWith(lower, ".d.ts")) return Extensions["d.ts"];
        if (EndsWith(lower, ".min.js") || EndsWith(lower, ".min.css")) return Minified;
        // A leading dot names a hidden file; it doesn't start an extension.
        var dot = lower.LastIndexOf('.');
        return dot > 0 && Extensions.TryGetValue(lower[(dot + 1)..], out var icon) ? icon : Generic;
    }

    /// <summary>The icon for a folder, by its own name.</summary>
    public static FileIcon FolderNamed(string name) =>
        Folders.TryGetValue(name.ToLowerInvariant(), out var icon) ? icon : Folder("Folder", null, 0x6FA8DC);

    /// <summary>The icon for the folder that contains <paramref name="path"/>; null at the top level.</summary>
    public static FileIcon? FolderContaining(string path)
    {
        var parts = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2) return null;
        var folders = parts[..^1].Select(p => p.ToLowerInvariant()).ToList();
        var last = folders[^1];
        if (Folders.ContainsKey(last)) return FolderNamed(last);
        // Inside a dependency, CI or build folder, everything below it keeps that folder's look.
        return FolderNamed(folders.LastOrDefault(Containers.Contains) ?? last);
    }

    /// <summary>The icon for a branch, chosen from its name.</summary>
    public static FileIcon BranchNamed(string name)
    {
        var lower = name.ToLowerInvariant();
        if (BranchNames.TryGetValue(lower, out var exact)) return exact;
        var end = lower.AsSpan().IndexOfAny('/', '-', '_');
        var first = end < 0 ? lower : lower[..end];
        if (BranchPrefixes.TryGetValue(first, out var byPrefix)) return byPrefix;
        // `123-fix-login` looks like an issue branch.
        return first.Length > 0 && first.All(char.IsDigit) ? BranchPrefixes["issue"] : BranchDefault;
    }

    private static bool StartsWith(string text, string prefix) => text.StartsWith(prefix, StringComparison.Ordinal);
    private static bool EndsWith(string text, string suffix) => text.EndsWith(suffix, StringComparison.Ordinal);

    private static FileIcon Letters(string name, string text, uint color, bool dark = false) =>
        new(name, IconGlyph.Letters, text, color, dark);
    private static FileIcon Symbol(string name, string symbol, uint color) => new(name, IconGlyph.Symbol, symbol, color);
    private static FileIcon Folder(string name, string? inner, uint color) => new(name, IconGlyph.Folder, inner, color);
    private static FileIcon Branch(string name, string symbol, uint color) => Symbol(name, symbol, color);

    private static Dictionary<string, FileIcon> Build(Action<Action<string[], FileIcon>> fill)
    {
        var map = new Dictionary<string, FileIcon>();
        fill((keys, icon) =>
        {
            foreach (var key in keys) map[key] = icon;
        });
        return map;
    }

    private static Dictionary<string, FileIcon> BuildFolders() => Build(Add =>
    {
        Add(["src", "source", "sources"], Folder("Source", "chevron.left.forwardslash.chevron.right", 0x42A5F5));
        Add(["lib", "libs", "library", "libraries"], Folder("Library", "books.vertical.fill", 0x8D6E63));
        Add(["docs", "doc", "documentation"], Folder("Docs", "book.fill", 0x4DB6AC));
        Add(["test", "tests", "__tests__", "spec", "specs"], Folder("Tests", "checkmark", 0x66BB6A));
        Add(["assets", "static", "resources", "res"], Folder("Assets", "photo.fill", 0xAB47BC));
        Add(["images", "img", "icons", "media"], Folder("Images", "photo.fill", 0x9575CD));
        Add(["public", "www", "web"], Folder("Public", "globe", 0x26C6DA));
        Add(["components", "views", "ui"], Folder("Components", "square.grid.2x2.fill", 0x29B6F6));
        Add(["scripts", "script", "tools", "bin"], Folder("Scripts", "terminal.fill", 0x7CB342));
        Add(["config", "configs", "conf", "settings"], Folder("Config", "gearshape.fill", 0x9E9E9E));
        Add([".github", ".gitlab", ".circleci"], Folder("CI", "arrow.triangle.branch", 0xF05032));
        Add([".git"], Folder("Git", "arrow.triangle.branch", 0xF05032));
        Add([".vscode", ".idea", ".xcode"], Folder("Editor", "wrench.and.screwdriver.fill", 0x1E88E5));
        Add(["node_modules", "vendor", "third_party", "pods", "packages"], Folder("Dependencies", "shippingbox.fill", 0x8BC34A));
        Add(["build", "dist", "out", "target", "release", "debug", ".build", "deriveddata"], Folder("Build output", "hammer.fill", 0xFF9800));
        Add(["api", "routes", "controllers", "server"], Folder("API", "network", 0xEF5350));
        Add(["models", "model", "db", "database", "migrations"], Folder("Data", "cylinder.split.1x2.fill", 0x26A69A));
        Add(["styles", "css", "themes"], Folder("Styles", "paintpalette.fill", 0xEC407A));
        Add(["utils", "util", "helpers", "common", "shared", "core"], Folder("Shared", "wrench.fill", 0x78909C));
        Add(["docker", ".docker"], Folder("Docker", "shippingbox.fill", 0x2496ED));
        Add(["fonts"], Folder("Fonts", "textformat", 0x8E8E93));
        Add(["hooks"], Folder("Hooks", "link", 0x7E57C2));
        Add(["types", "typings", "interfaces"], Folder("Types", "t.square.fill", 0x3178C6));
        Add(["localization", "locales", "i18n", "l10n"], Folder("Localization", "character.bubble.fill", 0x5C6BC0));
        Add(["examples", "example", "samples", "demo"], Folder("Examples", "lightbulb.fill", 0xFFCA28));
    });

    private static Dictionary<string, FileIcon> BuildBranchNames() => Build(Add =>
    {
        Add(["main", "master", "trunk"], Branch("Main branch", "star.fill", 0x42A5F5));
        Add(["develop", "dev", "development", "next"], Branch("Development", "hammer.fill", 0xAB47BC));
        Add(["staging", "stage", "preprod"], Branch("Staging", "flag.fill", 0xFF9800));
        Add(["production", "prod", "live"], Branch("Production", "bolt.shield.fill", 0xE53935));
    });

    private static Dictionary<string, FileIcon> BuildBranchPrefixes() => Build(Add =>
    {
        Add(["feature", "feat", "features"], Branch("Feature", "sparkles", 0x26A69A));
        Add(["fix", "bugfix", "bug"], Branch("Bug fix", "ladybug.fill", 0xE53935));
        Add(["hotfix", "urgent"], Branch("Hotfix", "flame.fill", 0xFF7043));
        Add(["release", "releases", "rc", "v"], Branch("Release", "shippingbox.fill", 0x7E57C2));
        Add(["chore", "build", "ci", "ops"], Branch("Chore", "wrench.and.screwdriver.fill", 0x78909C));
        Add(["docs", "doc", "documentation"], Branch("Docs", "book.fill", 0x4DB6AC));
        Add(["test", "tests", "testing"], Branch("Tests", "checkmark.seal.fill", 0x66BB6A));
        Add(["refactor", "cleanup", "tidy"], Branch("Refactor", "arrow.triangle.2.circlepath", 0x5C6BC0));
        Add(["perf", "performance", "speed"], Branch("Performance", "bolt.fill", 0xFFB300));
        Add(["style", "ui", "design", "theme"], Branch("Design", "paintpalette.fill", 0xEC407A));
        Add(["wip", "experiment", "spike", "poc", "tmp", "temp", "try"], Branch("Experiment", "testtube.2", 0x9C27B0));
        Add(["revert"], Branch("Revert", "arrow.uturn.backward.circle.fill", 0xEF5350));
        Add(["dependabot", "renovate", "deps", "bump"], Branch("Dependencies", "arrow.down.circle.fill", 0x8BC34A));
        Add(["pr", "pull", "review", "mr"], Branch("Pull request", "arrow.triangle.pull", 0x29B6F6));
        Add(["issue", "issues", "ticket"], Branch("Issue", "smallcircle.filled.circle", 0x66BB6A));
    });

    private static Dictionary<string, FileIcon> BuildExtensions() => Build(Add =>
    {
        Add(["tsx", "jsx"], React);
        Add(["ts", "mts", "cts"], Letters("TypeScript", "TS", 0x3178C6));
        Add(["d.ts"], Letters("TypeScript declarations", "TS", 0x3178C6));
        Add(["js", "mjs", "cjs"], Letters("JavaScript", "JS", 0xF7DF1E, dark: true));
        Add(["swift"], Symbol("Swift", "swift", 0xF05138));
        Add(["py", "pyw", "pyi"], Letters("Python", "PY", 0x3776AB));
        Add(["go"], Letters("Go", "GO", 0x00ADD8));
        Add(["rs"], Letters("Rust", "RS", 0xDEA584, dark: true));
        Add(["java"], Letters("Java", "J", 0xE76F00));
        Add(["kt", "kts"], Letters("Kotlin", "KT", 0x7F52FF));
        Add(["c", "h"], Letters("C", "C", 0x5C6BC0));
        Add(["cpp", "cc", "cxx", "hpp", "hh", "hxx"], Letters("C++", "C+", 0x00599C));
        Add(["m", "mm"], Letters("Objective-C", "OC", 0x438EFF));
        Add(["cs"], Letters("C#", "C#", 0x68217A));
        Add(["rb", "gemspec"], Letters("Ruby", "RB", 0xCC342D));
        Add(["php"], Letters("PHP", "PHP", 0x777BB4));
        Add(["dart"], Letters("Dart", "DA", 0x0175C2));
        Add(["lua"], Letters("Lua", "LU", 0x000080));
        Add(["scala"], Letters("Scala", "SC", 0xDC322F));
        Add(["ex", "exs"], Letters("Elixir", "EX", 0x6E4A7E));
        Add(["hs"], Letters("Haskell", "HS", 0x5D4F85));
        Add(["zig"], Letters("Zig", "ZG", 0xF7A41D, dark: true));
        Add(["vue"], Letters("Vue", "V", 0x42B883));
        Add(["svelte"], Letters("Svelte", "S", 0xFF3E00));
        Add(["html", "htm"], Letters("HTML", "<>", 0xE44D26));
        Add(["css"], Letters("CSS", "CSS", 0x1572B6));
        Add(["scss", "sass"], Letters("Sass", "SC", 0xCD6799));
        Add(["less"], Letters("Less", "LE", 0x1D365D));
        Add(["json", "jsonc", "json5"], Letters("JSON", "{}", 0xCBA02A, dark: true));
        Add(["yml", "yaml"], Letters("YAML", "YML", 0xCB171E));
        Add(["toml"], Letters("TOML", "TML", 0x9C4221));
        Add(["xml", "plist", "svg"], Letters("XML", "</>", 0xE37933));
        Add(["md", "markdown", "mdx"], Letters("Markdown", "M↓", 0x519ABA));
        Add(["txt", "text", "log"], Symbol("Text", "doc.text", 0x8E8E93));
        Add(["sh", "bash", "zsh", "fish"], Symbol("Shell", "terminal.fill", 0x4EAA25));
        Add(["ps1", "bat", "cmd"], Symbol("Script", "terminal.fill", 0x3B78C4));
        Add(["sql", "sqlite", "db"], Symbol("Database", "cylinder.split.1x2.fill", 0x0288D1));
        Add(["csv", "tsv", "xls", "xlsx"], Symbol("Table", "tablecells.fill", 0x1D8348));
        Add(["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "ico", "icns", "avif"], Symbol("Image", "photo.fill", 0x9B59B6));
        Add(["mp4", "mov", "avi", "mkv", "webm"], Symbol("Video", "film.fill", 0xE91E63));
        Add(["mp3", "wav", "flac", "aac", "ogg", "m4a"], Symbol("Audio", "music.note", 0xFF7043));
        Add(["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "pkg"], Symbol("Archive", "doc.zipper", 0xB8860B));
        Add(["pdf"], Symbol("PDF", "doc.richtext.fill", 0xE53935));
        Add(["doc", "docx", "pages", "rtf"], Symbol("Document", "doc.text.fill", 0x2B7CD3));
        Add(["ppt", "pptx", "key"], Symbol("Presentation", "rectangle.on.rectangle.angled.fill", 0xD35230));
        Add(["ttf", "otf", "woff", "woff2"], Symbol("Font", "textformat", 0x8E8E93));
        Add(["lock"], Symbol("Lockfile", "lock.fill", 0x8E8E93));
        Add(["gitignore", "gitattributes", "gitmodules", "gitkeep"], Symbol("Git", "arrow.triangle.branch", 0xF05032));
        Add(["xcodeproj", "xcworkspace", "pbxproj", "xcconfig", "entitlements"], Symbol("Xcode", "hammer.fill", 0x1C7CD6));
        Add(["storyboard", "xib"], Symbol("Interface Builder", "rectangle.3.group.fill", 0x1C7CD6));
        Add(["gradle"], Letters("Gradle", "GR", 0x02303A));
        Add(["tf", "tfvars"], Letters("Terraform", "TF", 0x7B42BC));
        Add(["proto"], Letters("Protobuf", "PB", 0x4285F4));
        Add(["graphql", "gql"], Letters("GraphQL", "GQ", 0xE10098));
        Add(["patch", "diff"], Symbol("Patch", "plusminus", 0x4CAF50));
        Add(["ipynb"], Letters("Notebook", "NB", 0xF37726));
        Add(["r"], Letters("R", "R", 0x276DC3));
        Add(["conf", "ini", "cfg", "properties"], Symbol("Settings", "gearshape.fill", 0x8E8E93));
    });
}
