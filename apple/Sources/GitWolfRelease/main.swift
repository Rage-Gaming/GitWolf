import Foundation
import GitWolfCore
import Security

// gitwolf-release: update-signing keys, signing a release archive, and writing the update feed.
//
//   gitwolf-release keys generate            make the key pair; the private key goes into your login Keychain
//   gitwolf-release keys public              print the public key (it goes into Info.plist as SUPublicEDKey)
//   gitwolf-release keys export <file>       write the private key to a file (0600), for a CI secret
//   gitwolf-release build-number <version>   the build number for a version
//   gitwolf-release appcast --version V --archive FILE --url URL [--notes FILE] [--feed FILE] --out FILE
//
// The private key is read from the Keychain, or from the GITWOLF_UPDATE_KEY environment variable (CI).
// It is never printed and never passed on a command line.

private let service = "GitWolf Update Signing Key"
private let account = "ed25519"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// The Keychain is reached through Apple's own `security` tool: it has a stable identity, so access granted
/// once ("Always Allow") survives rebuilds of this tool, which a binary of ours would not.
func runSecurity(_ arguments: [String], stdin: String? = nil) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = arguments
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    let input = Pipe()
    if stdin != nil { p.standardInput = input }
    do { try p.run() } catch { return (-1, "") }
    if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)); try? input.fileHandleForWriting.close() }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func keychainRead() -> String? {
    let r = runSecurity(["find-generic-password", "-s", service, "-a", account, "-w"])
    guard r.status == 0 else { return nil }
    let key = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    return key.isEmpty ? nil : key
}

func keychainSave(_ secret: String) {
    // `security -i` reads its commands from stdin, so the secret never appears in an argument list.
    let r = runSecurity(["-i"], stdin: "add-generic-password -s \"\(service)\" -a \"\(account)\" -w \"\(secret)\" -U\n")
    if r.status != 0 { fail("couldn’t save the key to the Keychain") }
}

func privateKey() -> String {
    if let env = ProcessInfo.processInfo.environment["GITWOLF_UPDATE_KEY"], !env.isEmpty { return env }
    if let stored = keychainRead() { return stored }
    fail("no update signing key. Run `gitwolf-release keys generate`, or set GITWOLF_UPDATE_KEY.")
}

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func html(forMarkdown text: String) -> String {
    // Release notes are short Markdown from GitHub; show them as preformatted-but-wrapped text, safely escaped.
    let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
    return "<pre style=\"font-family: -apple-system, sans-serif; white-space: pre-wrap;\">\(escaped)</pre>"
}

let args = Array(CommandLine.arguments.dropFirst())
switch (args.first, args.dropFirst().first) {
case ("keys", "generate"):
    if keychainRead() != nil { fail("a key already exists in your Keychain. Use `keys public` to see its public key.") }
    let pair = UpdateSigning.generate()
    keychainSave(pair.privateKey)
    print("Created the update signing key and stored the private half in your login Keychain.")
    print("Public key (SUPublicEDKey):")
    print(pair.publicKey)
case ("keys", "public"):
    do { print(try UpdateSigning.publicKey(forPrivateKey: privateKey())) } catch { fail(error.localizedDescription) }
case ("keys", "export"):
    guard args.count > 2 else { fail("usage: keys export <file>") }
    let path = args[2]
    guard FileManager.default.createFile(atPath: path, contents: Data(privateKey().utf8), attributes: [.posixPermissions: 0o600]) else {
        fail("couldn’t write \(path)")
    }
    print("Wrote the private key to \(path) (readable only by you). Paste it into the GITWOLF_UPDATE_KEY repository secret, then delete the file.")
case ("build-number", _):
    guard args.count > 1, let v = AppVersion(args[1]) else { fail("usage: build-number <version>") }
    print(v.buildNumber)
case ("appcast", _):
    guard let versionText = option("--version", in: args), let version = AppVersion(versionText),
          let archive = option("--archive", in: args), let url = option("--url", in: args),
          let out = option("--out", in: args) else {
        fail("usage: appcast --version V --archive FILE --url URL [--notes FILE] [--feed FILE] --out FILE")
    }
    guard let data = FileManager.default.contents(atPath: archive) else { fail("can’t read \(archive)") }
    let signature: String
    do { signature = try UpdateSigning.sign(data, privateKey: privateKey()) } catch { fail(error.localizedDescription) }
    let notes = option("--notes", in: args).flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
    let existing = option("--feed", in: args).flatMap { FileManager.default.contents(atPath: $0) }.map(Appcast.parse) ?? []
    let item = AppcastItem(version: version.description, build: String(version.buildNumber), url: url, length: data.count,
                           signature: signature, notesHTML: notes.isEmpty ? "" : html(forMarkdown: notes))
    let feed = Appcast.render(Appcast.merging(item, into: existing))
    do { try feed.write(toFile: out, atomically: true, encoding: .utf8) } catch { fail("couldn’t write \(out)") }
    print("Signed \(archive) (\(data.count) bytes) and wrote \(out) with \(Appcast.merging(item, into: existing).count) release(s).")
default:
    print("""
    usage:
      gitwolf-release keys generate | public | export <file>
      gitwolf-release build-number <version>
      gitwolf-release appcast --version V --archive FILE --url URL [--notes FILE] [--feed FILE] --out FILE
    """)
    exit(args.isEmpty ? 0 : 1)
}
