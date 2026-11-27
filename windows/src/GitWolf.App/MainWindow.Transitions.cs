using System.Diagnostics;
using GitWolf.Core;
using GitWolf.Store;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Animation;

namespace GitWolf.App;

/// <summary>
/// Changes the right panel in one step. What was there stays until the new selection is ready, then
/// fades in.
/// </summary>
public sealed partial class MainWindow
{
    /// <summary>The longest wait for colours and the signature before showing without them.</summary>
    private static readonly TimeSpan PrepareLimit = TimeSpan.FromMilliseconds(120);

    private readonly Windows.UI.ViewManagement.UISettings _system = new();
    private DispatcherTimer? _slow;
    private bool _holding;
    private (string? Commit, DiffTarget? Target) _shown;
    private Storyboard? _fade;

    private void HoldDetail()
    {
        _holding = true;
        // Its buttons belong to what was picked before.
        RightPanel.IsHitTestVisible = false;
        if (_slow is null)
        {
            // A spinner only for a load slow enough to be noticed.
            _slow = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
            _slow.Tick += (_, _) =>
            {
                _slow.Stop();
                DetailLoading.Visibility = Visibility.Visible;
                DetailLoading.IsActive = true;
            };
        }
        if (!_slow.IsEnabled && !DetailLoading.IsActive) _slow.Start();
    }

    private void ReleaseDetail()
    {
        _holding = false;
        RightPanel.IsHitTestVisible = true;
        _slow?.Stop();
        DetailLoading.IsActive = false;
        DetailLoading.Visibility = Visibility.Collapsed;
    }

    private async Task SwapDetailAsync(RepositoryStore store)
    {
        try
        {
            await Task.WhenAny(Task.WhenAll(Detail.PrepareAsync(store), Diff.PrepareAsync(store)),
                Task.Delay(PrepareLimit));
        }
        catch (Exception e)
        {
            // Shown without what could not be prepared.
            Trace.TraceWarning($"Preparing the selection failed: {e.GetType().Name}");
        }
        // Something else was picked meanwhile, and its own swap follows.
        if (!ReferenceEquals(store, _store) || store.IsLoadingSelection || !_holding) return;
        ReleaseDetail();
        ShowDetail();
        var now = (store.SelectedCommitId, store.SelectedTarget);
        if (now != _shown) FadeIn();
        _shown = now;
    }

    private void FadeIn()
    {
        // Off when animations are turned off in Windows.
        if (!_system.AnimationsEnabled) return;
        if (_fade is null)
        {
            var opacity = new DoubleAnimation
            {
                From = 0.35, To = 1, Duration = TimeSpan.FromMilliseconds(140),
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
            };
            Storyboard.SetTarget(opacity, RightPanel);
            Storyboard.SetTargetProperty(opacity, "Opacity");
            _fade = new Storyboard { Children = { opacity } };
        }
        _fade.Begin();
    }
}
