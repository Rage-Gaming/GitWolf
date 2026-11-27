using Microsoft.UI.Xaml;

namespace GitWolf.App;

/// <summary>
/// App entry point. Mirrors apple/Sources/GitWolf/GitWolfApp.swift: owns the single
/// MainWindow and (eventually) the Workspace that tracks open repositories.
/// </summary>
public partial class App : Application
{
    private MainWindow? _window;

    public App()
    {
        Services.LegacyMigration.Run();
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        _window.Activate();

        // `GitWolf.App.exe <folder>` opens that repository.
        var arguments = Environment.GetCommandLineArgs();
        _ = _window.StartAsync(arguments.Length > 1 ? arguments[1] : null);
    }
}
