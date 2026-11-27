using GitWolf.App.Services;
using GitWolf.Core;
using GitWolf.Store;
using Windows.ApplicationModel.DataTransfer;

namespace GitWolf.App;

/// <summary>Changing the icon of a repository's tile.</summary>
public sealed partial class MainWindow
{
    /// <summary>Called once from the constructor, after the workspace exists.</summary>
    private void AttachRepoIcons()
    {
        Rail.IconRequested += store => _ = RepoIconDialog.ShowAsync(Root.XamlRoot, _workspace.IconStore, store.Id,
            WinRT.Interop.WindowNative.GetWindowHandle(this), _workspace.IconsChanged);
        Rail.ImageDropped += (store, data) => _ = DropIconAsync(store, data);
    }

    private async Task DropIconAsync(RepositoryStore store, DataPackageView data)
    {
        if (await RepoIconImages.ImportAsync(_workspace.IconStore, data) is not { } name)
            ShowError("That file couldn’t be read as an image.");
        else if (!_workspace.SetIcon(store, RepoIcon.OfImage(name)))
            ShowError("The icon couldn’t be saved.");
    }
}
