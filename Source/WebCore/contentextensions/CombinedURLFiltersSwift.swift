/*
 * Copyright (C) 2025 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

// The CombinedURLFilters island: the prefix tree that content-extension compilation builds out of
// every rule's term sequence, and the walk that turns it into NFAs.
//
// WHY THIS SHAPE. The representation was not guessed; it was measured first, as arm C4 of
// `cxprobe` (webkit-swift-ports/cxprobe/README.md), which built the same graph seven ways in each
// language over five real and three synthetic corpora:
//
//  * A graph of Swift `final class` vertices -- the spelling a Swift programmer reaches for --
//    costs 2.8x the production C++ shape, and the cause is 5,442,746 retain/release pairs for a
//    171,003-node tree, 32 ARC operations per node.
//  * An ARENA of `UInt32` node indices costs 1 retain and 8 releases FOR THE WHOLE RUN, because
//    node identity is an integer rather than a reference. It is also what the neighbouring
//    `ImmutableNFA` already is, so it is the shape a WebKit reviewer expects.
//  * Making node identity an integer is also what makes the action side table a dense parallel
//    ARRAY rather than a hash map keyed on a vertex address. That is worth ~2.6x on the consume
//    walk in Swift and ~1.8x in C++ -- a PORTABLE win, applied to both sides before any ratio.
//  * Children as a CONTIGUOUS RUN with child 0 INLINE in the node record. Production is
//    `Vector<PrefixTreeEdge, 0, CrashOnOverflow, 1>`, whose one-element buffer bmalloc hands out
//    adjacent to the vertex; inlining child 0 is how a parallel-array arena gets the same single
//    cache line, and it closes the re-walk gap exactly (115.8 ns against the pointer graph's
//    115.7). Mean fanout on real blocker lists is 1.08-1.09, which is also why the child search
//    below is a linear scan and not a binary one.
//
// Result on a real 26,664-rule blocker list: 0.596 of the production shape, 0.797 against the same
// design in C++, 2.3 MB against 6.3 MB, zero `unsafe`.
//
// WHAT STILL CROSSES TO C++, and why each one does:
//
//  * `Term` never crosses. `CombinedFiltersAlphabet::interned` returns a dense `UInt32` id and the
//    C++ caller interns; the island stores ids. `term(UInt32) -> const Term&` is deliberately NOT
//    importable -- the reference is a projection of the alphabet's storage, and the annotation the
//    importer suggests would be a false lifetime claim -- so the three things the walk needs from
//    a term are id-taking queries on the alphabet instead.
//  * `ImmutableCharNFANodeBuilder` and the NFA stay in C++. That is not a limitation, it is a
//    correctness requirement: the builder sinks its ranges, epsilon targets and actions by
//    iterating `HashSet`s, and re-implementing it in Swift would change the ORDER those land in
//    the NFA's five parallel vectors. `SerializedNFA` stores those offsets, so a Swift set would
//    be behaviourally identical and byte-different -- and one of the differential oracle's nine
//    golden captures is taken in stored order for exactly this reason.
//  * A `WTF::Function` cannot be called from Swift, so the per-NFA handler arrives as
//    `CombinedURLFiltersNFASink` -- the island's only piece of added C++, and the same shape the
//    CSS tokenizer island already uses in the other direction.

public import WebCore_Private.CombinedURLFiltersSwiftTypes

private typealias CX = WebCore.ContentExtensions

// MARK: - The prefix tree arena

/// One prefix-tree vertex. 16 bytes, and the `moreStart`/`childCount` pair is what
/// `Vector<PrefixTreeEdge, 0, CrashOnOverflow, 1>` is: child 0 in the record, the rest in a
/// contiguous run in the shared edge arena.
///
/// The run's CAPACITY is not stored. It is `childCount - 1` rounded up to a power of two, so a run
/// is full exactly when `childCount - 1` is zero or a power of two -- which makes the record 16
/// bytes rather than 20, and a 20-byte record measured as a memory regression against the linked
/// sibling list this replaced.
private struct PrefixTreeNode {
    var term0: UInt32 = 0
    var child0: UInt32 = 0
    var moreStart: UInt32 = 0
    var childCount: UInt32 = 0
}

private struct PrefixTreeEdge {
    var term: UInt32
    var child: UInt32
}

// MARK: - NFA node builders held across a walk

/// A box for one `ImmutableCharNFANodeBuilder`.
///
/// `generateNFAForSubtree` keeps a stack in which SEVERAL builders are live, unfinalized and
/// mutated in place at once, so the port needs a growable container of them -- and the builder is
/// move-only in C++, so Swift imports it `~Copyable` and `Array` will not hold it. `UniqueArray`
/// (SE-0527) is the container for exactly this, and it is `@available(macOS 27)` while WebCore
/// deploys to 15, so it is not reachable here yet. A class reference is the remaining spelling.
///
/// Recorded as a to-file item rather than worked around in C++: a back-deployable growable
/// container of noncopyable elements is the missing capability, and its cost here is one
/// allocation per NFA node that appears on the walk's spine.
private final class NFANodeBuilderBox {
    var builder: CX.ImmutableCharNFANodeBuilder

    init(_ builder: consuming CX.ImmutableCharNFANodeBuilder) {
        self.builder = builder
    }
}

/// `CombinedURLFilters.cpp`'s `ActiveSubtree`: where the walk is in one vertex's child list, plus
/// the NFA node generated for that vertex if one has been. `nil` is C++'s default-constructed
/// builder, i.e. `!isValid()`.
private struct ActiveSubtree {
    var vertex: UInt32
    var edgeIndex: UInt32
    var builder: NFANodeBuilderBox?
}

// MARK: - The reverse suffix tree

/// The suffix-sharing tree `generateSuffixWithReverseSuffixTree` builds, as an arena for the same
/// reason the prefix tree is one.
///
/// Its roots are keyed by the leaf's action list. C++ keys them on `HashableActionList`, whose
/// equality is over a SORTED copy of the actions, so a Swift dictionary keyed on the sorted array
/// is the same partition -- and the map's own iteration order is not observable, because the only
/// thing C++ iterates it for is `clearReverseSuffixTree`, a hand-rolled depth-first destructor
/// that exists to avoid overflowing the stack while freeing. An arena needs no such pass, so those
/// 20 lines have no counterpart here.
private struct ReverseSuffixTree {
    struct Edge {
        var term: UInt32
        var child: Int
    }

    struct Vertex {
        var edges: [Edge] = []
        var nodeId: UInt32 = 0
    }

    var vertices: [Vertex] = []
    var roots: [[UInt64]: Int] = [:]
}

// MARK: - The island

@_expose(Cxx)
public final class CombinedURLFiltersSwift {
    /// Vertex 0 is the root, and it is never removed. Nothing is ever freed: the C++ deletes
    /// prefix-tree vertices as `processNFAs` walks them, and cxprobe finding 7 measured that this
    /// buys no footprint back at 30k rules -- `phys_footprint` at end of consume is identical to
    /// footprint after insert for every arm, in bmalloc and in system malloc alike, because
    /// neither returns the pages. What the walk does instead is clear a vertex's child count,
    /// which is what makes the tree shrink logically.
    private var nodes: [PrefixTreeNode] = [PrefixTreeNode()]

    /// Children 1..n-1 of every vertex, in one arena. A full run bump-allocates a run of twice the
    /// capacity at the end and copies; the abandoned space is not reclaimed, which is the same
    /// trade `WTF::Vector` makes when it reallocates.
    private var edges: [PrefixTreeEdge] = []

    /// The action side table, dense and parallel to `nodes` -- C++'s
    /// `HashMap<const PrefixTreeVertex*, ActionList>`. An empty list means "no entry": C++ only
    /// ever inserts through `add(vertex, ActionList())` immediately followed by an append, so a
    /// present-but-empty entry does not occur and `find() != end()` and "non-empty" agree.
    private var actions: [[UInt64]] = [[]]

    /// Where `addPatternTerm` is in the tree. C++ walks a local pointer down the tree inside one
    /// `addPattern` call; the terms arrive here one at a time because a Swift function exposed to
    /// C++ cannot take a `Span` (filings register §27), and a per-term call needs no buffer at all.
    private var cursor: UInt32 = 0

    public init() { }

    // MARK: Building the tree

    /// One term of the pattern currently being added, named by its id in the C++ alphabet.
    ///
    /// C++ compares `alphabet.term(edge.termId) == term`, a VALUE comparison against a term it has
    /// not interned yet, and its comment explains why: interning first would add alphabet entries
    /// for terms the tree already has. That reasoning does not survive inspection -- every term of
    /// every pattern is interned either way, because a term that matches an existing edge is by
    /// construction already interned with that edge's id, and one that does not is interned as the
    /// edge is appended. Same set, same order, same ids. So the caller interns up front and the
    /// scan below compares ids, which is what makes the whole boundary term-free.
    public func addPatternTerm(_ termId: UInt32) {
        cursor = descend(from: cursor, term: termId)
    }

    /// Ends the pattern begun by the preceding `addPatternTerm` calls and records its action.
    ///
    /// The caller guarantees at least one term: `CombinedURLFilters::addPattern` returns early on
    /// an empty pattern, and without that guard this would attach an action to the root.
    public func endPattern(_ actionId: UInt64) {
        if !actions[Int(cursor)].contains(actionId) {
            actions[Int(cursor)].append(actionId)
        }
        cursor = 0
    }

    public func isEmptyTree() -> Bool {
        nodes[0].childCount == 0
    }

    // MARK: The walk

    /// `CombinedURLFilters::processNFAs`. Returns false if the sink asked to stop.
    ///
    /// `UInt`, not `Int`, and the difference is a shipped defect. `swift::UInt` is `size_t`, so
    /// this parameter and the C++ `size_t` are the same type and NOTHING is converted at the
    /// boundary. Spelled `Int` it was `ptrdiff_t`, and every caller that passes
    /// `std::numeric_limits<size_t>::max()` -- which is how all ten of WebKit's own
    /// direct-construction ContentExtensionTest cases spell "no limit", DFAHelpers.h:52 --
    /// delivered **-1**, so the size test below fired on the first node and the island emitted
    /// one NFA per pattern. C++ warns on none of this. Six of 105 tests, and the oracle could
    /// not see it because all nine of its captures used one finite limit; the sweep that catches
    /// it now is `oracle/run.py`'s MAXNFA_SWEEP. Revisit log R125.
    public func processNFAs(_ maxNFASize: UInt,
                            _ alphabet: inout WebCore.ContentExtensions.CombinedFiltersAlphabet,
                            _ sink: inout WebCore.ContentExtensions.CombinedURLFiltersNFASink) -> Bool {
        var stack: [UInt32] = []
        stack.reserveCapacity(128)

        while true {
            // Traverse out to a leaf, always down the LAST child, which is why the child run has
            // to preserve production's order rather than merely its membership.
            stack.removeAll(keepingCapacity: true)
            var vertex: UInt32 = 0
            while true {
                stack.append(vertex)
                if nodes[Int(vertex)].childCount == 0 {
                    break
                }
                vertex = lastChildEdge(vertex).child
            }
            if stack.count == 1 {
                // Every edge in the prefix tree has been processed and removed.
                break
            }

            // Find the prefix root for this NFA: the vertex after the last quantified term, or the
            // root if no quantifiers are left.
            while stack.count > 1 {
                if !alphabet.hasFixedLength(lastChildEdge(stack[stack.count - 2]).term) {
                    break
                }
                stack.removeLast()
            }

            var nfa = CX.NFA()
            do {
                // Put the prefix into the NFA. `lastNode` is finalized between the two statements
                // C++ spells as one move-assignment, which finalizes its left-hand side first.
                var lastNode = CX.ImmutableCharNFANodeBuilder(&nfa)
                for i in 0..<(stack.count - 1) {
                    let edge = lastChildEdge(stack[i])
                    let newNode = alphabet.generateGraph(edge.term, &nfa, &lastNode,
                                                         consuming: actionList(of: edge.child))
                    lastNode.finalizeNow()
                    lastNode = consume newNode
                }

                // Put the non-quantified vertices in the subtree into the NFA and remove them.
                generateNFAForSubtree(&nfa, &alphabet,
                                      subtreeRoot: consume lastNode,
                                      root: stack[stack.count - 1],
                                      maxNFASize: maxNFASize)
            }

            if !sink.takeNFA(&nfa) {
                return false
            }

            // Clean up any processed leaf vertices, leaving the empty root.
            while stack.count > 1 {
                if nodes[Int(stack[stack.count - 1])].childCount != 0 {
                    break
                }
                removeLastChild(stack[stack.count - 2])
                stack.removeLast()
            }
        }
        return true
    }

    // MARK: - Prefix tree primitives
    //
    // Each one is the `PrefixTreeEdges` operation of the same name, with child 0 in the node
    // record and children 1..n-1 at `moreStart`. Keeping them together is what lets the walk above
    // read like the C++ it replaces.

    private func childEdge(_ vertex: UInt32, _ index: UInt32) -> PrefixTreeEdge {
        let node = nodes[Int(vertex)]
        if index == 0 {
            return PrefixTreeEdge(term: node.term0, child: node.child0)
        }
        return edges[Int(node.moreStart + index - 1)]
    }

    private func lastChildEdge(_ vertex: UInt32) -> PrefixTreeEdge {
        childEdge(vertex, nodes[Int(vertex)].childCount - 1)
    }

    private func setChildEdge(_ vertex: UInt32, _ index: UInt32, _ edge: PrefixTreeEdge) {
        if index == 0 {
            nodes[Int(vertex)].term0 = edge.term
            nodes[Int(vertex)].child0 = edge.child
            return
        }
        edges[Int(nodes[Int(vertex)].moreStart + index - 1)] = edge
    }

    private func setChildTerm(_ vertex: UInt32, _ index: UInt32, _ term: UInt32) {
        if index == 0 {
            nodes[Int(vertex)].term0 = term
            return
        }
        edges[Int(nodes[Int(vertex)].moreStart + index - 1)].term = term
    }

    private func removeLastChild(_ vertex: UInt32) {
        nodes[Int(vertex)].childCount -= 1
    }

    /// `edges.removeAllMatching([](edge) { return edge.termId == invalidTermId; })`, and stable,
    /// as WTF's is (`Vector.h:1787` compacts by moving the survivors down over the holes).
    ///
    /// Shrinking a run never invalidates the implicit capacity: capacity is at least
    /// `childCount - 1` rounded up to a power of two at the moment it was allocated, and the
    /// append path reallocates whenever `childCount - 1` is zero or a power of two, so the slot it
    /// writes is always inside what was allocated.
    private func removeChildrenWithInvalidTerm(_ vertex: UInt32) {
        let count = nodes[Int(vertex)].childCount
        var write: UInt32 = 0
        for read in 0..<count {
            let edge = childEdge(vertex, read)
            if edge.term == CX.invalidTermId {
                continue
            }
            if write != read {
                setChildEdge(vertex, write, edge)
            }
            write += 1
        }
        nodes[Int(vertex)].childCount = write
    }

    /// The child of `vertex` reached by `term`, appending one if there is none. The linear scan is
    /// the measured choice: mean fanout on real blocker lists is 1.08-1.09, so at least 92% of
    /// scans stop on the first element and a search-algorithm change cannot reach the other 8%
    /// without also changing the order the consume walk visits children in.
    private func descend(from vertex: UInt32, term: UInt32) -> UInt32 {
        let node = nodes[Int(vertex)]
        if node.childCount != 0 {
            if node.term0 == term {
                return node.child0
            }
            for k in 0..<(node.childCount - 1) where edges[Int(node.moreStart + k)].term == term {
                return edges[Int(node.moreStart + k)].child
            }
        }

        let child = UInt32(nodes.count)
        nodes.append(PrefixTreeNode())
        actions.append([])

        let existing = node.childCount
        if existing == 0 {
            nodes[Int(vertex)].term0 = term
            nodes[Int(vertex)].child0 = child
            nodes[Int(vertex)].childCount = 1
            return child
        }

        // `inRun` children live at `moreStart`; the run is full when `inRun` is zero or a power of
        // two, which is the implicit-capacity rule stated on `PrefixTreeNode`.
        let inRun = existing - 1
        var start = nodes[Int(vertex)].moreStart
        if inRun & (inRun &- 1) == 0 {
            let newCapacity = inRun == 0 ? 1 : inRun * 2
            let newStart = UInt32(edges.count)
            edges.append(contentsOf: repeatElement(PrefixTreeEdge(term: 0, child: 0),
                                                   count: Int(newCapacity)))
            for k in 0..<Int(inRun) {
                edges[Int(newStart) + k] = edges[Int(start) + k]
            }
            start = newStart
            nodes[Int(vertex)].moreStart = newStart
        }
        edges[Int(start + inRun)] = PrefixTreeEdge(term: term, child: child)
        nodes[Int(vertex)].childCount = existing + 1
        return child
    }

    /// The actions on `vertex` as the `ActionList` the C++ API takes. The order is the order they
    /// were added in, which is what `HashMap::get` hands `Term::generateGraph`, and it reaches the
    /// NFA through a `HashSet` whose iteration order depends on it.
    private func actionList(of vertex: UInt32) -> CX.ActionList {
        var list = CX.ActionList()
        for action in actions[Int(vertex)] {
            list.append(consuming: action)
        }
        return list
    }

    // MARK: - Generating one NFA out of a fixed-length subtree

    /// `generateNFAForSubtree`. Walks the subtree rooted at `root`, generating NFA nodes for every
    /// fixed-length edge and clearing the vertices it consumes.
    private func generateNFAForSubtree(_ nfa: inout CX.NFA,
                                       _ alphabet: inout CX.CombinedFiltersAlphabet,
                                       subtreeRoot: consuming CX.ImmutableCharNFANodeBuilder,
                                       root: UInt32,
                                       maxNFASize: UInt) {
        var stack: [ActiveSubtree] = []
        if nodes[Int(root)].childCount == 0 {
            // C++ never moves the parameter in this case, so the caller's builder is finalized by
            // scope exit a moment later. Nothing generates NFA nodes in between, so finalizing it
            // here is the same packing.
            var unused = consume subtreeRoot
            unused.finalizeNow()
            return
        }
        stack.append(ActiveSubtree(vertex: root, edgeIndex: 0,
                                   builder: NFANodeBuilderBox(consume subtreeRoot)))

        var reverseSuffixTree = ReverseSuffixTree()
        var nfaTooBig = false

        while !stack.isEmpty {
            let vertex = stack[stack.count - 1].vertex
            let edgeIndex = stack[stack.count - 1].edgeIndex

            if edgeIndex < nodes[Int(vertex)].childCount {
                // Past the size limit, stop descending but keep unwinding, so that the leaves
                // already processed are still cleaned up.
                if nfaTooBig {
                    stack[stack.count - 1].edgeIndex = nodes[Int(vertex)].childCount
                    continue
                }

                let edge = childEdge(vertex, edgeIndex)

                // Quantified edges in the subtree belong to another NFA.
                if !alphabet.hasFixedLength(edge.term) {
                    stack[stack.count - 1].edgeIndex += 1
                    continue
                }

                stack.append(ActiveSubtree(vertex: edge.child, edgeIndex: 0, builder: nil))
            } else {
                // Read before the compaction below, exactly as C++ does: a vertex all of whose
                // children were marked for deletion is not a leaf here, it is a vertex about to
                // become one.
                let isLeaf = nodes[Int(vertex)].childCount == 0
                removeChildrenWithInvalidTerm(vertex)

                if isLeaf {
                    generateInfixUnsuitableForReverseSuffixTree(&nfa, &alphabet, &stack)
                    generateSuffixWithReverseSuffixTree(&nfa, &alphabet, &stack, &reverseSuffixTree)

                    // Only ever stop at a leaf, so the NFA is always complete. This can overshoot
                    // `maxNFASize`, which is what the C++ comment here says and what the oracle's
                    // `share-hi` capture demonstrates at 75,002 nodes against a limit of 75,000.
                    //
                    // `WTF::Vector::size()` is a `size_t` too, so both sides of this comparison
                    // are `UInt` and it is character-for-character `CombinedURLFilters.cpp:472`.
                    // It used to read `Int(nfa.nodes.size()) > maxNFASize`, which was both the
                    // R125 defect and a trap on a value no build can reach.
                    if nfa.nodes.size() > maxNFASize {
                        nfaTooBig = true
                    }
                } else {
                    finalizeAndPop(&stack)
                }

                if !stack.isEmpty {
                    let top = stack.count - 1
                    let parent = stack[top].vertex
                    let edge = childEdge(parent, stack[top].edgeIndex)
                    if nodes[Int(edge.child)].childCount == 0 {
                        setChildTerm(parent, stack[top].edgeIndex, CX.invalidTermId)
                    }
                    stack[top].edgeIndex += 1
                }
            }
        }
    }

    /// `generateInfixUnsuitableForReverseSuffixTree`. The reverse suffix tree may only absorb the
    /// part of a branch below the last vertex that either carries an action or branches; this
    /// generates everything above that point in the forward direction.
    private func generateInfixUnsuitableForReverseSuffixTree(_ nfa: inout CX.NFA,
                                                             _ alphabet: inout CX.CombinedFiltersAlphabet,
                                                             _ stack: inout [ActiveSubtree]) {
        var i = stack.count - 1
        while i > 0 {
            i -= 1
            if stack[i].builder != nil {
                return
            }
            // C++ RELEASE_ASSERTs i > 0 here: the bottom of the stack is the root of the
            // fixed-length subtree and always has a generated node, so the `return` above fires
            // first. The loop condition is that assertion.

            let vertex = stack[i].vertex
            let hasActionInsideTree = !actions[Int(vertex)].isEmpty
            // Strictly this should count exit edges with fixed length; C++ notes that as costly
            // and unlikely to matter, and this port keeps the same approximation because it is
            // part of the behaviour, not an optimization.
            let hasSingleOutcome = nodes[Int(vertex)].childCount == 1

            if hasActionInsideTree || !hasSingleOutcome {
                // Go back to the end of the part already generated, and generate forward from
                // there down to `end`.
                let end = i
                var beginning = end
                while beginning > 0 {
                    beginning -= 1
                    if stack[beginning].builder != nil {
                        break
                    }
                }

                var source = beginning
                for stackIndex in (beginning + 1)...end {
                    let sourceBox = stack[source].builder!
                    let edge = childEdge(stack[source].vertex, stack[source].edgeIndex)
                    let produced = alphabet.generateGraph(edge.term, &nfa, &sourceBox.builder,
                                                          consuming: actionList(of: stack[stackIndex].vertex))
                    // C++ move-assigns into the slot, which finalizes whatever was there. Every
                    // slot in this range is invalid, so this is a no-op today; spelling it out is
                    // what keeps that true if the range ever widens.
                    stack[stackIndex].builder?.builder.finalizeNow()
                    stack[stackIndex].builder = NFANodeBuilderBox(consume produced)
                    source = stackIndex
                }
                return
            }
        }
    }

    /// `generateSuffixWithReverseSuffixTree`. Walks back up from the leaf, unifying the suffix
    /// with any other branch that ends in the same action list, and connects the result to the
    /// first vertex that already has a generated node.
    private func generateSuffixWithReverseSuffixTree(_ nfa: inout CX.NFA,
                                                     _ alphabet: inout CX.CombinedFiltersAlphabet,
                                                     _ stack: inout [ActiveSubtree],
                                                     _ tree: inout ReverseSuffixTree) {
        let leafVertex = stack[stack.count - 1].vertex
        // Not empty: the prefix tree always has actions on its leaves by construction.
        let key = actions[Int(leafVertex)].sorted()

        var destinationNodeId: UInt32
        var activeVertex: Int
        if let existing = tree.roots[key] {
            activeVertex = existing
            destinationNodeId = tree.vertices[existing].nodeId
        } else {
            var newNode = CX.ImmutableCharNFANodeBuilder(&nfa)
            // The UNSORTED list, as C++ hands over: the sorted copy is only the map key.
            newNode.setActionList(consuming: actionList(of: leafVertex))
            let nodeId = newNode.nodeId()
            newNode.finalizeNow()

            tree.vertices.append(ReverseSuffixTree.Vertex(edges: [], nodeId: nodeId))
            activeVertex = tree.vertices.count - 1
            tree.roots[key] = activeVertex
            destinationNodeId = nodeId
        }

        var stackPosition = stack.count - 2
        while true {
            let sourceVertex = stack[stackPosition].vertex
            let edge = childEdge(sourceVertex, stack[stackPosition].edgeIndex)

            // The end condition: a vertex that already has a generated node is where the backward
            // tree joins the forward one. That vertex must NOT enter the reverse suffix tree --
            // it can have transitions back into earlier parts of the prefix tree, and caching it
            // would invent transitions the source language does not have.
            if let sourceBox = stack[stackPosition].builder {
                shrink(&stack, to: stackPosition + 1)
                alphabet.generateGraph(edge.term, &nfa, &sourceBox.builder, destinationNodeId)
                return
            }
            stackPosition -= 1

            // Identity, not equality, of terms: ids come from the alphabet, so one id is one
            // interned term and resolving both sides would make the interning pointless.
            var existingChild: Int?
            for candidate in tree.vertices[activeVertex].edges where candidate.term == edge.term {
                existingChild = candidate.child
                break
            }

            if let existingChild {
                activeVertex = existingChild
            } else {
                var newNode = CX.ImmutableCharNFANodeBuilder(&nfa)
                alphabet.generateGraph(edge.term, &nfa, &newNode, destinationNodeId)
                tree.vertices.append(ReverseSuffixTree.Vertex(edges: [], nodeId: newNode.nodeId()))
                let newChild = tree.vertices.count - 1
                tree.vertices[activeVertex].edges.append(ReverseSuffixTree.Edge(term: edge.term,
                                                                                child: newChild))
                activeVertex = newChild
                newNode.finalizeNow()
            }
            destinationNodeId = tree.vertices[activeVertex].nodeId

            // The vertex had exactly one child and it has now been absorbed into the reverse
            // suffix tree.
            nodes[Int(sourceVertex)].childCount = 0
        }
    }

    // MARK: - Stack shrinking, and why it finalizes

    /// `Vector<ActiveSubtree>::shrink`, including the part that matters: destroying an
    /// `ActiveSubtree` destroys its builder, which sinks that node into the NFA. WTF destroys the
    /// removed tail FRONT TO BACK (`VectorTypeOperations::destruct`, `Vector.h:79`), and the order
    /// decides how the NFA's five parallel vectors are packed, so it is reproduced rather than
    /// left to Swift's release timing.
    private func shrink(_ stack: inout [ActiveSubtree], to count: Int) {
        for i in count..<stack.count {
            stack[i].builder?.builder.finalizeNow()
        }
        stack.removeLast(stack.count - count)
    }

    private func finalizeAndPop(_ stack: inout [ActiveSubtree]) {
        stack[stack.count - 1].builder?.builder.finalizeNow()
        stack.removeLast()
    }
}
