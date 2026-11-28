using System.Diagnostics;
using System.Runtime.InteropServices;
using GitWolf.App.Services;
using GitWolf.Core;
using Microsoft.UI.Windowing;

namespace GitWolf.App;

/// <summary>Requests to open a folder from the command line, a link or another copy of the app.</summary>
public sealed partial class MainWindow
{
    /// <summary>Completed once last session's repositories are back; later requests wait for it.</summary>
    private readonly TaskCompletionSource _started = new();

    /// <summary>Lets the next copy of the app run, before this one restarts itself.</summary>
    internal Action? ReleaseInstance { get; set; }

    /// <summary>Restores the last session, then opens what the command line asked for.</summary>
    internal async Task StartAsync(string[] arguments)
    {
        try
        {
            // Restore first: opening saves the list, which would otherwise replace the saved one.
            await _workspace.RestoreAsync();
            Diff.IsSplit = _workspace.SplitDiff;
        }
        catch (Exception e)
        {
            // Fire-and-forget from launch: report rather than lose the failure.
            Trace.TraceError($"Startup failed: {e.GetType().Name}");
            ShowError("The last session couldn’t be restored.");
        }
        finally
        {
            _started.TrySetResult();
        }
        await LaunchAsync(arguments);
    }

    /// <summary>Called on any thread with a later copy's command line.</summary>
    internal void Receive(string[] arguments) => DispatcherQueue.TryEnqueue(() =>
    {
        BringToFront();
        _ = LaunchAsync(arguments);
    });

    internal void BringToFront()
    {
        AppWindow.Show();
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } presenter)
            presenter.Restore();
        Activate();
        SetForegroundWindow(WindowHandle);
    }

    private async Task LaunchAsync(string[] arguments)
    {
        try
        {
            await _started.Task;
            if (arguments.Length == 0) return;
            if (await Task.Run(() => LaunchRequest.Parse(arguments)) is not { } target)
            {
                ShowError("There’s no folder GitWolf can open in that request.");
                return;
            }
            // A web page can follow a link, and opening a repository runs Git inside it.
            if (target.FromLink && !await Dialogs.ConfirmAsync(Root.XamlRoot, "Open this folder?",
                    $"A link asked GitWolf to open:\n\n{target.Folder}\n\nOnly continue if you trust this folder.",
                    "Open")) return;
            await OpenAsync(target.Folder);
        }
        catch (Exception e)
        {
            Trace.TraceError($"Opening a requested folder failed: {e.GetType().Name}");
            ShowError("The folder couldn’t be opened.");
        }
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(nint window);
}
