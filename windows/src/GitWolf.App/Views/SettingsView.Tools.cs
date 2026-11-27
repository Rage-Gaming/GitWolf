using GitWolf.App.Services;
using GitWolf.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace GitWolf.App.Views;

/// <summary>The editor used by "Open in", and custom actions.</summary>
public sealed partial class SettingsView
{
    private void Tools(AppSettings settings)
    {
        Editor(settings);
        CustomActions(settings);
    }

    private void Editor(AppSettings settings)
    {
        var path = new TextBox
        {
            Text = settings.State.EditorPath, FontFamily = new FontFamily("Consolas"),
            PlaceholderText = OpenIn.FindDefaultEditor() ?? "Visual Studio Code was not found",
        };
        AutomationProperties.SetName(path, "Editor program");
        var status = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, Foreground = Palette.Orange };
        void Describe()
        {
            status.Text = settings.State.EditorPath.Length == 0 || settings.Editor is not null
                ? "" : "Not a local .exe file given as a full path.";
            status.Visibility = status.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        }
        path.TextChanged += (_, _) =>
        {
            settings.Update(settings.State with { EditorPath = path.Text });
            Describe();
        };
        var choose = new Button { Content = "Choose…" };
        choose.Click += async (_, _) =>
        {
            if (await PickExecutableAsync() is { } file) path.Text = file;
        };
        var reset = new Button { Content = "Reset" };
        reset.Click += (_, _) => path.Text = "";
        var note = new TextBlock
        {
            Text = "The program “Open in” uses for code. Leave empty for Visual Studio Code.",
            FontSize = 12, Opacity = 0.65, TextWrapping = TextWrapping.Wrap,
        };
        Describe();
        Group("Editor", new StackPanel
        {
            Padding = new Thickness(12), Spacing = 10,
            Children =
            {
                path,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { choose, reset } },
                status, note,
            },
        });
    }

    private void CustomActions(AppSettings settings)
    {
        var rows = new StackPanel { Padding = new Thickness(12), Spacing = 8 };
        var add = new Button { Content = "Add Action" };
        IReadOnlyList<CustomAction> All() => settings.State.CustomActions ?? [];
        void Save(IEnumerable<CustomAction> actions)
        {
            settings.Update(settings.State with { CustomActions = actions.ToList() });
            add.IsEnabled = All().Count < AppSettings.MaxActions;
        }
        void AddRow(CustomAction action)
        {
            var name = new TextBox
            {
                Text = action.Name, PlaceholderText = "Name", MaxLength = 100,
            };
            AutomationProperties.SetName(name, "Action name");
            var command = new TextBox
            {
                Text = action.Command, PlaceholderText = "Command, e.g. make test", MaxLength = 4000,
                FontFamily = new FontFamily("Consolas"), IsSpellCheckEnabled = false,
            };
            AutomationProperties.SetName(command, "Action command");
            var remove = new Button { Content = new FontIcon { Glyph = "", FontSize = 12 } };
            AutomationProperties.SetName(remove, "Remove action");
            ToolTipService.SetToolTip(remove, "Remove action");
            Grid.SetColumn(command, 1);
            Grid.SetColumn(remove, 2);
            var row = new Grid
            {
                ColumnSpacing = 8,
                ColumnDefinitions =
                {
                    new ColumnDefinition { Width = new GridLength(140) }, new ColumnDefinition(),
                    new ColumnDefinition { Width = GridLength.Auto },
                },
                Children = { name, command, remove },
            };
            void Edited()
            {
                var edited = action with { Name = name.Text, Command = command.Text };
                if (edited == action) return;
                action = edited;
                Save(All().Select(a => a.Id == edited.Id ? edited : a));
            }
            name.TextChanged += (_, _) => Edited();
            command.TextChanged += (_, _) => Edited();
            remove.Click += (_, _) =>
            {
                Save(All().Where(a => a.Id != action.Id));
                rows.Children.Remove(row);
            };
            // Rows sit above the button.
            rows.Children.Insert(rows.Children.IndexOf(add), row);
        }

        rows.Children.Add(add);
        foreach (var action in All()) AddRow(action);
        add.IsEnabled = All().Count < AppSettings.MaxActions;
        add.Click += (_, _) =>
        {
            var action = new CustomAction(Guid.NewGuid(), "", "");
            Save(All().Append(action));
            AddRow(action);
        };
        rows.Children.Add(new TextBlock
        {
            Text = "Runs with Git’s sh in the repository’s root folder, with GITWOLF_REPO (the root path) and "
                + "GITWOLF_BRANCH in the environment. Put them in double quotes, as in \"$GITWOLF_BRANCH\". "
                + "Actions appear in the Open in menu and the jump palette.",
            FontSize = 12, Opacity = 0.65, TextWrapping = TextWrapping.Wrap,
        });
        Group("Custom actions", rows);
    }
}
