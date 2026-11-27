using System.Net;
using System.Text;
using GitWolf.Core;

namespace GitWolfCore.Tests;

/// <summary>A transport that records each request and serves canned JSON.</summary>
internal sealed class StubHttp(Func<string, string> reply, HttpStatusCode status = HttpStatusCode.OK)
{
    public sealed record Call(string Method, string Url, string Body, Dictionary<string, string> Headers)
    {
        public string? Header(string name) => Headers.GetValueOrDefault(name);
    }

    private readonly object _lock = new();
    private readonly List<Call> _calls = [];

    public StubHttp(string reply = "{}", HttpStatusCode status = HttpStatusCode.OK) : this(_ => reply, status) { }

    /// <summary>Replies in order; the last one repeats.</summary>
    public static StubHttp Sequence(params string[] replies)
    {
        var index = 0;
        return new StubHttp(_ => replies[Math.Min(index++, replies.Length - 1)]);
    }

    public IReadOnlyList<Call> Calls
    {
        get { lock (_lock) return [.. _calls]; }
    }

    public async Task<(byte[], HttpStatusCode)> Send(HttpRequestMessage request)
    {
        // The request is disposed after sending, so everything is read now.
        var body = request.Content is null ? "" : await request.Content.ReadAsStringAsync();
        var headers = request.Headers.ToDictionary(h => h.Key, h => string.Join(",", h.Value),
            StringComparer.OrdinalIgnoreCase);
        var url = request.RequestUri!.AbsoluteUri;
        lock (_lock)
        {
            _calls.Add(new Call(request.Method.Method, url, body, headers));
            return (Encoding.UTF8.GetBytes(reply(url)), status);
        }
    }

    public ProviderClient Client(ProviderKind kind, string? host = null, string token = "t") =>
        new(new ProviderAccount(kind, host ?? kind.DefaultHost(), "me"), token, Send);
}
