using System.Text;
using System.Text.RegularExpressions;

namespace GitWolf.Core;

// A small, safe subset of Markdown for pull request and issue text, mirroring MarkdownView.swift. The
// text is untrusted: nothing is executed, no HTML is rendered, no image is downloaded and only http
// and https links are kept.

public enum MarkdownBlockKind { Heading, Paragraph, Bullet, Numbered, Task, Quote, Code, Rule, Table }

/// <param name="Level">Heading level, or the nesting depth of a list item.</param>
/// <param name="Marker">The number of a numbered item.</param>
public sealed record MarkdownBlock(
    MarkdownBlockKind Kind, string Text = "", int Level = 0, string Marker = "", bool Checked = false);

public sealed record MarkdownSpan(
    string Text, bool Bold = false, bool Italic = false, bool Code = false, bool Strike = false, Uri? Link = null);

public static partial class Markdown
{
    /// <summary>Longer text is cut, so a huge description can't stall the window.</summary>
    public const int MaxLength = 60_000;

    public static List<MarkdownBlock> Parse(string source)
    {
        if (source.Length > MaxLength) source = source[..MaxLength] + "\n\n…";
        var lines = Comments().Replace(source.ReplaceLineEndings("\n"), "").Split('\n');
        var blocks = new List<MarkdownBlock>();
        var paragraph = new List<string>();

        void Flush()
        {
            if (paragraph.Count == 0) return;
            blocks.Add(new MarkdownBlock(MarkdownBlockKind.Paragraph, string.Join('\n', paragraph)));
            paragraph.Clear();
        }
        void Add(MarkdownBlock block)
        {
            Flush();
            blocks.Add(block);
        }

        for (var i = 0; i < lines.Length; i++)
        {
            var line = lines[i];
            var trimmed = line.Trim();
            if (trimmed.StartsWith("```", StringComparison.Ordinal) || trimmed.StartsWith("~~~", StringComparison.Ordinal))
            {
                var fence = trimmed[..3];
                var code = new List<string>();
                while (++i < lines.Length && !lines[i].Trim().StartsWith(fence, StringComparison.Ordinal)) code.Add(lines[i]);
                Add(new MarkdownBlock(MarkdownBlockKind.Code, string.Join('\n', code)));
            }
            else if (trimmed.Length == 0) Flush();
            else if (HeadingLine().Match(trimmed) is { Success: true } heading)
                Add(new MarkdownBlock(MarkdownBlockKind.Heading, heading.Groups[2].Value, heading.Groups[1].Length));
            else if (RuleLine().IsMatch(trimmed)) Add(new MarkdownBlock(MarkdownBlockKind.Rule));
            else if (TaskLine().Match(line) is { Success: true } task)
                Add(new MarkdownBlock(MarkdownBlockKind.Task, task.Groups[3].Value, Depth(task.Groups[1].Value),
                    Checked: task.Groups[2].Value is "x" or "X"));
            else if (BulletLine().Match(line) is { Success: true } bullet)
                Add(new MarkdownBlock(MarkdownBlockKind.Bullet, bullet.Groups[2].Value, Depth(bullet.Groups[1].Value)));
            else if (NumberLine().Match(line) is { Success: true } number)
                Add(new MarkdownBlock(MarkdownBlockKind.Numbered, number.Groups[3].Value, Depth(number.Groups[1].Value),
                    number.Groups[2].Value));
            else if (trimmed.StartsWith('>'))
            {
                var quote = new List<string> { trimmed[1..].TrimStart() };
                while (i + 1 < lines.Length && lines[i + 1].TrimStart().StartsWith('>'))
                    quote.Add(lines[++i].TrimStart()[1..].TrimStart());
                Add(new MarkdownBlock(MarkdownBlockKind.Quote, string.Join('\n', quote)));
            }
            else if (trimmed.StartsWith('|'))
            {
                var rows = new List<string> { trimmed };
                while (i + 1 < lines.Length && lines[i + 1].TrimStart().StartsWith('|')) rows.Add(lines[++i].Trim());
                Add(new MarkdownBlock(MarkdownBlockKind.Table, string.Join('\n', rows)));
            }
            else paragraph.Add(trimmed);
        }
        Flush();
        return blocks;
    }

    private static int Depth(string indent) => Math.Min(4, indent.Replace("\t", "    ").Length / 2);

