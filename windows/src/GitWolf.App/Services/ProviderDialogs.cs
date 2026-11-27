using System.Diagnostics;
using GitWolf.App.Views;
using GitWolf.Core;
using GitWolf.Store;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.System;

namespace GitWolf.App.Services;

/// <summary>
/// New pull request or issue, fork and notifications. Ported from NewCollabSheet.swift,
/// ForkSheet.swift and NotificationsSheet.swift.
/// </summary>
internal static class ProviderDialogs
{
    private static readonly string[] BaseBranches = ["main", "master", "develop", "trunk"];

    public static async Task NewCollabAsync(XamlRoot root, RepositoryStore store, CollabKind kind)
    {
        var pull = kind == CollabKind.PullRequest;
        var word = pull ? store.PullRequestsTitle.TrimEnd('s').ToLowerInvariant() : "issue";
        var head = store.Status.Branch;
        var title = new TextBox { Header = "Title" };
        var body = new TextBox
        {
            Header = "Description (Markdown)", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap,
            MinHeight = 120, MaxHeight = 220,
        };
        var content = new StackPanel { Spacing = 12, Width = 440 };
        var baseBranch = new ComboBox { Header = "Merge into", IsEditable = true, HorizontalAlignment = HorizontalAlignment.Stretch };
        var draft = new CheckBox { Content = "Create as draft" };
        if (pull)
        {
            var remote = store.Remotes.Contains("origin") ? "origin" : store.Remotes.FirstOrDefault();
            var branches = store.RemoteBranches
                .Where(b => remote is not null && b.Name.StartsWith(remote + "/", StringComparison.Ordinal))
                .Select(b => b.Name[(remote!.Length + 1)..])
                .Where(n => n != "HEAD" && n != head).ToList();
            foreach (var name in branches) baseBranch.Items.Add(name);
            var preferred = BaseBranches.FirstOrDefault(branches.Contains) ?? branches.FirstOrDefault();
            baseBranch.SelectedItem = preferred;
            content.Children.Add(Ui.Text(head is null ? "Check out a branch first." : $"From {head}"
                + (store.NeedsPush ? ". It will be pushed first." : ""), 12.5, secondary: true));
            content.Children.Add(baseBranch);
            // The title starts as the branch's latest commit subject.
            var tip = store.LocalBranches.FirstOrDefault(b => b.IsCurrent)?.Hash;
            title.Text = store.Commits.FirstOrDefault(c => tip is { Length: > 0 }
                && c.Hash.StartsWith(tip, StringComparison.Ordinal))?.Subject ?? head ?? "";
        }
        content.Children.Add(title);
        content.Children.Add(body);
        if (pull) content.Children.Add(draft);

        await RunAsync(root, $"New {word}", "Create", content, () => title.Text.Trim().Length > 0
            && (!pull || (head is not null && Base().Length > 0)), refresh =>
        {
            title.TextChanged += (_, _) => refresh();
            baseBranch.SelectionChanged += (_, _) => refresh();
            baseBranch.TextSubmitted += (_, _) => refresh();
        }, () => store.CreateCollabAsync(kind, title.Text.Trim(), body.Text.ReplaceLineEndings("\n"), Base(),
            draft.IsChecked == true));

        string Base() => (baseBranch.SelectedItem as string ?? baseBranch.Text ?? "").Trim();
    }

    public static async Task ForkAsync(XamlRoot root, RepositoryStore store)
    {
        if (!store.HasProviderAccount)
        {
            await Dialogs.ConfirmAsync(root, "Fork repository",
                "Add an account for this repository’s host in Settings → Accounts, then try again.", "OK");
            return;
        }
        var hasUpstream = store.Remotes.Contains("upstream");
        var origin = new RadioButton
        {
            Content = "Use the fork as “origin” and keep the original as “upstream”",
            IsEnabled = !hasUpstream, IsChecked = !hasUpstream,
        };
        var extra = new RadioButton { Content = "Add the fork as another remote", IsChecked = hasUpstream };
        var name = new TextBox { Header = "Remote name", Text = "fork" };
        var content = new StackPanel
        {
            Spacing = 10, Width = 440,
            Children =
            {
                Ui.Text($"This creates a copy of {store.RemoteLocation?.Path} under your account on "
                    + $"{store.RemoteLocation?.Host} and changes this checkout’s remotes.", 12.5),
                origin, extra, name,
            },
        };
        await RunAsync(root, "Fork repository", "Fork", content,
            () => extra.IsChecked != true || name.Text.Trim().Length > 0, refresh =>
            {
                origin.Checked += (_, _) => refresh();
                extra.Checked += (_, _) => refresh();
                name.TextChanged += (_, _) => refresh();
            }, () => store.ForkAsync(extra.IsChecked == true
                ? ForkRemoteMode.AddRemote(name.Text.Trim())
                : ForkRemoteMode.UseAsOrigin));
    }

