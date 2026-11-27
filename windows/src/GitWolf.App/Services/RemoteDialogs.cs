using System.Diagnostics;
using GitWolf.Core;
using GitWolf.Store;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace GitWolf.App.Services;

/// <summary>Force push, a refused push, and the list of remotes.</summary>
internal static class RemoteDialogs
{
    /// <summary>Fetches, lists what a force push would replace, then does exactly that.</summary>
    public static async Task ForcePushAsync(XamlRoot root, RepositoryStore store, string? remote)
    {
        if (await store.PlanForcePushAsync(remote) is not { } plan) return;
        var target = $"{plan.Remote}/{plan.Target}";
        var text = plan switch
        {
            { Expected: null } => $"“{target}” doesn’t exist yet, so nothing on the remote is replaced.",
            { LostCount: 0 } => $"This updates “{target}” to your “{plan.Branch}”. No commits are lost.",
            _ => $"This replaces “{target}” with your “{plan.Branch}”. "
                + $"{plan.LostCount} commit{(plan.LostCount == 1 ? "" : "s")} will be removed from it:\n\n"
                + string.Join("\n", plan.Lost)
                + (plan.LostCount > plan.Lost.Count ? $"\nand {plan.LostCount - plan.Lost.Count} more" : ""),
        };
        if (await Dialogs.ConfirmAsync(root, $"Force push “{plan.Branch}”?",
                text + "\n\nThe push is refused if the remote branch changes after this.", "Force push"))
            await store.PushAsync(new PushOptions(Force: plan));
    }

    /// <summary>The remote refused the push: explains and offers the two ways forward.</summary>
    public static async Task PushRejectedAsync(XamlRoot root, RepositoryStore store, PushOptions options)
    {
        var dialog = Dialog(root, "The remote has commits you don’t have", new TextBlock
        {
            MaxWidth = 420, TextWrapping = TextWrapping.Wrap,
            Text = "Pull them first, then push again. Or force push to overwrite the remote branch with yours "
                + "(commits that exist only there are lost).",
        });
        dialog.PrimaryButtonText = "Pull";
        dialog.SecondaryButtonText = "Force push…";
        dialog.CloseButtonText = "Cancel";
        dialog.DefaultButton = ContentDialogButton.Primary;
        switch (await ShowAsync(dialog))
        {
            case ContentDialogResult.Primary:
                await store.PullAsync();
                break;
            case ContentDialogResult.Secondary:
                await ForcePushAsync(root, store, options.Remote);
                break;
            case null:
                store.ErrorMessage = "The push was refused: the remote has commits you don’t have. Pull, then push.";
                break;
        }
    }

