import Foundation

public struct GraphEdge: Hashable, Sendable {
    /// Lane index at the start of the segment.
    public var from: Int
    /// Lane index at the end of the segment.
    public var to: Int
}

/// Drawing instructions for one history row. `top` edges run from the row's top edge to its
/// vertical middle (where the commit node sits); `bottom` edges from the middle to the bottom.
public struct GraphRow: Hashable, Sendable {
    public var lane: Int
    public var top: [GraphEdge]
    public var bottom: [GraphEdge]
    public var laneCount: Int
}

/// Assigns commits to lanes. Input must be in topological order (children before parents),
/// as produced by `git log --topo-order`.
public enum GraphLayout {
    public static func layout(_ commits: [Commit]) -> [GraphRow] {
        var lanes: [String?] = []
        var rows: [GraphRow] = []
        rows.reserveCapacity(commits.count)

        func freeSlot(_ lanes: inout [String?]) -> Int {
            if let i = lanes.firstIndex(where: { $0 == nil }) { return i }
            lanes.append(nil)
            return lanes.count - 1
        }

        for commit in commits {
            let before = lanes
            let matching = lanes.indices.filter { lanes[$0] == commit.hash }

            let lane: Int
            if let first = matching.first {
                lane = first
            } else {
                lane = freeSlot(&lanes)
            }

            var top: [GraphEdge] = []
            for (i, hash) in before.enumerated() where hash != nil {
                top.append(GraphEdge(from: i, to: hash == commit.hash ? lane : i))
            }

            for m in matching { lanes[m] = nil }
            lanes[lane] = nil

            var bottom: [GraphEdge] = []
            var touched = Set<Int>()
            for (index, parent) in commit.parents.enumerated() {
                if index == 0 {
                    lanes[lane] = parent
                    bottom.append(GraphEdge(from: lane, to: lane))
                    touched.insert(lane)
                } else if let existing = lanes.firstIndex(where: { $0 == parent }) {
                    bottom.append(GraphEdge(from: lane, to: existing))
                } else {
                    let slot = freeSlot(&lanes)
                    lanes[slot] = parent
                    bottom.append(GraphEdge(from: lane, to: slot))
                    touched.insert(slot)
                }
            }

            // Lanes that simply pass through this row.
            for (j, hash) in lanes.enumerated() where hash != nil && !touched.contains(j) {
                if j < before.count, let was = before[j], was != commit.hash {
                    bottom.append(GraphEdge(from: j, to: j))
                }
            }

            while lanes.last == .some(nil) { lanes.removeLast() }
            let width = max(before.count, lanes.count, lane + 1)
            rows.append(GraphRow(lane: lane, top: top, bottom: bottom, laneCount: width))
        }
        return rows
    }
}
