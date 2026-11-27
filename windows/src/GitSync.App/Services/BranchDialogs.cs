using System.Diagnostics;
using GitSync.Core;
using GitSync.Store;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitSync.App.Services;

/// <summary>Renaming and cleaning up branches, and stashing a hunk.</summary>
internal static class BranchDialogs
{
    public static async Task RenameAsync(XamlRoot root, RepositoryStore store, string branch)
    {
        if (await Dialogs.PromptAsync(root, "Rename branch", "new-name", "Rename", initial: branch) is { } name
            && name != branch)
            await store.RenameBranchAsync(branch, name);
    }

    public static async Task StashHunkAsync(
        XamlRoot root, RepositoryStore store, DiffTarget target, FileDiff diff, int hunk)
    {
        if (await Dialogs.PromptAsync(root, "Stash this hunk", "Message (optional)", "Stash", allowEmpty: true)
            is { } message)
            await store.StashHunkAsync(target, diff, hunk, message);
    }

    /// <summary>Lists merged and orphaned local branches, and deletes the ones ticked.</summary>
    public static async Task CleanupAsync(XamlRoot root, RepositoryStore store)
    {
        var baseRef = store.Status.Branch ?? "HEAD";
        if (await store.ReadAsync(r => r.CleanupCandidatesAsync(baseRef)) is not { } items) return;

        var content = new StackPanel { Spacing = 10, MinWidth = 420 };
        content.Children.Add(new TextBlock
        {
            Text = $"Local branches already merged into {baseRef}, or whose branch on the remote was deleted. "
                + "The current branch and main, master and develop are never listed.",
            TextWrapping = TextWrapping.Wrap, Opacity = 0.75,
        });
        var dialog = new ContentDialog
        {
            RequestedTheme = (root.Content as FrameworkElement)?.ActualTheme ?? ElementTheme.Default,
            XamlRoot = root, Title = "Clean up branches", Content = content,
            CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close,
        };

        var boxes = items.Select(item => new CheckBox
        {
            Content = Label(item), Tag = item, IsChecked = item.IsMerged, MinHeight = 32,
        }).ToList();
        var warning = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = Views.Palette.Orange };
        List<BranchCleanupItem> Chosen() =>
            boxes.Where(b => b.IsChecked == true).Select(b => (BranchCleanupItem)b.Tag).ToList();
        void Check()
        {
            var chosen = Chosen();
            var unmerged = chosen.Count(i => !i.IsMerged);
            warning.Text = unmerged == 0 ? ""
                : $"{(unmerged == 1 ? "1 selected branch has" : $"{unmerged} selected branches have")} commits that "
                    + "aren’t merged. Deleting loses them; only the reflog can recover them.";
            warning.Visibility = unmerged == 0 ? Visibility.Collapsed : Visibility.Visible;
            dialog.PrimaryButtonText = chosen.Count == 1 ? "Delete 1 branch" : $"Delete {chosen.Count} branches";
            dialog.IsPrimaryButtonEnabled = chosen.Count > 0;
        }

        if (items.Count == 0)
        {
            content.Children.Add(new TextBlock { Text = "Nothing to clean up." });
        }
        else
        {
            var list = new StackPanel();
            foreach (var box in boxes)
            {
                box.Checked += (_, _) => Check();
                box.Unchecked += (_, _) => Check();
                list.Children.Add(box);
            }
            content.Children.Add(new ScrollViewer { Content = list, MaxHeight = 300 });
            content.Children.Add(warning);
            Check();
        }

        try
        {
            if (await dialog.ShowAsync() == ContentDialogResult.Primary) await store.DeleteBranchesAsync(Chosen());
        }
        catch (Exception e)
        {
            // Fire-and-forget: e.g. a second dialog while one is already open.
            Trace.TraceWarning($"The cleanup dialog failed: {e.GetType().Name}");
        }
    }

    private static TextBlock Label(BranchCleanupItem item)
    {
        var why = item.Reason == CleanupReason.Merged ? "merged" : "remote deleted";
        if (!item.IsMerged) why += ", unmerged";
        var text = new TextBlock { TextTrimming = TextTrimming.CharacterEllipsis };
        text.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = item.Name });
        text.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run
        {
            Text = $"   {why}", FontSize = 12,
            Foreground = item.IsMerged ? Views.Palette.Green : Views.Palette.Orange,
        });
        return text;
    }
}
