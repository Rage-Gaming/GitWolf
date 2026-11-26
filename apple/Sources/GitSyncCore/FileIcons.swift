import Foundation

/// Which icon to show for a file, chosen from its name or extension. This is data only; each platform
/// draws it (flat colour, no gradients).
public struct FileIcon: Equatable, Sendable {
    public enum Glyph: Equatable, Sendable {
        /// Short letters on a coloured rounded square, e.g. "TS".
        case letters(String)
        /// A system symbol name (SF Symbols on macOS; map to the nearest icon elsewhere).
        case symbol(String)
        /// The React atom: three ellipses and a dot.
        case react
        /// A folder in the brand colour, with an optional small symbol on it (e.g. "book.fill" for docs).
        case folder(String?)
    }

    public var name: String
    public var glyph: Glyph
    /// Brand colour as 0xRRGGBB.
    public var color: UInt32
    /// Use dark text on the tile (for light brand colours such as JavaScript yellow).
    public var darkText: Bool

    init(_ name: String, _ glyph: Glyph, _ color: UInt32, darkText: Bool = false) {
        self.name = name
        self.glyph = glyph
        self.color = color
        self.darkText = darkText
    }
}

public enum FileIcons {
    /// The icon for a path (only the file name matters).
    public static func icon(forPath path: String) -> FileIcon {
        let file = (path as NSString).lastPathComponent
        let lower = file.lowercased()
        if let byName = names[lower] { return byName }
        if lower.hasPrefix(".env") { return env }
        if lower.hasPrefix("readme") { return names["readme.md"] ?? generic }
        if lower.hasPrefix("license") || lower.hasPrefix("licence") || lower == "copying" { return license }
        if lower.hasPrefix("dockerfile") { return names["dockerfile"] ?? generic }
        // Compound extensions first (foo.test.ts has ".ts"; foo.d.ts and foo.min.js are special), then the last one.
        if lower.hasSuffix(".d.ts") { return extensions["d.ts"] ?? generic }
        if lower.hasSuffix(".min.js") || lower.hasSuffix(".min.css") { return minified }
        let ext = (lower as NSString).pathExtension
        if let icon = extensions[ext] { return icon }
        return generic
    }

    /// The icon for a folder, by its own name (`src`, `docs`, `node_modules`, `.github`…).
    public static func folderIcon(named name: String) -> FileIcon {
        let lower = name.lowercased()
        return folders[lower] ?? FileIcon("Folder", .folder(nil), 0x6FA8DC)
    }

    /// The icon for the folder that directly contains `path` (nil for files at the top level).
    public static func folderIcon(containing path: String) -> FileIcon? {
        let dir = (path as NSString).deletingLastPathComponent
        guard !dir.isEmpty else { return nil }
        let parts = dir.split(separator: "/").map { $0.lowercased() }
        if let last = parts.last, folders[last] != nil { return folderIcon(named: last) }
        // Inside a dependency, CI or build folder, everything below it keeps that folder's look.
        if let outer = parts.last(where: { containers.contains($0) }) { return folderIcon(named: outer) }
        return folderIcon(named: parts.last ?? dir)
    }

    private static let containers: Set<String> = [
        "node_modules", "vendor", "third_party", "pods", ".github", ".gitlab", ".circleci", ".git",
        "dist", "build", "out", "target", ".build", "deriveddata",
    ]

    private static func folder(_ name: String, _ inner: String?, _ color: UInt32) -> FileIcon {
        FileIcon(name, .folder(inner), color)
    }

