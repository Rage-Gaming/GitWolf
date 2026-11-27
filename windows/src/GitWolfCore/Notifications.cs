namespace GitWolf.Core;

// Ported from apple/Sources/GitWolfCore/Notifications.swift.

public enum NotificationReason { ReviewRequested, Mention, Assigned, Other }

/// <summary>Something that needs your attention on a hosting provider (a review request, a mention…).</summary>
public sealed record ProviderNotification(
    string Id, string Title, string Repository, NotificationReason Reason, bool IsPullRequest,
    DateTimeOffset? Updated, Uri? Url, bool Unread = true);

public static class NotificationExtensions
{
    public static bool SupportsNotifications(this ProviderKind kind) =>
        kind is ProviderKind.GitHub or ProviderKind.GitLab or ProviderKind.Gitea;

    public static string Title(this NotificationReason reason) => reason switch
    {
        NotificationReason.ReviewRequested => "Review requested",
        NotificationReason.Mention => "Mentioned",
        NotificationReason.Assigned => "Assigned",
        _ => "Activity",
    };
}

public sealed partial class ProviderClient
{
    /// <summary>
    /// Review requests, mentions and assignments waiting for you. GitHub needs the `notifications`
    /// token scope; GitLab uses your to-do list.
    /// </summary>
    public async Task<List<ProviderNotification>> NotificationsAsync() =>
        (await ReadNotificationsAsync()).Select(n => n with { Url = Openable(n.Url) }).ToList();

    private async Task<List<ProviderNotification>> ReadNotificationsAsync() => Account.Kind switch
    {
        ProviderKind.GitHub => ParseGitHubNotifications(
            await FetchAsync($"{ApiBase}/notifications?participating=true&per_page=50"), Account.Origin),
        ProviderKind.GitLab => ParseGitLabTodos(await FetchAsync($"{ApiBase}/todos?state=pending&per_page=50")),
        ProviderKind.Gitea => ParseGiteaNotifications(
            await FetchAsync($"{ApiBase}/notifications?status-types=unread&limit=50")),
        _ => throw ProviderException.Unsupported($"{Account.Kind.Title()} has no notifications API."),
    };

    public async Task MarkReadAsync(ProviderNotification notification)
    {
        var id = Uri.EscapeDataString(notification.Id);
        if (id is "." or "..") throw ProviderException.InvalidResponse;
        if (Account.Kind is ProviderKind.GitHub or ProviderKind.Gitea)
            await SendAsync(HttpMethod.Patch, $"{ApiBase}/notifications/threads/{id}");
        else if (Account.Kind == ProviderKind.GitLab)
            await SendAsync(HttpMethod.Post, $"{ApiBase}/todos/{id}/mark_as_done");
    }

    public async Task MarkAllReadAsync()
    {
        if (Account.Kind == ProviderKind.GitHub)
            await SendAsync(HttpMethod.Put, $"{ApiBase}/notifications", new { });
        else if (Account.Kind == ProviderKind.Gitea)
            await SendAsync(HttpMethod.Put, $"{ApiBase}/notifications");
        else if (Account.Kind == ProviderKind.GitLab)
            await SendAsync(HttpMethod.Post, $"{ApiBase}/todos/mark_as_done");
    }

    // MARK: Parsing

    internal static NotificationReason ReasonFor(string? raw) => raw switch
    {
        "review_requested" or "approval_required" => NotificationReason.ReviewRequested,
        "mention" or "team_mention" or "mentioned" or "directly_addressed" => NotificationReason.Mention,
        "assign" or "assigned" => NotificationReason.Assigned,
        _ => NotificationReason.Other,
    };

    /// <summary>`https://api.github.com/repos/o/r/pulls/12` → `https://github.com/o/r/pull/12`.</summary>
    internal static Uri? GitHubWebUrl(string? api, string webBase)
    {
        if (!Uri.TryCreate(api, UriKind.Absolute, out var url)) return null;
        var parts = url.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var repos = Array.IndexOf(parts, "repos");
        if (repos < 0 || parts.Length < repos + 4) return null;
        var path = $"/{parts[repos + 1]}/{parts[repos + 2]}";
        var kind = parts[repos + 3];
        if (parts.Length > repos + 4)
        {
            var number = parts[repos + 4];
            path += kind switch
            {
                "pulls" => $"/pull/{number}", "issues" => $"/issues/{number}", "commits" => $"/commit/{number}", _ => "",
            };
        }
        return Link(webBase + path);
    }

    internal static List<ProviderNotification> ParseGitHubNotifications(byte[] data, string webBase)
    {
        var result = new List<ProviderNotification>();
        foreach (var r in ArrayOf(data))
        {
            if (GetString(r, "id") is not { } id || Property(r, "subject") is not { } subject
                || GetString(subject, "title") is not { } title) continue;
            result.Add(new ProviderNotification(
                id, title, Nested(r, "repository", "full_name"), ReasonFor(GetString(r, "reason")),
                GetString(subject, "type") == "PullRequest", Iso(GetString(r, "updated_at")),
                GitHubWebUrl(GetString(subject, "url"), webBase), GetBool(r, "unread", true)));
        }
        return result;
    }

    internal static List<ProviderNotification> ParseGitLabTodos(byte[] data)
    {
        var result = new List<ProviderNotification>();
        foreach (var r in ArrayOf(data))
        {
            if (GetInt(r, "id") is not { } id) continue;
            var title = Nested(r, "target", "title");
            if (title.Length == 0) title = GetString(r, "body") ?? "";
            if (title.Length == 0) continue;
            result.Add(new ProviderNotification(
                id.ToString(), title, Nested(r, "project", "path_with_namespace"), ReasonFor(GetString(r, "action_name")),
                GetString(r, "target_type") == "MergeRequest", Iso(GetString(r, "updated_at")),
                Link(GetString(r, "target_url"))));
        }
        return result;
    }

    internal static List<ProviderNotification> ParseGiteaNotifications(byte[] data)
    {
        var result = new List<ProviderNotification>();
        foreach (var r in ArrayOf(data))
        {
            if (GetInt(r, "id") is not { } id || Property(r, "subject") is not { } subject
                || GetString(subject, "title") is not { } title) continue;
            result.Add(new ProviderNotification(
                id.ToString(), title, Nested(r, "repository", "full_name"), NotificationReason.Other,
                GetString(subject, "type") == "Pull", Iso(GetString(r, "updated_at")),
                Link(GetString(subject, "html_url")), GetBool(r, "unread", true)));
        }
        return result;
    }
}
