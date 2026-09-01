/*
 * Copyright (C) 2015 Apple Inc. All rights reserved.
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

#include "config.h"
#include "CombinedURLFilters.h"

#if ENABLE(CONTENT_EXTENSIONS)

#include "HashableActionList.h"
#include "Term.h"
// The island's boundary types, plus -- for the reason CSSTokenizer.cpp:37 records -- the other
// two islands' boundary headers, because WebCoreSwift-Generated.h is emitted once for the whole
// module and every translation unit that includes it must be able to see all of them.
#include "CSSCalcSwiftTypes.h"
#include "CSSTokenizerSwiftTypes.h"
#include "CombinedURLFiltersSwiftTypes.h"
// Same suppression and the same FIXME as CSSTokenizer.cpp: the generated header hands C++ an
// Objective-C-only non-defining fixed-underlying-type enum declaration for each `@c` enum, which
// -Werror makes fatal. Filings register §26.
IGNORE_CLANG_WARNINGS_BEGIN("elaborated-enum-base")
#include "WebCoreSwift-Generated.h"
IGNORE_CLANG_WARNINGS_END
#include <wtf/DataLog.h>
#include <wtf/Vector.h>
#include <wtf/text/CString.h>
#include <type_traits>

namespace WebCore {

namespace ContentExtensions {

// REGION 1 of 4 of the C++ builder, guarded so that a build can answer what is DELETABLE by
// making the compiler the oracle. See CombinedURLFilters.h for the mode and WebCore.xcconfig for
// why it is a build mode rather than an `nm` inspection.
//
// The prefix tree and the reverse suffix tree, both of which the island replaces with arenas.
#if COMBINED_URL_FILTERS_CPP_BUILDER_COMPILED_IN
struct PrefixTreeEdge {
    // The term is named by its id in CombinedURLFilters::m_alphabet, never by a pointer into the
    // alphabet's storage: the id has no lifetime to get wrong, it is what an eventual Swift
    // caller can hold, and invalidTermId gives the "no term here" state a name instead of
    // spelling it as a null pointer.
    uint32_t termId;
    std::unique_ptr<PrefixTreeVertex> child;
};

typedef Vector<PrefixTreeEdge, 0, CrashOnOverflow, 1> PrefixTreeEdges;

struct PrefixTreeVertex {
    WTF_DEPRECATED_MAKE_STRUCT_FAST_ALLOCATED(PrefixTreeVertex);

    PrefixTreeEdges edges;
};

struct ReverseSuffixTreeVertex;
struct ReverseSuffixTreeEdge {
    uint32_t termId;
    std::unique_ptr<ReverseSuffixTreeVertex> child;
};
typedef Vector<ReverseSuffixTreeEdge, 0, CrashOnOverflow, 1> ReverseSuffixTreeEdges;

struct ReverseSuffixTreeVertex {
    ReverseSuffixTreeEdges edges;
    uint32_t nodeId;
};
using ReverseSuffixTreeRoots = HashMap<HashableActionList, ReverseSuffixTreeVertex, HashableActionListHash, HashableActionListHashTraits>;
#endif // COMBINED_URL_FILTERS_CPP_BUILDER_COMPILED_IN

#if CONTENT_EXTENSIONS_PERFORMANCE_REPORTING && COMBINED_URL_FILTERS_CPP_BUILDER_COMPILED_IN
static size_t recursiveMemoryUsed(const PrefixTreeVertex& vertex)
{
    size_t size = sizeof(PrefixTreeVertex)
        + vertex.edges.capacity() * sizeof(PrefixTreeEdge);
    for (const auto& edge : vertex.edges) {
        ASSERT(edge.child);
        size += recursiveMemoryUsed(*edge.child.get());
    }
    return size;
}

size_t CombinedURLFilters::memoryUsed() const
{
    // Counts the C++ arm only. On `Builder::Swift` the prefix tree and the action side table are
    // in the island, so this reports the two empty containers below plus the alphabet, and the
    // island's own footprint is missing. Not filled in here because this whole branch does not
    // compile today for reasons that predate the island (ContentExtensionCompiler.cpp:388 names
    // locals that no longer exist), and a size accessor written against a branch that cannot be
    // built is a number nobody has ever seen. cxprobe measured the island's footprint directly
    // instead, off `phys_footprint`: 2.3 MB against the C++ shape's 6.3 MB on a real 26,664-rule
    // list. Recorded as a follow-up, together with fixing the branch.
    size_t actionsSize = 0;
    for (const auto& slot : m_actions)
        actionsSize += slot.value.capacity() * sizeof(uint64_t);

    return sizeof(CombinedURLFilters)
        + m_alphabet.memoryUsed()
        + recursiveMemoryUsed(m_prefixTreeRoot)
        + sizeof(HashMap<PrefixTreeVertex*, ActionList>)
        + m_actions.capacity() * (sizeof(PrefixTreeVertex*) + sizeof(ActionList))
        + actionsSize;
}
#endif
    
#if CONTENT_EXTENSIONS_STATE_MACHINE_DEBUGGING && COMBINED_URL_FILTERS_CPP_BUILDER_COMPILED_IN
static String prefixTreeVertexToString(const PrefixTreeVertex& vertex, const HashMap<const PrefixTreeVertex*, ActionList>& actions, unsigned depth)
{
    StringBuilder builder;
    while (depth--)
        builder.append("  "_s);
    builder.append("vertex actions: "_s);

    auto actionsSlot = actions.find(&vertex);
    if (actionsSlot != actions.end()) {
        for (uint64_t action : actionsSlot->value)
            builder.append(action, ',');
    }
    builder.append('\n');
    return builder.toString();
}

static void recursivePrint(const CombinedFiltersAlphabet& alphabet, const PrefixTreeVertex& vertex, const HashMap<const PrefixTreeVertex*, ActionList>& actions, unsigned depth)
{
    dataLog(prefixTreeVertexToString(vertex, actions, depth));
    for (const auto& edge : vertex.edges) {
        StringBuilder builder;
        for (unsigned i = 0; i < depth * 2; ++i)
            builder.append(' ');
        builder.append("vertex edge: "_s, alphabet.term(edge.termId).toString(), '\n');
        dataLog(builder.toString());
        ASSERT(edge.child);
        recursivePrint(alphabet, *edge.child.get(), actions, depth + 1);
    }
}

void CombinedURLFilters::print() const
{
    // C++ arm only: on `Builder::Swift` the tree below is empty and the island has no dumper.
    recursivePrint(m_alphabet, m_prefixTreeRoot, m_actions, 0);
}
#endif

// The Swift island, boxed so that CombinedURLFilters.h does not have to name a type that only
// exists in the generated header.
struct CombinedURLFilters::SwiftIsland {
    WTF_DEPRECATED_MAKE_STRUCT_FAST_ALLOCATED(SwiftIsland);

    WebCore::CombinedURLFiltersSwift island { WebCore::CombinedURLFiltersSwift::init() };
};

// Every integer that crosses into the island, asserted to arrive as the type it left as.
//
// This exists because one of them did not. `processNFAs` took `size_t` here and `Int` on the Swift
// side, `swift::Int` is `ptrdiff_t`, and C++ converts `size_t` to it silently -- so
// `std::numeric_limits<size_t>::max()`, which is how WebKit's own tests spell "no limit", arrived
// as -1 and the island emitted one NFA per pattern. Six of 105 ContentExtensionTest cases, no
// diagnostic anywhere, and nine golden NFA captures that all passed because every one of them used
// a finite limit. Revisit log R125.
//
// Asserting the whole member-function type, rather than adding a cast at the call, is the
// difference between fixing the instance and closing the class: a Swift signature is not visible
// from here and nobody editing the island sees this file, so the check has to be one that fires on
// ANY future change to how these arguments are spelled -- width, signedness or order. It costs
// nothing at runtime and it names the boundary in the diagnostic.
//
// (`{braced}` arguments would diagnose the narrowing too, and were the first choice, but scalar
// braced initializers trip -Wbraced-scalar-init and WebCore builds -Werror.)
//
// AND THE MAPPING IS NOT SYMMETRIC, which is the trap one layer down. A `size_t` IMPORTED into
// Swift from C++ is `Int` -- that is the Clang importer's fixed mapping, so `termCount()` below is
// read as `Int` and the compiler checks it. A Swift `Int` EXPORTED to C++ is `ptrdiff_t`, which is
// how R125 happened. So an entry point Swift provides spells its size `UInt` (`processNFAs`) while
// a query C++ provides is read as `Int` (`CombinedURLFiltersPattern::termCount`), and both of
// those are pinned here as `size_t` on the C++ side, which is the one spelling that is true of
// both directions.
using SwiftIslandType = WebCore::CombinedURLFiltersSwift;
static_assert(std::is_same_v<decltype(&SwiftIslandType::addPattern),
    void (SwiftIslandType::*)(uint64_t, CombinedURLFiltersPattern&)>,
    "CombinedURLFiltersSwift.addPattern must take CombinedURLFilters::addPattern's action id type "
    "unchanged, and the pattern by reference so that no Term and no Vector is copied.");
static_assert(std::is_same_v<decltype(&CombinedURLFiltersPattern::termCount),
    size_t (CombinedURLFiltersPattern::*)() const>,
    "CombinedURLFiltersPattern::termCount must stay a size_t: the island's loop bound narrowing "
    "is the same class of defect as R125's, and Swift spells size_t `UInt`.");
static_assert(std::is_same_v<decltype(&SwiftIslandType::isEmptyTree),
    bool (SwiftIslandType::*)()>,
    "CombinedURLFiltersSwift.isEmptyTree must return CombinedURLFilters::isEmpty's type unchanged.");
static_assert(std::is_same_v<decltype(&SwiftIslandType::processNFAs),
    bool (SwiftIslandType::*)(size_t, CombinedFiltersAlphabet&, CombinedURLFiltersNFASink&)>,
    "CombinedURLFiltersSwift.processNFAs must take CombinedURLFilters::processNFAs' size_t "
    "unchanged: spelled `Int` in Swift it is ptrdiff_t, and SIZE_MAX silently becomes -1 (R125).");

CombinedURLFilters::CombinedURLFilters(Builder builder)
#if COMBINED_URL_FILTERS_CPP_BUILDER_COMPILED_IN
    : m_prefixTreeRoot(makeUniqueRef<PrefixTreeVertex>())
    , m_island(builder == Builder::Swift ? makeUnique<SwiftIsland>() : nullptr)
#else
    // REGION 2 of 4: with no C++ builder there is nowhere for `Builder::Cpp` to go, and the
    // measurement mode asserts that rather than silently producing an empty rule list.
    : m_island(makeUnique<SwiftIsland>())
#endif
{
#if !COMBINED_URL_FILTERS_CPP_BUILDER_COMPILED_IN
    RELEASE_ASSERT(builder == Builder::Swift);
#endif
}

CombinedURLFilters::~CombinedURLFilters() = default;

bool CombinedURLFilters::isEmpty() const
{
    if (m_island)
        return m_island->island.isEmptyTree();
#if COMBINED_URL_FILTERS_CPP_BUILDER_COMPILED_IN
    return m_prefixTreeRoot->edges.isEmpty();
#else
    RELEASE_ASSERT_NOT_REACHED();
#endif
}

void CombinedURLFilters::addPattern(uint64_t actionId, const Vector<Term>& pattern)
{
    ASSERT_WITH_MESSAGE(!pattern.isEmpty(), "The parser should have excluded empty patterns before reaching CombinedURLFilters.");

    if (pattern.isEmpty())
        return;

    if (m_island) {
        // The whole pattern, in one call. `CombinedURLFiltersPattern` borrows the alphabet and
        // this `Vector<Term>` for the duration, and the island names the pattern's terms by INDEX:
        // it asks whether an edge's interned term equals the term at an index, and interns only
        // where the C++ below would have appended an edge. So no `Term` crosses, interning is as
        // lazy as the C++'s, and the boundary is crossed once per rule rather than once per term
        // -- which is what lets the island's tree be reached through a single `inout` access
        // instead of paying Swift's dynamic exclusivity enforcement on every touch. R124.
        CombinedURLFiltersPattern islandPattern(m_alphabet, pattern);
        m_island->island.addPattern(actionId, islandPattern);
        return;
    }

#if !COMBINED_URL_FILTERS_CPP_BUILDER_COMPILED_IN
    // No other builder to fall through to, and no failure channel on this signature either.
    RELEASE_ASSERT_NOT_REACHED();
#else
    // REGION 3 of 4: building the tree.
    // Extend the prefix tree with the new pattern.
    auto* lastPrefixTree = m_prefixTreeRoot.ptr();

    for (const Term& term : pattern) {
        size_t nextEntryIndex = notFound;
        for (size_t i = 0; i < lastPrefixTree->edges.size(); ++i) {
            // A value comparison against a term that has not been interned yet, which is what it
            // was before ids: interning it here to compare ids instead would add entries to the
            // alphabet for terms the tree already has.
            if (m_alphabet.term(lastPrefixTree->edges[i].termId) == term) {
                nextEntryIndex = i;
                break;
            }
        }
        if (nextEntryIndex != notFound)
            lastPrefixTree = lastPrefixTree->edges[nextEntryIndex].child.get();
        else {
            lastPrefixTree->edges.append(PrefixTreeEdge({m_alphabet.interned(term), makeUnique<PrefixTreeVertex>()}));
            lastPrefixTree = lastPrefixTree->edges.last().child.get();
        }
    }

    auto addResult = m_actions.add(lastPrefixTree, ActionList());
    ActionList& actions = addResult.iterator->value;
    if (actions.find(actionId) == notFound)
        actions.append(actionId);
#endif // COMBINED_URL_FILTERS_CPP_BUILDER_COMPILED_IN
}

// REGION 4 of 4: the walk itself -- the ActiveSubtree stack, the two graph generators, the
// hand-rolled depth-first free of the reverse suffix tree, and the subtree driver.
#if COMBINED_URL_FILTERS_CPP_BUILDER_COMPILED_IN
struct ActiveSubtree {
    ActiveSubtree(PrefixTreeVertex& vertex, ImmutableCharNFANodeBuilder&& nfaNode, unsigned edgeIndex)
        : vertex(vertex)
        , nfaNode(WTF::move(nfaNode))
        , edgeIndex(edgeIndex)
    {
    }
    PrefixTreeVertex& vertex;
    ImmutableCharNFANodeBuilder nfaNode;
    unsigned edgeIndex;
};

static void generateInfixUnsuitableForReverseSuffixTree(const CombinedFiltersAlphabet& alphabet, NFA& nfa, Vector<ActiveSubtree>& stack, const HashMap<const PrefixTreeVertex*, ActionList>& actions)
{
    // To avoid conflicts, we use the reverse suffix tree for subtrees that do not merge
    // in the prefix tree.
    //
    // We only unify the suffixes to the actions on the leaf.
    // If there are actions inside the tree, we generate the part of the subtree up to the action.
    //
    // If we accidentally insert a node with action inside the reverse-suffix-tree, we would create
    // new actions on unrelated pattern when unifying their suffixes.
    for (unsigned i = stack.size() - 1; i--;) {
        ActiveSubtree& activeSubtree = stack[i];
        if (activeSubtree.nfaNode.isValid())
            return;

        RELEASE_ASSERT_WITH_MESSAGE(i > 0, "The bottom of the stack must be the root of our fixed-length subtree. It should have it the isValid() case above.");

        auto actionsIterator = actions.find(&activeSubtree.vertex);
        bool hasActionInsideTree = actionsIterator != actions.end();

        // Stricto sensu, we should count the number of exit edges with fixed length.
        // That is costly and unlikely to matter in practice.
        bool hasSingleOutcome = activeSubtree.vertex.edges.size() == 1;

        if (hasActionInsideTree || !hasSingleOutcome) {
            // Go back to the end of the subtree that has already been generated.
            // From there, generate everything up to the vertex we found.
            unsigned end = i;
            unsigned beginning = end;

            ActiveSubtree* sourceActiveSubtree = nullptr;
            while (beginning--) {
                ActiveSubtree& activeSubtree = stack[beginning];
                if (activeSubtree.nfaNode.isValid()) {
                    sourceActiveSubtree = &activeSubtree;
                    break;
                }
            }
            ASSERT_WITH_MESSAGE(sourceActiveSubtree, "The root should always have a valid generator.");

            for (unsigned stackIndex = beginning + 1; stackIndex <= end; ++stackIndex) {
                ImmutableCharNFANodeBuilder& sourceNode = sourceActiveSubtree->nfaNode;
                ASSERT(sourceNode.isValid());
                auto& edge = sourceActiveSubtree->vertex.edges[sourceActiveSubtree->edgeIndex];

                ActiveSubtree& destinationActiveSubtree = stack[stackIndex];
                destinationActiveSubtree.nfaNode = alphabet.term(edge.termId).generateGraph(nfa, sourceNode, actions.get(&destinationActiveSubtree.vertex));

                sourceActiveSubtree = &destinationActiveSubtree;
            }

            return;
        }
    }
}

static void generateSuffixWithReverseSuffixTree(const CombinedFiltersAlphabet& alphabet, NFA& nfa, Vector<ActiveSubtree>& stack, const HashMap<const PrefixTreeVertex*, ActionList>& actions, ReverseSuffixTreeRoots& reverseSuffixTreeRoots)
{
    ActiveSubtree& leafSubtree = stack.last();
    ASSERT_WITH_MESSAGE(!leafSubtree.nfaNode.isValid(), "The leaf should never be generated by the code above, it should always be inserted into the prefix tree.");

    ActionList actionList = actions.get(&leafSubtree.vertex);
    ASSERT_WITH_MESSAGE(!actionList.isEmpty(), "Our prefix tree should always have actions on the leaves by construction.");

    HashableActionList hashableActionList(actionList);
    auto rootAddResult = reverseSuffixTreeRoots.add(hashableActionList, ReverseSuffixTreeVertex());
    if (rootAddResult.isNewEntry) {
        ImmutableCharNFANodeBuilder newNode(nfa);
        newNode.setActions(WTF::move(actionList));
        rootAddResult.iterator->value.nodeId = newNode.nodeId();
    }

    ReverseSuffixTreeVertex* activeReverseSuffixTreeVertex = &rootAddResult.iterator->value;
    uint32_t destinationNodeId = rootAddResult.iterator->value.nodeId;

    unsigned stackPosition = stack.size() - 2;
    while (true) {
        ActiveSubtree& source = stack[stackPosition];
        auto& edge = source.vertex.edges[source.edgeIndex];

        // This is the end condition: when we meet a node that has already been generated,
        // we just need to connect our backward tree to the forward tree.
        //
        // We *must not* add this last node to the reverse-suffix tree. That node can have
        // transitions back to earlier part of the prefix tree. If the prefix tree "caches"
        // such node, it would create new transitions that did not exist in the source language.
        if (source.nfaNode.isValid()) {
            stack.shrink(stackPosition + 1);
            alphabet.term(edge.termId).generateGraph(nfa, source.nfaNode, destinationNodeId);
            return;
        }
        --stackPosition;

        ASSERT_WITH_MESSAGE(!actions.contains(&source.vertex), "Any node with final actions should have been created before hitting the reverse suffix-tree.");

        ReverseSuffixTreeEdge* existingEdge = nullptr;
        for (ReverseSuffixTreeEdge& potentialExistingEdge : activeReverseSuffixTreeVertex->edges) {
            // Identity, not equality of terms: ids come from the alphabet, so one id means one
            // interned term. Resolving both sides and comparing the Terms would be a value
            // comparison and would make the interning pointless.
            if (edge.termId == potentialExistingEdge.termId) {
                existingEdge = &potentialExistingEdge;
                break;
            }
        }

        if (existingEdge)
            activeReverseSuffixTreeVertex = existingEdge->child.get();
        else {
            ImmutableCharNFANodeBuilder newNode(nfa);
            alphabet.term(edge.termId).generateGraph(nfa, newNode, destinationNodeId);
            std::unique_ptr<ReverseSuffixTreeVertex> newVertex(new ReverseSuffixTreeVertex());
            newVertex->nodeId = newNode.nodeId();

            ReverseSuffixTreeVertex* newVertexAddress = newVertex.get();
            activeReverseSuffixTreeVertex->edges.append(ReverseSuffixTreeEdge({ edge.termId, WTF::move(newVertex) }));
            activeReverseSuffixTreeVertex = newVertexAddress;
        }
        destinationNodeId = activeReverseSuffixTreeVertex->nodeId;

        ASSERT(source.vertex.edges.size() == 1);
        source.vertex.edges.clear();
    }

    RELEASE_ASSERT_NOT_REACHED();
}

static void clearReverseSuffixTree(ReverseSuffixTreeRoots& reverseSuffixTreeRoots)
{
    // We cannot rely on the destructor being called in order from top to bottom as we may overflow
    // the stack. Instead, we go depth first in the reverse-suffix-tree.

    for (auto& slot : reverseSuffixTreeRoots) {
        Vector<ReverseSuffixTreeVertex*, 128> stack;
        stack.append(&slot.value);

        while (true) {
            ReverseSuffixTreeVertex* top = stack.last();
            if (top->edges.isEmpty()) {
                stack.removeLast();
                if (stack.isEmpty())
                    break;
                stack.last()->edges.removeLast();
            } else
                stack.append(top->edges.last().child.get());
        }
    }
    reverseSuffixTreeRoots.clear();
}

static void generateNFAForSubtree(const CombinedFiltersAlphabet& alphabet, NFA& nfa, ImmutableCharNFANodeBuilder&& subtreeRoot, PrefixTreeVertex& root, const HashMap<const PrefixTreeVertex*, ActionList>& actions, size_t maxNFASize)
{
    // This recurses the subtree of the prefix tree.
    // For each edge that has fixed length (no quantifiers like ?, *, or +) it generates the nfa graph,
    // recurses into children, and deletes any processed leaf nodes.

    ReverseSuffixTreeRoots reverseSuffixTreeRoots;
    Vector<ActiveSubtree> stack;
    if (!root.edges.isEmpty())
        stack.append(ActiveSubtree(root, WTF::move(subtreeRoot), 0));

    bool nfaTooBig = false;
    
    // Generate graphs for each subtree that does not contain any quantifiers.
    while (!stack.isEmpty()) {
        PrefixTreeVertex& vertex = stack.last().vertex;
        const unsigned edgeIndex = stack.last().edgeIndex;

        if (edgeIndex < vertex.edges.size()) {
            auto& edge = vertex.edges[edgeIndex];

            // Clean up any processed leaves and return early if we are past the maxNFASize.
            if (nfaTooBig) {
                stack.last().edgeIndex = stack.last().vertex.edges.size();
                continue;
            }
            
            // Quantified edges in the subtree will be a part of another NFA.
            if (!alphabet.term(edge.termId).hasFixedLength()) {
                stack.last().edgeIndex++;
                continue;
            }

            ASSERT(edge.child.get());
            ImmutableCharNFANodeBuilder emptyBuilder;
            stack.append(ActiveSubtree(*edge.child.get(), WTF::move(emptyBuilder), 0));
        } else {
            bool isLeaf = vertex.edges.isEmpty();

            ASSERT(edgeIndex == vertex.edges.size());
            vertex.edges.removeAllMatching([](PrefixTreeEdge& edge)
            {
                return edge.termId == invalidTermId;
            });

            if (isLeaf) {
                generateInfixUnsuitableForReverseSuffixTree(alphabet, nfa, stack, actions);
                generateSuffixWithReverseSuffixTree(alphabet, nfa, stack, actions, reverseSuffixTreeRoots);

                // Only stop generating an NFA at a leaf to ensure we have a correct NFA. We could go slightly over the maxNFASize.
                if (nfa.nodes.size() > maxNFASize)
                    nfaTooBig = true;
            } else
                stack.removeLast();

            if (!stack.isEmpty()) {
                auto& activeSubtree = stack.last();
                auto& edge = activeSubtree.vertex.edges[stack.last().edgeIndex];
                if (edge.child->edges.isEmpty())
                    edge.termId = invalidTermId; // Mark this leaf for deleting.
                activeSubtree.edgeIndex++;
            }
        }
    }
    clearReverseSuffixTree(reverseSuffixTreeRoots);
}

#endif // COMBINED_URL_FILTERS_CPP_BUILDER_COMPILED_IN

bool CombinedURLFilters::processNFAs(size_t maxNFASize, Function<bool(NFA&&)>&& handler)
{
    if (m_island) {
        // The sink is the whole of the added C++: a `WTF::Function` is not something Swift can
        // call, so it is borrowed for the duration of this one call and never stored.
        //
        // `maxNFASize` goes over unconverted -- the static_asserts above are what keeps that true.
        CombinedURLFiltersNFASink sink(handler);
        return m_island->island.processNFAs(maxNFASize, m_alphabet, sink);
    }

#if !COMBINED_URL_FILTERS_CPP_BUILDER_COMPILED_IN
    RELEASE_ASSERT_NOT_REACHED();
#else
    // REGION 4b of 4: the driver.
#if CONTENT_EXTENSIONS_STATE_MACHINE_DEBUGGING && COMBINED_URL_FILTERS_CPP_BUILDER_COMPILED_IN
    print();
#endif
    while (true) {
        // Traverse out to a leaf.
        Vector<PrefixTreeVertex*, 128> stack;
        auto* vertex = m_prefixTreeRoot.ptr();
        while (true) {
            ASSERT(vertex);
            stack.append(vertex);
            if (vertex->edges.isEmpty())
                break;
            vertex = vertex->edges.last().child.get();
        }
        if (stack.size() == 1)
            break; // We're done once we have processed and removed all the edges in the prefix tree.
        
        // Find the prefix root for this NFA. This is the vertex after the last term with a quantifier if there is one,
        // or the root if there are no quantifiers left.
        while (stack.size() > 1) {
            if (!m_alphabet.term(stack[stack.size() - 2]->edges.last().termId).hasFixedLength())
                break;
            stack.removeLast();
        }
        ASSERT_WITH_MESSAGE(!stack.isEmpty(), "At least the root should be in the stack");

        // Make an NFA with the subtrees for whom this is also the last quantifier (or who also have no quantifier).
        NFA nfa;
        {
            // Put the prefix into the NFA.
            ImmutableCharNFANodeBuilder lastNode(nfa);
            for (unsigned i = 0; i < stack.size() - 1; ++i) {
                const PrefixTreeEdge& edge = stack[i]->edges.last();
                ImmutableCharNFANodeBuilder newNode = m_alphabet.term(edge.termId).generateGraph(nfa, lastNode, m_actions.get(edge.child.get()));
                lastNode = WTF::move(newNode);
            }

            // Put the non-quantified vertices in the subtree into the NFA and delete them.
            ASSERT(stack.last());
            generateNFAForSubtree(m_alphabet, nfa, WTF::move(lastNode), *stack.last(), m_actions, maxNFASize);
        }

        if (!handler(WTF::move(nfa)))
            return false;

        // Clean up any processed leaf nodes.
        while (true) {
            if (stack.size() > 1) {
                if (stack[stack.size() - 1]->edges.isEmpty()) {
                    stack[stack.size() - 2]->edges.removeLast();
                    stack.removeLast();
                } else
                    break; // Vertex is not a leaf.
            } else
                break; // Leave the empty root.
        }
    }
    return true;
#endif // COMBINED_URL_FILTERS_CPP_BUILDER_COMPILED_IN
}

} // namespace ContentExtensions
} // namespace WebCore

#endif // ENABLE(CONTENT_EXTENSIONS)