    /// <summary>
    /// Lists the remotes to add, edit, remove, fetch and push. Everything happens inside one dialog,
    /// as WinUI can't stack them.
    /// </summary>
    public static async Task ManageAsync(XamlRoot root, RepositoryStore store)
    {
        var body = new StackPanel { Spacing = 14, Width = 440 };
        var dialog = Dialog(root, "Remotes", new ScrollViewer { Content = body, MaxHeight = 440 });
        dialog.CloseButtonText = "Done";
        Func<Task>? after = null;

        // Closes the dialog first, so a question the operation raises can be shown.
        void CloseThen(Func<Task> run)
        {
            after = run;
            dialog.Hide();
        }

        async Task ListAsync()
        {
            var remotes = await store.RemoteInfosAsync();
            body.Children.Clear();
            if (remotes is null)
            {
                body.Children.Add(Note(store.ErrorMessage ?? "The remotes couldn’t be read."));
                return;
            }
            if (remotes.Count == 0) body.Children.Add(Note("This repository has no remotes."));
            foreach (var remote in remotes)
            {
                var entry = new StackPanel { Spacing = 4 };
                entry.Children.Add(new TextBlock { Text = remote.Name, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
                entry.Children.Add(Note(remote.FetchUrl, selectable: true));
                if (remote.PushUrl != remote.FetchUrl)
                    entry.Children.Add(Note($"Pushes to {remote.PushUrl}", selectable: true));
                entry.Children.Add(Row(
                    Action("Fetch", remote.Name, () => CloseThen(() => store.FetchRemoteAsync(remote.Name))),
                    Action("Push", remote.Name,
                        () => CloseThen(() => store.PushAsync(new PushOptions(Remote: remote.Name))),
                        store.Status.Branch is not null),
                    Action("Edit", remote.Name, () => Edit(remote)),
                    Action("Remove", remote.Name, () => ConfirmRemove(remote.Name))));
                body.Children.Add(entry);
            }
            body.Children.Add(Action("Add remote", null, () => Edit(null)));
        }

        void ConfirmRemove(string name)
        {
            var failure = Note("");
            body.Children.Clear();
            body.Children.Add(Note($"Remove “{name}”? Its remote branches and tracking settings are removed "
                + "from this repository. Nothing changes on the server."));
            body.Children.Add(failure);
            body.Children.Add(Row(
                Action("Remove remote", name, () => _ = ApplyAsync(() => store.RemoveRemoteAsync(name), failure)),
                Action("Cancel", null, () => _ = ListAsync())));
        }

        void Edit(RemoteInfo? remote)
        {
            var name = new TextBox { Header = "Name", Text = remote?.Name ?? "", PlaceholderText = "origin" };
            var url = new TextBox
            {
                Header = "URL", Text = remote?.FetchUrl ?? "", PlaceholderText = "https://host/owner/repo.git",
            };
            var failure = Note("");
            body.Children.Clear();
            body.Children.Add(name);
            body.Children.Add(url);
            body.Children.Add(failure);
            body.Children.Add(Row(
                Action(remote is null ? "Add" : "Save", null, () =>
                {
                    var (newName, newUrl) = (name.Text.Trim(), url.Text.Trim());
                    // An unchanged address isn't written back: what is shown has any password removed.
                    _ = ApplyAsync(() => remote is null
                        ? store.AddRemoteAsync(newName, newUrl)
                        : store.EditRemoteAsync(remote.Name, newName, newUrl == remote.FetchUrl ? null : newUrl), failure);
                }),
                Action("Cancel", null, () => _ = ListAsync())));
        }

        async Task ApplyAsync(Func<Task<bool>> operation, TextBlock failure)
        {
            if (store.IsBusy)
            {
                failure.Text = "Wait for the current operation to finish, then try again.";
                return;
            }
            if (await operation()) await ListAsync();
            else failure.Text = store.ErrorMessage ?? "That didn’t work.";
        }

        await ListAsync();
        await ShowAsync(dialog);
        if (after is not null) await after();
    }

    private static ContentDialog Dialog(XamlRoot root, string title, UIElement content) => new()
    {
        // Dialogs don't inherit a theme forced on the window content.
        RequestedTheme = (root.Content as FrameworkElement)?.ActualTheme ?? ElementTheme.Default,
        XamlRoot = root, Title = title, Content = content,
    };

    /// <summary>Null when the dialog couldn't be shown (WinUI allows one at a time).</summary>
    private static async Task<ContentDialogResult?> ShowAsync(ContentDialog dialog)
    {
        try
        {
            return await dialog.ShowAsync();
        }
        catch (Exception e)
        {
            Trace.TraceWarning($"Dialog could not be shown: {e.GetType().Name}");
            return null;
        }
    }

    private static TextBlock Note(string text, bool selectable = false) => new()
    {
        Text = text, TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = 0.75,
        IsTextSelectionEnabled = selectable,
    };

    private static StackPanel Row(params Button[] buttons)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var button in buttons) row.Children.Add(button);
        return row;
    }

    private static Button Action(string text, string? subject, Action run, bool enabled = true)
    {
        var button = new Button { Content = text, IsEnabled = enabled };
        if (subject is not null) AutomationProperties.SetName(button, $"{text} {subject}");
        button.Click += (_, _) => run();
        return button;
    }
}
