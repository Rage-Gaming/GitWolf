using System.Collections.ObjectModel;

namespace GitSync.App.Views;

internal static class ListSync
{
    /// <summary>
    /// Edits <paramref name="target"/> in place to match <paramref name="source"/>, so a list keeps
    /// its scroll position and unchanged rows are not rebuilt.
    /// </summary>
    public static void Apply<T, TKey>(ObservableCollection<T> target, IReadOnlyList<T> source, Func<T, TKey> key)
        where TKey : notnull
    {
        var wanted = source.Select(key).ToHashSet();
        for (var i = target.Count - 1; i >= 0; i--)
            if (!wanted.Contains(key(target[i]))) target.RemoveAt(i);

        var comparer = EqualityComparer<TKey>.Default;
        for (var i = 0; i < source.Count; i++)
        {
            if (i < target.Count && comparer.Equals(key(target[i]), key(source[i])))
            {
                if (!EqualityComparer<T>.Default.Equals(target[i], source[i])) target[i] = source[i];
            }
            else
            {
                target.Insert(i, source[i]);
            }
        }
        // Rows that moved leave stale copies behind the end.
        while (target.Count > source.Count) target.RemoveAt(target.Count - 1);
    }
}
