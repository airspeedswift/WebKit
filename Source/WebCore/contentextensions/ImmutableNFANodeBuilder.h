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

#pragma once

#include <WebCore/ImmutableNFA.h>
#include <WebCore/MutableRangeList.h>
#include <wtf/HashSet.h>
#include <wtf/SwiftBridging.h>

#if ENABLE(CONTENT_EXTENSIONS)

namespace WebCore {

namespace ContentExtensions {

// A ImmutableNFANodeBuilder let you build an NFA node by adding states and linking with other nodes.
// When a builder is destructed, all its properties are finalized into the NFA. Using the NFA with a live
// builder results in undefined behavior.
// SWIFT_SAFE: Swift imports the builder as unsafe because of the raw `TypedImmutableNFA*` back
// pointer. The pointer is never handed out, and the class maintains the invariant that
// `m_finalized` is true whenever it is null -- the default constructor leaves both in that state,
// and the move constructor and move assignment restore it in the source -- so the destructor and
// `finalize()` never dereference null. `isValid()` reports the pointer's presence rather than
// exposing it. Without this, every mention of the builder from Swift costs an `unsafe` marker.
//
// The annotation does NOT claim the aliasing rule noted above is enforced: touching the NFA while
// a builder is live is undefined behaviour in C++ and would remain so from Swift. Swift's own
// exclusivity checking is what covers it there, because the builder holds the NFA `inout`.
template <typename CharacterType, typename ActionType>
class SWIFT_SAFE ImmutableNFANodeBuilder {
    typedef ImmutableNFA<CharacterType, ActionType> TypedImmutableNFA;
    typedef HashSet<uint32_t, DefaultHash<uint32_t>, WTF::UnsignedWithZeroKeyHashTraits<uint32_t>> TargetSet;
public:
    ImmutableNFANodeBuilder() { }

    ImmutableNFANodeBuilder(TypedImmutableNFA& immutableNFA)
        : m_immutableNFA(&immutableNFA)
        , m_finalized(false)
    {
        m_nodeId = m_immutableNFA->nodes.size();
        m_immutableNFA->nodes.append(ImmutableNFANode());
    }

    ImmutableNFANodeBuilder(ImmutableNFANodeBuilder&& other)
        : m_immutableNFA(other.m_immutableNFA)
        , m_ranges(WTF::move(other.m_ranges))
        , m_epsilonTransitionTargets(WTF::move(other.m_epsilonTransitionTargets))
        , m_actions(WTF::move(other.m_actions))
        , m_nodeId(other.m_nodeId)
        , m_finalized(other.m_finalized)
    {
        other.m_immutableNFA = nullptr;
        other.m_finalized = true;
    }

    ~ImmutableNFANodeBuilder()
    {
        if (!m_finalized)
            finalize();
    }

    bool isValid() const
    {
        return !!m_immutableNFA;
    }

    uint32_t nodeId() const
    {
        ASSERT(isValid());
        return m_nodeId;
    }

    struct TrivialRange {
        CharacterType first;
        CharacterType last;
    };
    
    struct FakeRangeIterator {
        CharacterType first() const { return range.first; }
        CharacterType last() const { return range.last; }
        uint32_t data() const { return targetId; }
        bool operator==(const FakeRangeIterator& other) const
        {
            return this->isEnd == other.isEnd;
        }
        FakeRangeIterator operator++()
        {
            isEnd = true;
            return *this;
        }
        
        TrivialRange range;
        uint32_t targetId;
        bool isEnd;
    };

    void addTransition(CharacterType first, CharacterType last, uint32_t targetNodeId)
    {
        ASSERT(!m_finalized);
        ASSERT(m_immutableNFA);

        struct Converter {
            TargetSet convert(uint32_t target)
            {
                return TargetSet({ target });
            }
            void extend(TargetSet& existingTargets, uint32_t target)
            {
                existingTargets.add(target);
            }
        };
        
        Converter converter;
        m_ranges.extend(FakeRangeIterator { { first, last }, targetNodeId, false }, FakeRangeIterator { { 0, 0 }, targetNodeId, true }, converter);
    }

    void addEpsilonTransition(const ImmutableNFANodeBuilder& target)
    {
        ASSERT(m_immutableNFA == target.m_immutableNFA);
        addEpsilonTransition(target.m_nodeId);
    }

    void addEpsilonTransition(uint32_t targetNodeId)
    {
        ASSERT(!m_finalized);
        ASSERT(m_immutableNFA);
        m_epsilonTransitionTargets.add(targetNodeId);
    }

    template<typename ActionContainer>
    void setActions(ActionContainer&& actions)
    {
        ASSERT(!m_finalized);
        ASSERT(m_immutableNFA);

        m_actions.addAll(WTF::move(actions));
    }