    static let folders: [String: FileIcon] = {
        var m: [String: FileIcon] = [:]
        func add(_ names: [String], _ icon: FileIcon) { for n in names { m[n] = icon } }
        add(["src", "source", "sources"], folder("Source", "chevron.left.forwardslash.chevron.right", 0x42A5F5))
        add(["lib", "libs", "library", "libraries"], folder("Library", "books.vertical.fill", 0x8D6E63))
        add(["docs", "doc", "documentation"], folder("Docs", "book.fill", 0x4DB6AC))
        add(["test", "tests", "__tests__", "spec", "specs"], folder("Tests", "checkmark", 0x66BB6A))
        add(["assets", "static", "resources", "res"], folder("Assets", "photo.fill", 0xAB47BC))
        add(["images", "img", "icons", "media"], folder("Images", "photo.fill", 0x9575CD))
        add(["public", "www", "web"], folder("Public", "globe", 0x26C6DA))
        add(["components", "views", "ui"], folder("Components", "square.grid.2x2.fill", 0x29B6F6))
        add(["scripts", "script", "tools", "bin"], folder("Scripts", "terminal.fill", 0x7CB342))
        add(["config", "configs", "conf", "settings"], folder("Config", "gearshape.fill", 0x9E9E9E))
        add([".github", ".gitlab", ".circleci"], folder("CI", "arrow.triangle.branch", 0xF05032))
        add([".git"], folder("Git", "arrow.triangle.branch", 0xF05032))
        add([".vscode", ".idea", ".xcode"], folder("Editor", "wrench.and.screwdriver.fill", 0x1E88E5))
        add(["node_modules", "vendor", "third_party", "pods", "packages"], folder("Dependencies", "shippingbox.fill", 0x8BC34A))
        add(["build", "dist", "out", "target", "release", "debug", ".build", "deriveddata"], folder("Build output", "hammer.fill", 0xFF9800))
        add(["api", "routes", "controllers", "server"], folder("API", "network", 0xEF5350))
        add(["models", "model", "db", "database", "migrations"], folder("Data", "cylinder.split.1x2.fill", 0x26A69A))
        add(["styles", "css", "themes"], folder("Styles", "paintpalette.fill", 0xEC407A))
        add(["utils", "util", "helpers", "common", "shared", "core"], folder("Shared", "wrench.fill", 0x78909C))
        add(["docker", ".docker"], folder("Docker", "shippingbox.fill", 0x2496ED))
        add(["fonts"], folder("Fonts", "textformat", 0x8E8E93))
        add(["hooks"], folder("Hooks", "link", 0x7E57C2))
        add(["types", "typings", "interfaces"], folder("Types", "t.square.fill", 0x3178C6))
        add(["localization", "locales", "i18n", "l10n"], folder("Localization", "character.bubble.fill", 0x5C6BC0))
        add(["examples", "example", "samples", "demo"], folder("Examples", "lightbulb.fill", 0xFFCA28))
        return m
    }()

    /// The icon for a branch, chosen from its name: `main`, `develop`, and conventional prefixes such as
    /// `feature/…`, `fix/…`, `release/…`, `docs/…`. Also accepts `refs/heads/x` style short names only.
    public static func branchIcon(named name: String) -> FileIcon {
        let lower = name.lowercased()
        if let exact = branchNames[lower] { return exact }
        let separators = CharacterSet(charactersIn: "/-_")
        let first = lower.components(separatedBy: separators).first ?? lower
        if let byPrefix = branchPrefixes[first] { return byPrefix }
        // `123-fix-login` and `issue-42` look like issue branches.
        if first.allSatisfy(\.isNumber) && !first.isEmpty { return branchPrefixes["issue"] ?? branchDefault }
        return branchDefault
    }

    private static let branchDefault = FileIcon("Branch", .symbol("arrow.triangle.branch"), 0x8E8E93)

    private static func branch(_ name: String, _ symbol: String, _ color: UInt32) -> FileIcon {
        FileIcon(name, .symbol(symbol), color)
    }

