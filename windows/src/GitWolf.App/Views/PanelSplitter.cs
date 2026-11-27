using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace GitWolf.App.Views;

/// <summary>A gap dragged to resize what is on either side. Double-click restores the default.</summary>
public sealed partial class PanelSplitter : UserControl
{
    private double _last;
    private bool _dragging;
    private bool _hovering;
    private bool _horizontal;
    /// <summary>Shown under the pointer, so the gap can be found.</summary>
    private readonly Border _grip = new()
    {
        Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0x99, 0x80, 0x80, 0x80)),
        CornerRadius = new CornerRadius(2), Opacity = 0,
        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
    };

    /// <summary>True for a gap dragged up and down; otherwise left and right.</summary>
    public bool Horizontal
    {
        get => _horizontal;
        set
        {
            _horizontal = value;
            Shape();
        }
    }

    /// <summary>Movement along the drag direction since the previous event.</summary>
    internal event Action<double>? Dragged;
    internal event Action? Finished;
    internal event Action? Reset;

    public PanelSplitter()
    {
        // Transparent, not null, so it receives the pointer.
        Content = new Grid { Background = new SolidColorBrush(Colors.Transparent), Children = { _grip } };
        Shape();
        PointerEntered += (_, _) => Hover(true);
        PointerExited += (_, _) => Hover(false);
        PointerPressed += OnPressed;
        PointerMoved += OnMoved;
        PointerReleased += (_, e) => ReleasePointerCapture(e.Pointer);
        PointerCaptureLost += (_, _) => Stop();
        DoubleTapped += (_, _) => Reset?.Invoke();
    }

    private void Shape()
    {
        Width = _horizontal ? double.NaN : 12;
        Height = _horizontal ? 10 : double.NaN;
        (_grip.Width, _grip.Height) = _horizontal ? (36.0, 4.0) : (4.0, 36.0);
        ProtectedCursor = InputSystemCursor.Create(
            _horizontal ? InputSystemCursorShape.SizeNorthSouth : InputSystemCursorShape.SizeWestEast);
    }

    private void Hover(bool over)
    {
        _hovering = over;
        _grip.Opacity = _hovering || _dragging ? 1 : 0;
    }

    private double Position(PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(null).Position;
        return _horizontal ? point.Y : point.X;
    }

    private void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed || !CapturePointer(e.Pointer)) return;
        _dragging = true;
        // Measured from the window, because the splitter itself moves while dragging.
        _last = Position(e);
        e.Handled = true;
    }

    private void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging) return;
        var now = Position(e);
        Dragged?.Invoke(now - _last);
        _last = now;
    }

    private void Stop()
    {
        if (!_dragging) return;
        _dragging = false;
        Hover(_hovering);
        Finished?.Invoke();
    }
}
