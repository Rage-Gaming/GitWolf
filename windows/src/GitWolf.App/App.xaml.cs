using Microsoft.UI.Xaml;

namespace GitWolf.App;

/// <summary>
/// App entry point. Mirrors apple/Sources/GitWolf/GitWolfApp.swift: owns the single
/// MainWindow and (eventually) the Workspace that tracks open repositories.
/// </summary>
public partial class App : Application
{
    private MainWindow? _window;

    private Services.SingleInstance? _instance;

    public App()
    {
        Services.LegacyMigration.Run();
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // `GitWolf.App.exe <folder>` opens that repository, in the running copy if there is one.
        var arguments = Environment.GetCommandLineArgs().Skip(1).ToArray();
        _instance = Services.SingleInstance.Claim(arguments);
        if (_instance is null) Environment.Exit(0);
        var window = _window = new MainWindow();
        window.ReleaseInstance = _instance.Dispose;
        window.Closed += (_, _) => _instance.Dispose();
        window.Activate();
        _ = window.StartAsync(arguments);
        _ = _instance.ListenAsync(window.Receive);
    }
}