    static let branchNames: [String: FileIcon] = {
        var m: [String: FileIcon] = [:]
        for n in ["main", "master", "trunk"] { m[n] = branch("Main branch", "star.fill", 0x42A5F5) }
        for n in ["develop", "dev", "development", "next"] { m[n] = branch("Development", "hammer.fill", 0xAB47BC) }
        for n in ["staging", "stage", "preprod"] { m[n] = branch("Staging", "flag.fill", 0xFF9800) }
        for n in ["production", "prod", "live"] { m[n] = branch("Production", "bolt.shield.fill", 0xE53935) }
        return m
    }()

    static let branchPrefixes: [String: FileIcon] = {
        var m: [String: FileIcon] = [:]
        func add(_ names: [String], _ icon: FileIcon) { for n in names { m[n] = icon } }
        add(["feature", "feat", "features"], branch("Feature", "sparkles", 0x26A69A))
        add(["fix", "bugfix", "bug"], branch("Bug fix", "ladybug.fill", 0xE53935))
        add(["hotfix", "urgent"], branch("Hotfix", "flame.fill", 0xFF7043))
        add(["release", "releases", "rc", "v"], branch("Release", "shippingbox.fill", 0x7E57C2))
        add(["chore", "build", "ci", "ops"], branch("Chore", "wrench.and.screwdriver.fill", 0x78909C))
        add(["docs", "doc", "documentation"], branch("Docs", "book.fill", 0x4DB6AC))
        add(["test", "tests", "testing"], branch("Tests", "checkmark.seal.fill", 0x66BB6A))
        add(["refactor", "cleanup", "tidy"], branch("Refactor", "arrow.triangle.2.circlepath", 0x5C6BC0))
        add(["perf", "performance", "speed"], branch("Performance", "bolt.fill", 0xFFB300))
        add(["style", "ui", "design", "theme"], branch("Design", "paintpalette.fill", 0xEC407A))
        add(["wip", "experiment", "spike", "poc", "tmp", "temp", "try"], branch("Experiment", "testtube.2", 0x9C27B0))
        add(["revert"], branch("Revert", "arrow.uturn.backward.circle.fill", 0xEF5350))
        add(["dependabot", "renovate", "deps", "bump"], branch("Dependencies", "arrow.down.circle.fill", 0x8BC34A))
        add(["pr", "pull", "review", "mr"], branch("Pull request", "arrow.triangle.pull", 0x29B6F6))
        add(["issue", "issues", "ticket"], branch("Issue", "smallcircle.filled.circle", 0x66BB6A))
        return m
    }()

    private static let generic = FileIcon("File", .symbol("doc"), 0x8E8E93)
    private static let env = FileIcon("Environment", .symbol("key.fill"), 0xECD53F)
    private static let license = FileIcon("License", .symbol("checkmark.seal.fill"), 0xD0B64B)
    private static let minified = FileIcon("Minified", .symbol("arrow.down.right.and.arrow.up.left"), 0x8E8E93)

    private static func letters(_ name: String, _ text: String, _ color: UInt32, dark: Bool = false) -> FileIcon {
        FileIcon(name, .letters(text), color, darkText: dark)
    }
    private static func symbol(_ name: String, _ symbol: String, _ color: UInt32) -> FileIcon {
        FileIcon(name, .symbol(symbol), color)
    }

