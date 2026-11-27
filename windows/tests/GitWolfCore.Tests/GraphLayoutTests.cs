using GitWolf.Core;
using Xunit;

namespace GitWolfCore.Tests;

// Ported from GraphTests in apple/Tests/GitWolfCoreTests/GitWolfCoreTests.swift.
public sealed class GraphLayoutTests
{
    private static Commit C(string hash, params string[] parents) =>
        new(hash, parents, "", "", DateTimeOffset.UnixEpoch, "", []);

    [Fact]
    public void LinearHistoryStaysInOneLane()
    {
        var rows = GraphLayout.Layout([C("c", "b"), C("b", "a"), C("a")]);
        Assert.All(rows, r => Assert.True(r.Lane == 0 && r.LaneCount == 1));
    }

    [Fact]
    public void MergeOpensAndClosesLane()
    {
        // m merges b into a-line; both descend from root r.
        var rows = GraphLayout.Layout([C("m", "a", "b"), C("a", "r"), C("b", "r"), C("r")]);

        Assert.Contains(new GraphEdge(0, 1), rows[0].Bottom);
        Assert.Equal(1, rows[2].Lane);
        Assert.Contains(new GraphEdge(1, 0), rows[3].Top);
    }
}
