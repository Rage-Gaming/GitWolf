import Foundation

/// Which icon to show for a file, chosen from its name or extension. This is data only; each platform
/// draws it (flat colour, no gradients).
public struct FileIcon: Equatable, Sendable {
    public enum Glyph: Equatable, Sendable {
        /// Short letters on a coloured rounded square, e.g. "TS".
        case letters(String)
        /// A system symbol name (SF Symbols on macOS; map to the nearest icon elsewhere).
        case symbol(String)
        /// A brand logo by Simple Icons slug (e.g. "python"), drawn in one flat colour on a coloured tile.
        case logo(String)
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

    /// The icon for a tag, from its name: version numbers (a major release like `v2.0.0` gets a star), pre-releases
    /// (`-rc.1`, `-beta`, `-alpha`), `nightly`, `latest`/`stable`, `lts`, deploy markers, and a plain tag otherwise
    /// (outlined when it is lightweight).
    public static func tagIcon(named name: String, isAnnotated: Bool = true) -> FileIcon {
        let lower = name.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { lower.contains($0) } }
        if has(["nightly", "daily"]) { return FileIcon("Nightly", .symbol("moon.stars.fill"), 0x5C6BC0) }
        if has(["-rc", ".rc", "rc."]) || lower.hasSuffix("rc") && lower.contains(where: \.isNumber) {
            return FileIcon("Release candidate", .symbol("flag.checkered"), 0x7E57C2)
        }
        if has(["alpha", "beta", "preview", "snapshot", "-pre", "canary", "-dev"]) {
            return FileIcon("Pre-release", .symbol("testtube.2"), 0xAB47BC)
        }
        if lower == "latest" || lower == "stable" || lower == "current" {
            return FileIcon("Latest", .symbol("checkmark.seal.fill"), 0x43A047)
        }
        if has(["lts"]) { return FileIcon("Long-term support", .symbol("shield.fill"), 0x26A69A) }
        if has(["deploy", "prod", "staging", "live"]) { return FileIcon("Deploy", .symbol("paperplane.fill"), 0x29B6F6) }
        if has(["backup", "archive", "old", "legacy"]) { return FileIcon("Archive", .symbol("archivebox.fill"), 0x8E8E93) }
        if match(#"^v?[1-9]\d*\.0(\.0)?$"#, lower) != nil { return FileIcon("Major release", .symbol("star.circle.fill"), 0xFFB300) }
        if match(#"^v?\d+(\.\d+)+$"#, lower) != nil {
            return FileIcon("Release", .symbol(isAnnotated ? "tag.fill" : "tag"), 0xFF9800)
        }
        return FileIcon("Tag", .symbol(isAnnotated ? "tag.fill" : "tag"), 0xFF9800)
    }

