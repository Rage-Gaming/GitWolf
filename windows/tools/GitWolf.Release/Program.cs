using GitWolf.Core;

// Signs a release archive and writes the update feed that includes it. The private key is read from
// GITWOLF_UPDATE_KEY only, so it never appears on a command line.
//
//   GitWolf.Release <archive> <version> <download url> <previous feed> <notes> <output feed>
//
// <previous feed> and <notes> may name files that don't exist yet.
if (args.Length != 6)
{
    Console.Error.WriteLine(
        "Usage: GitWolf.Release <archive> <version> <download url> <previous feed> <notes> <output feed>");
    return 2;
}
var key = Environment.GetEnvironmentVariable("GITWOLF_UPDATE_KEY");
if (string.IsNullOrWhiteSpace(key))
{
    Console.Error.WriteLine("GITWOLF_UPDATE_KEY is not set.");
    return 2;
}
try
{
    static string? ReadIfPresent(string path) => File.Exists(path) ? File.ReadAllText(path) : null;
    var feed = UpdatePublisher.Publish(File.ReadAllBytes(args[0]), args[1], args[2],
        ReadIfPresent(args[4]) ?? "", ReadIfPresent(args[3]), key, DateTimeOffset.UtcNow);
    File.WriteAllText(args[5], feed);
    Console.WriteLine($"Signed {Path.GetFileName(args[0])} and wrote {args[5]}.");
    return 0;
}
catch (Exception e) when (e is FormatException or IOException or UnauthorizedAccessException)
{
    Console.Error.WriteLine(e.Message);
    return 1;
}
