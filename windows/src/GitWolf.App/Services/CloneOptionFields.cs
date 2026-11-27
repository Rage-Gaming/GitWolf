using GitWolf.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitWolf.App.Services;

/// <summary>The optional clone settings, folded away until needed.</summary>
internal sealed class CloneOptionFields
{
    private readonly NumberBox _depth = new()
    {
        Header = "History depth (empty for everything)", Minimum = 1, Maximum = 1_000_000,
        ValidationMode = NumberBoxValidationMode.InvalidInputOverwritten,
    };
    private readonly ComboBox _filter = new()
    {
        Header = "File contents", HorizontalAlignment = HorizontalAlignment.Stretch,
        // In the order of CloneFilter.
        ItemsSource = new[]
        {
            "Download everything", "Download file contents when needed", "Download commits only",
        },
        SelectedIndex = 0,
    };
    private readonly TextBox _branch = new() { Header = "Branch (empty for the default)" };
    private readonly CheckBox _single = new() { Content = "Only that branch" };
    private readonly CheckBox _submodules = new() { Content = "Also clone submodules" };

    public Control View { get; }

    public CloneOptionFields() => View = new Expander
    {
        Header = "Options", HorizontalAlignment = HorizontalAlignment.Stretch,
        HorizontalContentAlignment = HorizontalAlignment.Stretch,
        Content = new StackPanel { Spacing = 10, Children = { _depth, _filter, _branch, _single, _submodules } },
    };

    /// <summary>Call on the UI thread.</summary>
    public CloneOptions Read() => new(
        double.IsNaN(_depth.Value) ? null : (int)_depth.Value,
        (CloneFilter)Math.Max(0, _filter.SelectedIndex),
        _single.IsChecked == true, _branch.Text, _submodules.IsChecked == true);
}
