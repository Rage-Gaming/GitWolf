using Microsoft.UI.Xaml;

namespace GitSync.App;

/// <summary>
/// App entry point. Mirrors apple/Sources/GitSync/GitSyncApp.swift: owns the single
/// MainWindow and (eventually) the Workspace that tracks open repositories.
/// </summary>
public partial class App : Application
{
    private MainWindow? _window;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        _window.Activate();

        // `GitSync.App.exe <folder>` opens that repository.
        var arguments = Environment.GetCommandLineArgs();
        _ = _window.StartAsync(arguments.Length > 1 ? arguments[1] : null);
    }
}
