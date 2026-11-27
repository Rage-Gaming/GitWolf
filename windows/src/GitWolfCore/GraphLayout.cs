namespace GitWolf.Core;

// Ported from apple/Sources/GitWolfCore/GraphLayout.swift.

/// <summary>Lane index at the start (<see cref="From"/>) and end (<see cref="To"/>) of the segment.</summary>
public readonly record struct GraphEdge(int From, int To);

/// <summary>
/// Drawing instructions for one history row. <see cref="Top"/> edges run from the row's top edge
/// to its vertical middle (where the commit node sits); <see cref="Bottom"/> edges from the
/// middle to the bottom.
/// </summary>
public sealed record GraphRow(int Lane, IReadOnlyList<GraphEdge> Top, IReadOnlyList<GraphEdge> Bottom, int LaneCount);

/// <summary>
/// Assigns commits to lanes. Input must be in topological order (children before parents), as
/// produced by `git log --topo-order`.
/// </summary>
public static class GraphLayout
{
    public static List<GraphRow> Layout(IReadOnlyList<Commit> commits)
    {
        var lanes = new List<string?>();
        var rows = new List<GraphRow>(commits.Count);

        static int FreeSlot(List<string?> lanes)
        {
            var i = lanes.FindIndex(x => x is null);
            if (i >= 0) return i;
            lanes.Add(null);
            return lanes.Count - 1;
        }

        foreach (var commit in commits)
        {
            var before = new List<string?>(lanes);
            var matching = new List<int>();
            for (int i = 0; i < lanes.Count; i++) if (lanes[i] == commit.Hash) matching.Add(i);

            var lane = matching.Count > 0 ? matching[0] : FreeSlot(lanes);

            var top = new List<GraphEdge>();
            for (int i = 0; i < before.Count; i++)
            {
                if (before[i] is null) continue;
                top.Add(new GraphEdge(i, before[i] == commit.Hash ? lane : i));
            }

            foreach (var m in matching) lanes[m] = null;
            lanes[lane] = null;

            var bottom = new List<GraphEdge>();
            var touched = new HashSet<int>();
            for (int index = 0; index < commit.Parents.Count; index++)
            {
                var parent = commit.Parents[index];
                if (index == 0)
                {
                    lanes[lane] = parent;
                    bottom.Add(new GraphEdge(lane, lane));
                    touched.Add(lane);
                }
                else
                {
                    var existing = lanes.FindIndex(x => x == parent);
                    if (existing >= 0)
                    {
                        bottom.Add(new GraphEdge(lane, existing));
                    }
                    else
                    {
                        var slot = FreeSlot(lanes);
                        lanes[slot] = parent;
                        bottom.Add(new GraphEdge(lane, slot));
                        touched.Add(slot);
                    }
                }
            }

            // Lanes that simply pass through this row.
            for (int j = 0; j < lanes.Count; j++)
            {
                if (lanes[j] is null || touched.Contains(j)) continue;
                if (j < before.Count && before[j] is { } was && was != commit.Hash)
                    bottom.Add(new GraphEdge(j, j));
            }

            while (lanes.Count > 0 && lanes[^1] is null) lanes.RemoveAt(lanes.Count - 1);
            var width = Math.Max(Math.Max(before.Count, lanes.Count), lane + 1);
            rows.Add(new GraphRow(lane, top, bottom, width));
        }
        return rows;
    }
}