    /// <summary>A form that stays open while its work runs and shows why it failed.</summary>
    private static async Task RunAsync(
        XamlRoot root, string title, string verb, StackPanel content, Func<bool> valid,
        Action<Action> watch, Func<Task> run)
    {
        var working = new ProgressBar { IsIndeterminate = true, Visibility = Visibility.Collapsed };
        var failure = Ui.Error("");
        content.Children.Add(working);
        content.Children.Add(failure);
        var dialog = new ContentDialog
        {
            RequestedTheme = (root.Content as FrameworkElement)?.ActualTheme ?? ElementTheme.Default,
            XamlRoot = root, Title = title, PrimaryButtonText = verb, CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            Content = new ScrollViewer { Content = content, MaxHeight = 520 },
        };
        var busy = false;
        void Refresh() => dialog.IsPrimaryButtonEnabled = !busy && valid();
        watch(Refresh);
        Refresh();
        dialog.PrimaryButtonClick += async (_, e) =>
        {
            e.Cancel = true;
            if (busy || !valid()) return;
            busy = true;
            Refresh();
            working.Visibility = Visibility.Visible;
            failure.Text = "";
            try
            {
                await run();
                busy = false;
                dialog.Hide();
            }
            catch (Exception error)
            {
                // An event handler can't pass the failure on, so every one is shown or logged here.
                Trace.TraceWarning($"{title} failed: {error.GetType().Name}");
                failure.Text = error is ProviderException or GitException
                    ? error.Message : "That didn’t work. Try again.";
            }
            finally
            {
                busy = false;
                working.Visibility = Visibility.Collapsed;
                Refresh();
            }
        };
        // Once started, the work can't be taken back, so the dialog waits for the answer.
        dialog.Closing += (_, e) => e.Cancel = busy;
        try
        {
            await dialog.ShowAsync();
        }
        catch (Exception e)
        {
            Trace.TraceWarning($"{title} dialog could not be shown: {e.GetType().Name}");
        }
    }

    public static async Task NotificationsAsync(XamlRoot root, NotificationsStore store)
    {
        var list = new StackPanel { Spacing = 2 };
        var working = new ProgressBar { IsIndeterminate = true };
        var refresh = Ui.Button("Refresh", () => _ = store.RefreshAsync());
        var readAll = Ui.Button("Mark all read", () => _ = store.MarkAllReadAsync());
        var content = new StackPanel
        {
            Spacing = 10, Width = 460,
            Children =
            {
                Ui.Row(8, refresh, readAll), working,
                new ScrollViewer { Content = list, Height = 380 },
            },
        };
        void Render()
        {
            working.Opacity = store.IsLoading ? 1 : 0;
            readAll.IsEnabled = store.UnreadCount > 0;
            list.Children.Clear();
            foreach (var problem in store.Problems)
                list.Children.Add(Ui.Error($"{problem.Account.Title}: {problem.Message}"));
            foreach (var entry in store.Entries) list.Children.Add(Row(store, entry));
            if (store.Entries.Count > 0 || store.IsLoading) return;
            list.Children.Add(Ui.Text(!store.HasAccounts
                ? "Add a GitHub, GitLab or Gitea account in Settings → Accounts to see notifications."
                : "You’re all caught up.", secondary: true));
        }
        var dialog = new ContentDialog
        {
            RequestedTheme = (root.Content as FrameworkElement)?.ActualTheme ?? ElementTheme.Default,
            XamlRoot = root, Title = "Notifications", Content = content, CloseButtonText = "Done",
        };
        store.Changed += Render;
        try
        {
            Render();
            _ = store.RefreshAsync();
            await dialog.ShowAsync();
        }
        catch (Exception e)
        {
            Trace.TraceWarning($"Notifications could not be shown: {e.GetType().Name}");
        }
        finally
        {
            store.Changed -= Render;
        }
    }

    private static UIElement Row(NotificationsStore store, NotificationsStore.Entry entry)
    {
        var note = entry.Note;
        var title = Ui.Text(note.Title, 13, bold: note.Unread);
        var detail = Ui.Text(
            $"{note.Repository} · {Words(note.Reason.ToString())} · {Ui.Ago(note.Updated)} · {entry.Account.Title}",
            11.5, secondary: true);
        var open = new Button
        {
            Content = new StackPanel { Spacing = 2, Children = { title, detail } },
            HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left,
            Background = null, BorderThickness = new Thickness(0), IsEnabled = note.Url is not null,
        };
        AutomationProperties.SetName(open, note.Title);
        open.Click += async (_, _) =>
        {
            if (note.Url is not { } url) return;
            await Launcher.LaunchUriAsync(url);
            await store.MarkReadAsync(entry);
        };
        var done = Ui.Button(new FontIcon { Glyph = "", FontSize = 12 }, () => _ = store.MarkReadAsync(entry),
            "Mark as read");
        ToolTipService.SetToolTip(done, "Mark as read");
        var row = new Grid
        {
            ColumnSpacing = 8,
            ColumnDefinitions = { new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto } },
        };
        Grid.SetColumn(done, 1);
        row.Children.Add(open);
        row.Children.Add(done);
        return row;
    }

    /// <summary>"ReviewRequested" becomes "review requested".</summary>
    private static string Words(string name) =>
        string.Concat(name.Select((c, i) => i > 0 && char.IsUpper(c) ? $" {c}" : $"{c}")).ToLowerInvariant();
}