    // The one instantiation content extensions actually use, named so that Swift can reach it:
    // the importer does not bring across the function template above (measured -- "has no member
    // 'setActions'", cxprobe/termimport/armcalls.swift), and a forwarding reference has nothing
    // for it to deduce from. Forwards, so the two spellings cannot drift.
    void setActionList(Vector<ActionType, 0, CrashOnOverflow, 1>&& actions)
    {
        setActions(WTF::move(actions));
    }

    // Sink this node's accumulated ranges, epsilon transitions and actions into the NFA now,
    // rather than whenever the builder happens to be destroyed.
    //
    // The order in which builders finalize decides how the five parallel NFA vectors are packed,
    // and that packing is observable (SerializedNFA stores the offsets). C++ gets the order from
    // scope exit and from Vector<ActiveSubtree>'s destruct order; Swift's release timing for an
    // imported C++ value is not the same thing, and for a builder held behind a class reference
    // it is ARC's business rather than the algorithm's. Calling this at each point the C++ would
    // have destroyed the builder makes the packing an explicit part of the algorithm in both
    // languages -- and the destructor still finalizes, so nothing that does not call it changes.
    void finalizeNow()
    {
        if (!m_finalized)
            finalize();
    }

    ImmutableNFANodeBuilder& operator=(ImmutableNFANodeBuilder&& other)
    {
        if (!m_finalized)
            finalize();

        m_immutableNFA = other.m_immutableNFA;
        m_ranges = WTF::move(other.m_ranges);
        m_epsilonTransitionTargets = WTF::move(other.m_epsilonTransitionTargets);
        m_actions = WTF::move(other.m_actions);
        m_nodeId = other.m_nodeId;
        m_finalized = other.m_finalized;

        other.m_immutableNFA = nullptr;
        other.m_finalized = true;
        return *this;
    }

private:
    void finalize()
    {
        ASSERT_WITH_MESSAGE(!m_finalized, "The API contract is that the builder can only be finalized once.");
        m_finalized = true;
        ImmutableNFANode& immutableNFANode = m_immutableNFA->nodes[m_nodeId];
        sinkActions(immutableNFANode);
        sinkEpsilonTransitions(immutableNFANode);
        sinkTransitions(immutableNFANode);
    }

    void sinkActions(ImmutableNFANode& immutableNFANode)
    {
        unsigned actionStart = m_immutableNFA->actions.size();
        for (const ActionType& action : m_actions)
            m_immutableNFA->actions.append(action);
        unsigned actionEnd = m_immutableNFA->actions.size();
        immutableNFANode.actionStart = actionStart;
        immutableNFANode.actionEnd = actionEnd;
    }

    void sinkTransitions(ImmutableNFANode& immutableNFANode)
    {
        unsigned transitionsStart = m_immutableNFA->transitions.size();
        for (const auto& range : m_ranges) {
            unsigned targetsStart = m_immutableNFA->targets.size();
            for (uint32_t target : range.data)
                m_immutableNFA->targets.append(target);
            unsigned targetsEnd = m_immutableNFA->targets.size();

            ImmutableRange<CharacterType> transition;
            transition.targetStart = targetsStart;
            transition.targetEnd = targetsEnd;
            transition.first = range.first;
            transition.last = range.last;
            m_immutableNFA->transitions.append(WTF::move(transition));
        }
        unsigned transitionsEnd = m_immutableNFA->transitions.size();

        immutableNFANode.rangesStart = transitionsStart;
        immutableNFANode.rangesEnd = transitionsEnd;
    }

    void sinkEpsilonTransitions(ImmutableNFANode& immutableNFANode)
    {
        unsigned start = m_immutableNFA->epsilonTransitionsTargets.size();
        for (uint32_t target : m_epsilonTransitionTargets)
            m_immutableNFA->epsilonTransitionsTargets.append(target);
        unsigned end = m_immutableNFA->epsilonTransitionsTargets.size();

        immutableNFANode.epsilonTransitionTargetsStart = start;
        immutableNFANode.epsilonTransitionTargetsEnd = end;
    }

    TypedImmutableNFA* m_immutableNFA { nullptr };
    MutableRangeList<CharacterType, TargetSet> m_ranges;
    TargetSet m_epsilonTransitionTargets;
    HashSet<ActionType, IntHash<ActionType>, WTF::UnsignedWithZeroKeyHashTraits<ActionType>> m_actions;
    uint32_t m_nodeId;
    bool m_finalized { true };
};

} // namespace ContentExtensions
} // namespace WebCore

#endif // ENABLE(CONTENT_EXTENSIONS)
