using System.ComponentModel;
using System.Diagnostics;
using GitWolf.App.Services;
using GitWolf.App.Views;
using GitWolf.Core;
using GitWolf.Store;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace GitWolf.App;

/// <summary>Opening the repository in other programs, and running custom actions on it.</summary>
public sealed partial class MainWindow
{
    private void SetUpOpenIn()
    {
        TopBar.OpenInRequested += ShowOpenInMenu;
        void Add(VirtualKey key, VirtualKeyModifiers modifiers, Action<RepositoryStore> run)
        {
            var accelerator = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
            accelerator.Invoked += (_, e) =>
            {
                // Ctrl+Alt is how AltGr arrives, which types characters such as € in a text box.
                if (FocusManager.GetFocusedElement(Root.XamlRoot) is TextBox || _store is not { } store) return;
                e.Handled = true;
                run(store);
            };
            Root.KeyboardAccelerators.Add(accelerator);
        }
        const VirtualKeyModifiers alternate = VirtualKeyModifiers.Control | VirtualKeyModifiers.Menu;
        Add(VirtualKey.T, alternate, OpenTerminal);
        Add(VirtualKey.E, alternate, OpenEditor);
        Add(VirtualKey.R, alternate | VirtualKeyModifiers.Shift, Reveal);
    }

    private void ShowOpenInMenu(FrameworkElement anchor)
    {
        if (_store is not { } store) return;
        var menu = new MenuFlyout
        {
            Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedRight,
        };
        void Add(string text, Action run)
        {
            var item = new MenuFlyoutItem { Text = text };
            item.Click += (_, _) => run();
            menu.Items.Add(item);
        }
        Add("Show in File Explorer", () => Reveal(store));
        Add("Open in Terminal", () => OpenTerminal(store));
        Add($"Open in {_settings.EditorName}", () => OpenEditor(store));
        menu.Items.Add(new MenuFlyoutSeparator());
        foreach (var action in _settings.Actions) Add(action.Name, () => RunAction(store, action));
        Add("Edit custom actions…", () => Settings.Open("Tools"));
        menu.ShowAt(anchor);
    }

    private void AddOpenInItems(List<PaletteItem> items)
    {
        if (_store is not { } store) return;
        void Add(string title, string subtitle, Action run) =>
            items.Add(new PaletteItem(Icons.OpenLink, title, subtitle, run));
        Add("Show in File Explorer", "Open in", () => Reveal(store));
        Add("Open in Terminal", "Open in", () => OpenTerminal(store));
        Add($"Open in {_settings.EditorName}", "Open in", () => OpenEditor(store));
        foreach (var action in _settings.Actions) Add(action.Name, "Custom action", () => RunAction(store, action));
    }

    private void Reveal(RepositoryStore store) => Start(OpenIn.Explorer(store.Id), "File Explorer");

    private void OpenTerminal(RepositoryStore store) => Start(OpenIn.Terminal(store.Id), "a terminal");

    private void OpenEditor(RepositoryStore store)
    {
        if (_settings.Editor is { } editor) Start(OpenIn.Editor(editor, store.Id), _settings.EditorName);
        else ShowError("No editor was found. Choose one in Settings > Tools.");
    }

    private void Start(ProcessStartInfo start, string what)
    {
        try
        {
            using var process = Process.Start(start);
        }
        catch (Exception e) when (e is Win32Exception or IOException)
        {
            Trace.TraceWarning($"Starting a program failed: {e.GetType().Name}");
            ShowError($"Couldn’t open {what}.");
        }
    }

    private void RunAction(RepositoryStore store, CustomAction action) => _ = RunActionAsync(store, action);

    private async Task RunActionAsync(RepositoryStore store, CustomAction action)
    {
        try
        {
            ShowNotice($"Running {action.Name}");
            await store.RunActionAsync(action,
                _settings.CustomGitPath ?? new GitRunner(Environment.SystemDirectory).GitPath);
        }
        catch (Exception e)
        {
            // Started from a click: report rather than lose the failure.
            Trace.TraceError($"A custom action failed: {e.GetType().Name}");
            ShowError($"“{action.Name}” couldn’t be run.");
        }
    }
}
