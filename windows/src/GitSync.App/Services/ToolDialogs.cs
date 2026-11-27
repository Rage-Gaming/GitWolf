using System.Diagnostics;
using GitSync.Store;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;

namespace GitSync.App.Services;

/// <summary>Saving and applying patch files. Ported from StoreScale.swift.</summary>
internal static class ToolDialogs
{
    /// <summary>The main window, which owns the file pickers.</summary>
    internal static IntPtr Window { get; set; }

    public static async Task ExportPatchAsync(XamlRoot root, RepositoryStore store, string hash)
    {
        if (await PickFolderAsync(Window, store) is { } folder) await store.ExportPatchAsync(hash, folder);
    }

    /// <returns>The chosen folder, or null when cancelled or the picker failed.</returns>
    internal static async Task<string?> PickFolderAsync(IntPtr window, RepositoryStore store)
    {
        try
        {
            var picker = new FolderPicker();
            picker.FileTypeFilter.Add("*");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, window);
            return (await picker.PickSingleFolderAsync())?.Path;
        }
        catch (Exception e)
        {
            Trace.TraceWarning($"Choosing a folder failed: {e.GetType().Name}");
            store.ErrorMessage = "The folder picker couldn’t be opened.";
            return null;
        }
    }

    public static async Task SavePatchAsync(RepositoryStore store, IntPtr window)
    {
        // Checked first: the save picker creates the file before anything is written to it.
        var status = store.Status;
        if (status.Staged.Count + status.Unstaged.Count + status.Conflicted.Count == 0)
        {
            store.ErrorMessage = "There are no changes to tracked files to save.";
            return;
        }
        try
        {
            var picker = new FileSavePicker { SuggestedFileName = $"{store.Name}-changes" };
            picker.FileTypeChoices.Add("Patch", [".patch"]);
            WinRT.Interop.InitializeWithWindow.Initialize(picker, window);
            if (await picker.PickSaveFileAsync() is { } file) await store.SaveWorkingPatchAsync(file.Path);
        }
        catch (Exception e)
        {
            Trace.TraceWarning($"Saving a patch failed: {e.GetType().Name}");
            store.ErrorMessage = "The patch couldn’t be saved.";
        }
    }

    public static async Task ApplyPatchesAsync(XamlRoot root, RepositoryStore store, IntPtr window)
    {
        try
        {
            var picker = new FileOpenPicker();
            foreach (var type in new[] { ".patch", ".diff", ".mbox", "*" }) picker.FileTypeFilter.Add(type);
            WinRT.Interop.InitializeWithWindow.Initialize(picker, window);
            var picked = await picker.PickMultipleFilesAsync();
            if (picked.Count == 0) return;
            // Numbered patches must be applied in order.
            var files = picked.Select(f => f.Path).Order(StringComparer.OrdinalIgnoreCase).ToList();
            var mailbox = await Task.Run(() => files.All(IsMailbox));
            if (await store.PatchProblemAsync(files, mailbox) is { } problem)
            {
                store.ErrorMessage = problem;
                return;
            }
            await ChooseAsync(root, store, files, mailbox);
        }
        catch (Exception e)
        {
            Trace.TraceWarning($"Applying a patch failed: {e.GetType().Name}");
            store.ErrorMessage = "The patch couldn’t be applied.";
        }
    }

    /// <summary>True for a patch that carries an author and message, as `git format-patch` writes.</summary>
    private static bool IsMailbox(string file)
    {
        using var reader = new StreamReader(file);
        var start = new char[5];
        return reader.ReadBlock(start, 0, 5) == 5 && new string(start) == "From ";
    }

    private static async Task ChooseAsync(
        XamlRoot root, RepositoryStore store, IReadOnlyList<string> files, bool mailbox)
    {
        var commits = new RadioButton { Content = "Apply as commits, keeping author and message" };
        var stage = new RadioButton { Content = "Apply and stage" };
        var plain = new RadioButton { Content = "Apply to the working files only" };
        var content = new StackPanel { Spacing = 4, MinWidth = 380 };
        content.Children.Add(new TextBlock
        {
            Text = string.Join("\n", files.Select(Path.GetFileName)), TextWrapping = TextWrapping.Wrap,
            FontSize = 12, Opacity = 0.75, MaxLines = 8, Margin = new Thickness(0, 0, 0, 8),
        });
        if (mailbox) content.Children.Add(commits);
        content.Children.Add(stage);
        content.Children.Add(plain);
        (mailbox ? commits : plain).IsChecked = true;
        var dialog = new ContentDialog
        {
            RequestedTheme = (root.Content as FrameworkElement)?.ActualTheme ?? ElementTheme.Default,
            XamlRoot = root, Title = files.Count == 1 ? "Apply patch" : $"Apply {files.Count} patches",
            Content = content, PrimaryButtonText = "Apply", CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            await store.ApplyPatchFilesAsync(files, commits.IsChecked == true, stage.IsChecked == true);
    }
}