    /// <summary>Bold, italic, code, strikethrough and links within one block.</summary>
    public static List<MarkdownSpan> Inline(string text)
    {
        var spans = new List<MarkdownSpan>();
        Inline(text, new MarkdownSpan(""), spans, 0);
        return spans;
    }

    private static void Inline(string text, MarkdownSpan style, List<MarkdownSpan> spans, int depth)
    {
        var at = 0;
        if (depth < 4)
        {
            foreach (Match m in Token().Matches(text))
            {
                if (m.Index > at) Plain(text[at..m.Index]);
                at = m.Index + m.Length;
                if (m.Groups["escape"].Success) Plain(m.Groups["escape"].Value);
                else if (m.Groups["code"].Success) spans.Add(style with { Text = m.Groups["code"].Value, Code = true });
                else if (m.Groups["bold"].Success)
                    Inline(m.Groups["bold"].Value, style with { Bold = true }, spans, depth + 1);
                else if (m.Groups["strike"].Success)
                    Inline(m.Groups["strike"].Value, style with { Strike = true }, spans, depth + 1);
                else if (m.Groups["italic"].Success)
                    Inline(m.Groups["italic"].Value, style with { Italic = true }, spans, depth + 1);
                else if (m.Groups["url"].Success)
                {
                    var label = m.Groups["label"].Value;
                    spans.Add(style with
                    {
                        Text = label.Length > 0 ? label : m.Groups["image"].Length > 0 ? "image" : m.Groups["url"].Value,
                        Link = SafeLink(m.Groups["url"].Value),
                    });
                }
                else
                {
                    var address = m.Groups["bare"].Value.TrimEnd('.', ',', ';', ':', '!', '?');
                    spans.Add(style with { Text = address, Link = SafeLink(address) });
                    at = m.Index + address.Length;
                }
            }
        }
        if (at < text.Length) Plain(text[at..]);

        void Plain(string value) => spans.Add(style with { Text = value });
    }

    /// <summary>Only web addresses can be opened: never files, scripts or other apps' schemes.</summary>
    public static Uri? SafeLink(string address) =>
        Uri.TryCreate(address, UriKind.Absolute, out var url)
        && (url.Scheme == Uri.UriSchemeHttps || url.Scheme == Uri.UriSchemeHttp) && url.UserInfo.Length == 0
            ? url : null;

    // Every pattern has a time limit as a second guard against pathological input.
    [GeneratedRegex(@"<!--.*?(-->|$)", RegexOptions.Singleline, 500)]
    private static partial Regex Comments();

    [GeneratedRegex(@"^(#{1,6})\s+(.*?)\s*#*$", RegexOptions.None, 500)]
    private static partial Regex HeadingLine();

    [GeneratedRegex(@"^([-*_])(\s*\1){2,}$", RegexOptions.None, 500)]
    private static partial Regex RuleLine();

    [GeneratedRegex(@"^(\s*)[-*+]\s+\[([ xX])\]\s+(.*)$", RegexOptions.None, 500)]
    private static partial Regex TaskLine();

    [GeneratedRegex(@"^(\s*)[-*+]\s+(.*)$", RegexOptions.None, 500)]
    private static partial Regex BulletLine();

    [GeneratedRegex(@"^(\s*)(\d{1,9})[.)]\s+(.*)$", RegexOptions.None, 500)]
    private static partial Regex NumberLine();

    [GeneratedRegex(
        @"\\(?<escape>[\\`*_~\[\]()#!>-])"
        + @"|`(?<code>[^`\n]+)`"
        + @"|(?<image>!?)\[(?<label>[^\[\]\n]{0,500})\]\((?<url>[^()\s]{1,2000})(?:\s+""[^""\n]*"")?\)"
        + @"|\*\*(?<bold>[^\n]+?)\*\*"
        + @"|(?<!\w)__(?<bold>[^\n]+?)__(?!\w)"
        + @"|~~(?<strike>[^\n]+?)~~"
        + @"|\*(?<italic>[^*\s][^*\n]*?)\*"
        + @"|(?<!\w)_(?<italic>[^_\n]+?)_(?!\w)"
        + @"|(?<bare>https?://[^\s<>()\[\]""']+)",
        RegexOptions.None, 500)]
    private static partial Regex Token();
}