    // Brand colours are the languages' own, flat.
    static let extensions: [String: FileIcon] = {
        var m: [String: FileIcon] = [:]
        func add(_ exts: [String], _ icon: FileIcon) { for e in exts { m[e] = icon } }
        let react = FileIcon("React", .react, 0x61DAFB)
        add(["tsx", "jsx"], react)
        add(["ts", "mts", "cts"], letters("TypeScript", "TS", 0x3178C6))
        add(["d.ts"], letters("TypeScript declarations", "TS", 0x3178C6))
        add(["js", "mjs", "cjs"], letters("JavaScript", "JS", 0xF7DF1E, dark: true))
        add(["swift"], symbol("Swift", "swift", 0xF05138))
        add(["py", "pyw", "pyi"], letters("Python", "PY", 0x3776AB))
        add(["go"], letters("Go", "GO", 0x00ADD8))
        add(["rs"], letters("Rust", "RS", 0xDEA584, dark: true))
        add(["java"], letters("Java", "J", 0xE76F00))
        add(["kt", "kts"], letters("Kotlin", "KT", 0x7F52FF))
        add(["c", "h"], letters("C", "C", 0x5C6BC0))
        add(["cpp", "cc", "cxx", "hpp", "hh", "hxx"], letters("C++", "C+", 0x00599C))
        add(["m", "mm"], letters("Objective-C", "OC", 0x438EFF))
        add(["cs"], letters("C#", "C#", 0x68217A))
        add(["rb", "gemspec"], letters("Ruby", "RB", 0xCC342D))
        add(["php"], letters("PHP", "PHP", 0x777BB4))
        add(["dart"], letters("Dart", "DA", 0x0175C2))
        add(["lua"], letters("Lua", "LU", 0x000080))
        add(["scala"], letters("Scala", "SC", 0xDC322F))
        add(["ex", "exs"], letters("Elixir", "EX", 0x6E4A7E))
        add(["hs"], letters("Haskell", "HS", 0x5D4F85))
        add(["zig"], letters("Zig", "ZG", 0xF7A41D, dark: true))
        add(["vue"], letters("Vue", "V", 0x42B883))
        add(["svelte"], letters("Svelte", "S", 0xFF3E00))
        add(["html", "htm"], letters("HTML", "<>", 0xE44D26))
        add(["css"], letters("CSS", "CSS", 0x1572B6))
        add(["scss", "sass"], letters("Sass", "SC", 0xCD6799))
        add(["less"], letters("Less", "LE", 0x1D365D))
        add(["json", "jsonc", "json5"], letters("JSON", "{}", 0xCBA02A, dark: true))
        add(["yml", "yaml"], letters("YAML", "YML", 0xCB171E))
        add(["toml"], letters("TOML", "TML", 0x9C4221))
        add(["xml", "plist", "svg"], letters("XML", "</>", 0xE37933))
        add(["md", "markdown", "mdx"], letters("Markdown", "M↓", 0x519ABA))
        add(["txt", "text", "log"], symbol("Text", "doc.text", 0x8E8E93))
        add(["sh", "bash", "zsh", "fish"], symbol("Shell", "terminal.fill", 0x4EAA25))
        add(["ps1", "bat", "cmd"], symbol("Script", "terminal.fill", 0x3B78C4))
        add(["sql", "sqlite", "db"], symbol("Database", "cylinder.split.1x2.fill", 0x0288D1))
        add(["csv", "tsv", "xls", "xlsx"], symbol("Table", "tablecells.fill", 0x1D8348))
        add(["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "ico", "icns", "avif"], symbol("Image", "photo.fill", 0x9B59B6))
        add(["mp4", "mov", "avi", "mkv", "webm"], symbol("Video", "film.fill", 0xE91E63))
        add(["mp3", "wav", "flac", "aac", "ogg", "m4a"], symbol("Audio", "music.note", 0xFF7043))
        add(["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "pkg"], symbol("Archive", "doc.zipper", 0xB8860B))
        add(["pdf"], symbol("PDF", "doc.richtext.fill", 0xE53935))
        add(["doc", "docx", "pages", "rtf"], symbol("Document", "doc.text.fill", 0x2B7CD3))
        add(["ppt", "pptx", "key"], symbol("Presentation", "rectangle.on.rectangle.angled.fill", 0xD35230))
        add(["ttf", "otf", "woff", "woff2"], symbol("Font", "textformat", 0x8E8E93))
        add(["lock"], symbol("Lockfile", "lock.fill", 0x8E8E93))
        add(["gitignore", "gitattributes", "gitmodules", "gitkeep"], symbol("Git", "arrow.triangle.branch", 0xF05032))
        add(["xcodeproj", "xcworkspace", "pbxproj", "xcconfig", "entitlements"], symbol("Xcode", "hammer.fill", 0x1C7CD6))
        add(["storyboard", "xib"], symbol("Interface Builder", "rectangle.3.group.fill", 0x1C7CD6))
        add(["gradle"], letters("Gradle", "GR", 0x02303A))
        add(["tf", "tfvars"], letters("Terraform", "TF", 0x7B42BC))
        add(["proto"], letters("Protobuf", "PB", 0x4285F4))
        add(["graphql", "gql"], letters("GraphQL", "GQ", 0xE10098))
        add(["patch", "diff"], symbol("Patch", "plusminus", 0x4CAF50))
        add(["ipynb"], letters("Notebook", "NB", 0xF37726))
        add(["r"], letters("R", "R", 0x276DC3))
        add(["conf", "ini", "cfg", "properties"], symbol("Settings", "gearshape.fill", 0x8E8E93))
        return m
    }()

    static let names: [String: FileIcon] = [
        "package.json": letters("npm", "npm", 0xCB3837),
        "package-lock.json": symbol("Lockfile", "lock.fill", 0xCB3837),
        "yarn.lock": symbol("Lockfile", "lock.fill", 0x2C8EBB),
        "pnpm-lock.yaml": symbol("Lockfile", "lock.fill", 0xF69220),
        "cargo.toml": letters("Cargo", "RS", 0xDEA584, dark: true),
        "cargo.lock": symbol("Lockfile", "lock.fill", 0xDEA584),
        "go.mod": letters("Go", "GO", 0x00ADD8),
        "go.sum": symbol("Lockfile", "lock.fill", 0x00ADD8),
        "package.swift": symbol("Swift package", "swift", 0xF05138),
        "package.resolved": symbol("Lockfile", "lock.fill", 0xF05138),
        "tsconfig.json": letters("TypeScript config", "TS", 0x3178C6),
        "jsconfig.json": letters("JavaScript config", "JS", 0xF7DF1E, dark: true),
        "gemfile": letters("Ruby", "RB", 0xCC342D),
        "gemfile.lock": symbol("Lockfile", "lock.fill", 0xCC342D),
        "podfile": letters("CocoaPods", "CP", 0xEE3322),
        "podfile.lock": symbol("Lockfile", "lock.fill", 0xEE3322),
        "requirements.txt": letters("Python", "PY", 0x3776AB),
        "pyproject.toml": letters("Python", "PY", 0x3776AB),
        "pipfile": letters("Python", "PY", 0x3776AB),
        "dockerfile": symbol("Docker", "shippingbox.fill", 0x2496ED),
        "docker-compose.yml": symbol("Docker", "shippingbox.fill", 0x2496ED),
        "docker-compose.yaml": symbol("Docker", "shippingbox.fill", 0x2496ED),
        ".dockerignore": symbol("Docker", "shippingbox.fill", 0x2496ED),
        "makefile": symbol("Makefile", "wrench.and.screwdriver.fill", 0x6D8086),
        "cmakelists.txt": symbol("CMake", "wrench.and.screwdriver.fill", 0x064F8C),
        "readme.md": symbol("Readme", "book.fill", 0x42A5F5),
        ".gitignore": symbol("Git", "arrow.triangle.branch", 0xF05032),
        ".gitattributes": symbol("Git", "arrow.triangle.branch", 0xF05032),
        ".gitmodules": symbol("Git", "arrow.triangle.branch", 0xF05032),
        ".gitkeep": symbol("Git", "arrow.triangle.branch", 0xF05032),
        ".editorconfig": symbol("Editor config", "gearshape.fill", 0x8E8E93),
        ".eslintrc": letters("ESLint", "ES", 0x4B32C3),
        ".prettierrc": letters("Prettier", "PR", 0x56B3B4),
        ".ds_store": symbol("macOS", "apple.logo", 0x8E8E93),
        "info.plist": letters("XML", "</>", 0xE37933),
    ]
}