    private static func match(_ pattern: String, _ text: String) -> Range<String.Index>? {
        text.range(of: pattern, options: .regularExpression)
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
    /// A brand logo (Simple Icons slug) in white on a coloured tile; the platform draws it.
    private static func logo(_ name: String, _ slug: String, _ color: UInt32, dark: Bool = false) -> FileIcon {
        FileIcon(name, .logo(slug), color, darkText: dark)
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
        add(["ts", "mts", "cts"], logo("TypeScript", "typescript", 0x3178C6))
        add(["d.ts"], logo("TypeScript declarations", "typescript", 0x3178C6))
        add(["js", "mjs", "cjs"], logo("JavaScript", "javascript", 0xF7DF1E, dark: true))
        add(["swift"], logo("Swift", "swift", 0xF05138))
        add(["py", "pyw", "pyi"], logo("Python", "python", 0x3776AB))
        add(["go"], logo("Go", "go", 0x00ADD8))
        add(["rs"], logo("Rust", "rust", 0xDEA584, dark: true))
        add(["java"], logo("Java", "openjdk", 0xE76F00))
        add(["kt", "kts"], logo("Kotlin", "kotlin", 0x7F52FF))
        add(["c", "h"], logo("C", "c", 0x5C6BC0))
        add(["cpp", "cc", "cxx", "hpp", "hh", "hxx"], logo("C++", "cplusplus", 0x00599C))
        add(["m", "mm"], letters("Objective-C", "OC", 0x438EFF))
        add(["rb", "gemspec"], logo("Ruby", "ruby", 0xCC342D))
        add(["php"], logo("PHP", "php", 0x777BB4))
        add(["dart"], logo("Dart", "dart", 0x0175C2))
        add(["lua"], logo("Lua", "lua", 0x000080))
        add(["scala"], logo("Scala", "scala", 0xDC322F))
        add(["ex", "exs"], logo("Elixir", "elixir", 0x6E4A7E))
        add(["hs"], logo("Haskell", "haskell", 0x5D4F85))
        add(["zig"], logo("Zig", "zig", 0xF7A41D, dark: true))
        add(["vue"], logo("Vue", "vuedotjs", 0x42B883))
        add(["svelte"], logo("Svelte", "svelte", 0xFF3E00))
        add(["html", "htm"], logo("HTML", "html5", 0xE44D26))
        add(["css"], logo("CSS", "css", 0x1572B6))
        add(["pl", "pm"], logo("Perl", "perl", 0x39457E))
        add(["clj", "cljs", "cljc", "edn"], logo("Clojure", "clojure", 0x5881D8))
        add(["erl", "hrl"], logo("Erlang", "erlang", 0xA90533))
        add(["jl"], logo("Julia", "julia", 0x9558B2))
        add(["nim", "nims"], logo("Nim", "nim", 0xFFE953, dark: true))
        add(["cr"], logo("Crystal", "crystal", 0x2B2B2B))
        add(["fs", "fsx", "fsi"], logo("F#", "fsharp", 0x378BBA))
        add(["sol"], logo("Solidity", "solidity", 0x5B5B5B))
        add(["wasm", "wat"], logo("WebAssembly", "webassembly", 0x654FF0))
        add(["tex", "sty", "cls"], logo("LaTeX", "latex", 0x008080))
        add(["coffee"], logo("CoffeeScript", "coffeescript", 0x6F4E37))
        add(["elm"], logo("Elm", "elm", 0x1293D8))
        add(["ml", "mli"], logo("OCaml", "ocaml", 0xEC6813))
        add(["rkt"], logo("Racket", "racket", 0x9F1D20))
        add(["f90", "f95", "f03", "for"], logo("Fortran", "fortran", 0x734F96))
        add(["d"], logo("D", "d", 0xB03931))
        add(["astro"], logo("Astro", "astro", 0xBC52EE))
        add(["gd"], logo("GDScript", "godotengine", 0x478CBF))
        add(["cs", "csx"], logo("C#", "csharp", 0x68217A))
        add(["razor", "cshtml"], logo(".NET", "dotnet", 0x512BD4))
        add(["scss", "sass"], logo("Sass", "sass", 0xCD6799))
        add(["less"], logo("Less", "less", 0x1D365D))
        add(["json", "jsonc", "json5"], logo("JSON", "json", 0xCBA02A, dark: true))
        add(["yml", "yaml"], logo("YAML", "yaml", 0xCB171E))
        add(["toml"], logo("TOML", "toml", 0x9C4221))
        add(["xml", "plist", "svg"], letters("XML", "</>", 0xE37933))
        add(["md", "markdown", "mdx"], logo("Markdown", "markdown", 0x519ABA))
        add(["txt", "text", "log"], symbol("Text", "doc.text", 0x8E8E93))
        add(["sh", "bash", "zsh", "fish"], logo("Shell", "gnubash", 0x4EAA25))
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
        add(["gradle"], logo("Gradle", "gradle", 0x02303A))
        add(["tf", "tfvars"], logo("Terraform", "terraform", 0x7B42BC))
        add(["proto"], letters("Protobuf", "PB", 0x4285F4))
        add(["graphql", "gql"], logo("GraphQL", "graphql", 0xE10098))
        add(["patch", "diff"], symbol("Patch", "plusminus", 0x4CAF50))
        add(["ipynb"], logo("Notebook", "jupyter", 0xF37726))
        add(["r"], logo("R", "r", 0x276DC3))
        add(["conf", "ini", "cfg", "properties"], symbol("Settings", "gearshape.fill", 0x8E8E93))
        add(["groovy", "gvy"], logo("Groovy", "apachegroovy", 0x4298B8))
        add(["ps1", "psm1", "psd1"], logo("PowerShell", "powershell", 0x5391FE))
        add(["nix"], logo("Nix", "nixos", 0x5277C3))
        add(["mlx", "mat"], letters("MATLAB", "ML", 0xE16737))
        add(["scm", "ss", "sld"], letters("Scheme", "SCM", 0x1E4A8C))
        add(["cob", "cbl", "cpy"], letters("COBOL", "CBL", 0x005CA5))
        add(["gleam"], letters("Gleam", "GL", 0xFFAFF3, dark: true))
        add(["v", "vh", "sv", "svh"], letters("Verilog", "V", 0x4F6D8F))
        add(["vhd", "vhdl"], letters("VHDL", "VH", 0x543978))
        add(["adb", "ads", "ada"], letters("Ada", "ADA", 0x02F88C, dark: true))
        add(["pas", "dpr", "dfm", "lpr", "pp"], logo("Delphi", "delphi", 0xEE1F35))
        add(["pro", "prolog"], letters("Prolog", "PRO", 0xE61B23))
        add(["tcl"], letters("Tcl", "TCL", 0xE4CC98, dark: true))
        add(["st"], letters("Smalltalk", "ST", 0x596706))
        add(["raku", "rakumod", "p6"], letters("Raku", "RK", 0x0000FB))
        add(["lisp", "lsp", "cl"], letters("Lisp", "LISP", 0x3FB68B))
        add(["el"], logo("Emacs Lisp", "gnuemacs", 0x7F5AB6))
        add(["vim"], logo("Vim script", "vim", 0x019733))
        add(["ino"], logo("Arduino", "arduino", 0x00979D))
        add(["cu", "cuh"], logo("CUDA", "nvidia", 0x76B900))
        add(["bicep"], letters("Bicep", "BI", 0x519ABA))
        add(["asm", "nasm"], letters("Assembly", "ASM", 0x6E4C13))
        add(["hx", "hxml"], logo("Haxe", "haxe", 0xEA8220))
        add(["res", "resi"], logo("ReScript", "rescript", 0xE6484F))
        add(["re", "rei"], letters("Reason", "RE", 0xDD4B39))
        add(["vala", "vapi"], logo("Vala", "vala", 0x7239B3))
        add(["scad"], logo("OpenSCAD", "openscad", 0xF9D72C, dark: true))
        add(["luau"], logo("Luau", "lua", 0x000080))
        add(["cairo"], letters("Cairo", "CA", 0xFF7A59))
        add(["move"], letters("Move", "MV", 0x4A90D9))
        add(["vy"], letters("Vyper", "VY", 0x2E7D32))
        add(["twig"], letters("Twig", "TW", 0xBACF29, dark: true))
        add(["liquid"], letters("Liquid", "LQ", 0x67B8DE))
        add(["hbs", "handlebars"], logo("Handlebars", "handlebarsdotjs", 0xF0772B))
        add(["mustache"], letters("Mustache", "{{", 0x724B3B))
        add(["pug", "jade"], logo("Pug", "pug", 0xA86454))
        add(["ejs"], logo("EJS", "ejs", 0xB4CA65, dark: true))
        add(["j2", "jinja", "jinja2"], logo("Jinja", "jinja", 0xB41717))
        add(["styl"], logo("Stylus", "stylus", 0xFF6347))
        add(["pcss", "postcss"], logo("PostCSS", "postcss", 0xDD3A0A))
        add(["hcl"], logo("Terraform", "terraform", 0x7B42BC))
        add(["prisma"], logo("Prisma", "prisma", 0x2D3748))
        add(["epp"], logo("Puppet", "puppet", 0xFFAE1A, dark: true))
        add(["bzl", "bazel"], logo("Bazel", "bazel", 0x43A047))
        add(["xcodeproj", "xcworkspace", "pbxproj", "xcconfig"], logo("Xcode", "xcode", 0x147EFB))
        add(["sln", "csproj", "vbproj", "fsproj"], logo("Visual Studio", "visualstudio", 0x5C2D91))
        add(["xaml"], logo("XAML", "xaml", 0x0C54C2))
        add(["scala.sbt"], logo("Apache Spark", "apachespark", 0xE25A1C))
        add(["sh", "bash", "zsh", "fish", "ksh"], logo("Shell", "gnubash", 0x4EAA25))
        return m
    }()

    static let names: [String: FileIcon] = [
        "nginx.conf": logo("nginx", "nginx", 0x009639),
        "vagrantfile": logo("Vagrant", "vagrant", 0x1868F2),
        "pom.xml": logo("Maven", "apachemaven", 0xC71A36),
        ".npmrc": logo("npm", "npm", 0xCB3837),
        "pnpm-workspace.yaml": logo("pnpm", "pnpm", 0xF69220),
        ".nvmrc": logo("Node.js", "nodedotjs", 0x5FA04E),
        "rollup.config.js": logo("Rollup", "rollupdotjs", 0xEC4A3F),
        "postcss.config.js": logo("PostCSS", "postcss", 0xDD3A0A),
        "caddyfile": logo("Caddy", "caddy", 0x1F88C0),
        ".vimrc": logo("Vim script", "vim", 0x019733),
        "redis.conf": logo("Redis", "redis", 0xDC382D),
        "schema.prisma": logo("Prisma", "prisma", 0x2D3748),
        "build.gradle": logo("Gradle", "gradle", 0x02303A),
        "settings.gradle": logo("Gradle", "gradle", 0x02303A),
        "tailwind.config.js": logo("Tailwind CSS", "tailwindcss", 0x06B6D4),
        "tailwind.config.ts": logo("Tailwind CSS", "tailwindcss", 0x06B6D4),
        "vite.config.ts": logo("Vite", "vite", 0x646CFF),
        "vite.config.js": logo("Vite", "vite", 0x646CFF),
        "webpack.config.js": logo("webpack", "webpack", 0x8DD6F9, dark: true),
        "babel.config.js": logo("Babel", "babel", 0xF9DC3E, dark: true),
        ".babelrc": logo("Babel", "babel", 0xF9DC3E, dark: true),
        "angular.json": logo("Angular", "angular", 0xDD0031),
        "pubspec.yaml": logo("Dart", "dart", 0x0175C2),
        "deno.json": logo("Deno", "deno", 0x70FFAF, dark: true),
        "bun.lockb": symbol("Lockfile", "lock.fill", 0xFBF0DF),
        "package.json": logo("npm", "npm", 0xCB3837),
        "package-lock.json": symbol("Lockfile", "lock.fill", 0xCB3837),
        "yarn.lock": symbol("Lockfile", "lock.fill", 0x2C8EBB),
        "pnpm-lock.yaml": symbol("Lockfile", "lock.fill", 0xF69220),
        "cargo.toml": logo("Cargo", "rust", 0xDEA584, dark: true),
        "cargo.lock": symbol("Lockfile", "lock.fill", 0xDEA584),
        "go.mod": logo("Go", "go", 0x00ADD8),
        "go.sum": symbol("Lockfile", "lock.fill", 0x00ADD8),
        "package.swift": logo("Swift package", "swift", 0xF05138),
        "package.resolved": symbol("Lockfile", "lock.fill", 0xF05138),
        "tsconfig.json": logo("TypeScript config", "typescript", 0x3178C6),
        "jsconfig.json": logo("JavaScript config", "javascript", 0xF7DF1E, dark: true),
        "gemfile": logo("Ruby", "ruby", 0xCC342D),
        "gemfile.lock": symbol("Lockfile", "lock.fill", 0xCC342D),
        "podfile": logo("CocoaPods", "cocoapods", 0xEE3322),
        "podfile.lock": symbol("Lockfile", "lock.fill", 0xEE3322),
        "requirements.txt": logo("Python", "python", 0x3776AB),
        "pyproject.toml": logo("Python", "python", 0x3776AB),
        "pipfile": logo("Python", "python", 0x3776AB),
        "dockerfile": logo("Docker", "docker", 0x2496ED),
        "docker-compose.yml": logo("Docker", "docker", 0x2496ED),
        "docker-compose.yaml": logo("Docker", "docker", 0x2496ED),
        ".dockerignore": logo("Docker", "docker", 0x2496ED),
        "makefile": logo("Makefile", "make", 0x6D8086),
        "cmakelists.txt": logo("CMake", "cmake", 0x064F8C),
        "readme.md": symbol("Readme", "book.fill", 0x42A5F5),
        ".gitignore": symbol("Git", "arrow.triangle.branch", 0xF05032),
        ".gitattributes": symbol("Git", "arrow.triangle.branch", 0xF05032),
        ".gitmodules": symbol("Git", "arrow.triangle.branch", 0xF05032),
        ".gitkeep": symbol("Git", "arrow.triangle.branch", 0xF05032),
        ".editorconfig": symbol("Editor config", "gearshape.fill", 0x8E8E93),
        ".eslintrc": logo("ESLint", "eslint", 0x4B32C3),
        ".prettierrc": logo("Prettier", "prettier", 0x56B3B4),
        ".ds_store": logo("macOS", "apple", 0x8E8E93),
        "info.plist": letters("XML", "</>", 0xE37933),
    ]
}
