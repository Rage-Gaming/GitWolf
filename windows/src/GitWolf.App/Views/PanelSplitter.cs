using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace GitWolf.App.Views;

/// <summary>The gap between two panels, dragged to resize them. Double-click restores the default.</summary>
public sealed partial class PanelSplitter : UserControl
{
    private double _last;
    private bool _dragging;

    /// <summary>Horizontal movement since the previous event.</summary>
    internal event Action<double>? Dragged;
    internal event Action? Finished;
    internal event Action? Reset;

    public PanelSplitter()
    {
        Width = 10;
        // Transparent, not null, so it receives the pointer.
        Content = new Grid { Background = new SolidColorBrush(Colors.Transparent) };
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast);
        PointerPressed += OnPressed;
        PointerMoved += OnMoved;
        PointerReleased += (_, e) => ReleasePointerCapture(e.Pointer);
        PointerCaptureLost += (_, _) => Stop();
        DoubleTapped += (_, _) => Reset?.Invoke();
    }

    private void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed || !CapturePointer(e.Pointer)) return;
        _dragging = true;
        // Measured from the window, because the splitter itself moves while dragging.
        _last = e.GetCurrentPoint(null).Position.X;
        e.Handled = true;
    }

    private void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging) return;
        var x = e.GetCurrentPoint(null).Position.X;
        Dragged?.Invoke(x - _last);
        _last = x;
    }

    private void Stop()
    {
        if (!_dragging) return;
        _dragging = false;
        Finished?.Invoke();
    }
}
