/*
 * Copyright (C) 2024-2025 Samuel Weinig <sam@webkit.org>
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include "CSSCalcTree.h"
#include <wtf/StdLibExtras.h>

namespace WebCore {
namespace CSSCalc {

// MARK: Traversal

// MARK: - forAllChildren

// `forAllChildren` will call the provided `functor` on all direct children of the provided node. This will include values of type `Child`, `ChildOrNone` and `std::optional<Child>`.

template<typename F, Leaf Op> void forAllChildren(const auto&, const F&)
{
    // No children.
}

template<typename F, typename Op> void forAllChildren(const Op& root, const F& functor)
{
    struct Caller {
        const F& functor;

        void operator()(const Children& children)
        {
            for (auto& child : children)
                functor(child);
        }
        void operator()(const std::optional<Child>& root)
        {
            functor(root);
        }
        void operator()(const ChildOrNone& root)
        {
            functor(root);
        }
        void operator()(const Child& root)
        {
            functor(root);
        }
        void operator()(const CSS::CustomIdent& root)
        {
            functor(root);
        }
    };
    auto caller = Caller { functor };
    WTF::apply([&](const auto& ...x) { (..., caller(x)); }, root);
}

template<typename F> void forAllChildren(const Child& root, const F& functor)
{
    WTF::switchOn(root, [&](const auto& root) { forAllChildren(*root, functor); });
}

// MARK: - forAllChildNodes

// `forAllChildNodes` will call the provided `functor` on all direct `Child` typed children of the provided node. If a child is of type `ChildOrNone` or `std::optional<Child>`, the functor will be called on the unwrapped `Child` if and only if that is what the type is holding.

template<typename F, Leaf Op> void forAllChildNodes(const Op&, const F&)
{
    // No children.
}

template<typename F, typename Op> void forAllChildNodes(const Op& root, const F& functor)
{
    struct Caller {
        const F& functor;

        void operator()(const Children& children)
        {
            for (auto& child : children)
                functor(child);
        }
        void operator()(const std::optional<Child>& root)
        {
            if (root)
                functor(*root);
        }
        void operator()(const ChildOrNone& root)
        {
            WTF::switchOn(root,
                [&](const Child& root) { functor(root); },
                [&](const CSS::Keyword::None&) { }
            );
        }
        void operator()(const Child& root)
        {
            functor(root);
        }
        void operator()(const CSS::CustomIdent&)
        {
        }
        void operator()(const Random::Sharing&)
        {
        }
        // `CalcMix`'s single tuple element is a `Vector<CalcMix::Item>` rather than a `Children`,
        // because each argument carries an optional weight beside its value. The weight is not a
        // `Child`, so only the value is visited, which is what "child nodes" means here.
        void operator()(const Vector<CalcMix::Item>& items)
        {
            for (auto& item : items)
                functor(item.value);
        }
    };
    auto caller = Caller { functor };
    WTF::apply([&](const auto& ...x) { (..., caller(x)); }, root);
}

template<typename F> void forAllChildNodes(const Child& root, const F& functor)
{
    WTF::switchOn(root, [&](const auto& root) { forAllChildNodes(*root, functor); });
}

// MARK: - childNodeCountOf / childNodeAt

// The same set of children `forAllChildNodes` yields, answered by count and by index instead of by
// visit.
//
// `forAllChildNodes` is the wrong shape for both questions: counting with it visits every child,
// and finding the `index`th with it visits every child *and* has no early exit, so reading a node's
// children one at a time costs O(children^2) visits. These walk the tuple SLOTS -- of which the
// widest operation has four -- and consult a `Children`'s size rather than its elements, so both
// are O(1) in the child count.
//
// Everything below mirrors `forAllChildNodes`' `Caller` case for case, deliberately: the three
// answers have to agree about what a child is, and the cheapest way to keep them agreeing is for
// the case lists to be diffable against each other.

template<Leaf Op> uint32_t childNodeCountOf(const Op&)
{
    return 0;
}

template<typename Op> uint32_t childNodeCountOf(const Op& root)
{
    struct Caller {
        uint32_t count { 0 };

        void operator()(const Children& children) { count += children.size(); }
        void operator()(const std::optional<Child>& root) { count += root ? 1 : 0; }
        void operator()(const ChildOrNone& root) { count += WTF::holdsAlternative<Child>(root) ? 1 : 0; }
        void operator()(const Child&) { ++count; }
        void operator()(const CSS::CustomIdent&) { }
        void operator()(const Random::Sharing&) { }
        void operator()(const Vector<CalcMix::Item>& items) { count += items.size(); }
    };
    Caller caller;
    WTF::apply([&](const auto& ...x) { (..., caller(x)); }, root);
    return caller.count;
}

template<Leaf Op> const Child* childNodeAt(const Op&, uint32_t)
{
    return nullptr;
}

template<typename Op> const Child* childNodeAt(const Op& root, uint32_t index)
{
    struct Caller {
        // Counts down rather than up, so a slot can answer "not mine" by subtracting its own size
        // without needing to know how many slots came before it.
        uint32_t remaining;
        const Child* found { nullptr };

        void operator()(const Children& children)
        {
            if (found)
                return;
            if (remaining < children.size()) {
                found = &children[remaining];
                return;
            }
            remaining -= children.size();
        }
        void operator()(const std::optional<Child>& root) { single(root ? &*root : nullptr); }
        void operator()(const ChildOrNone& root) { single(get_if<Child>(&root)); }
        void operator()(const Child& root) { single(&root); }
        void operator()(const CSS::CustomIdent&) { }
        void operator()(const Random::Sharing&) { }
        void operator()(const Vector<CalcMix::Item>& items)
        {
            if (found)
                return;
            if (remaining < items.size()) {
                found = &items[remaining].value;
                return;
            }
            remaining -= items.size();
        }

        // A slot holding at most one child. `nullptr` means the slot is present in the tuple but
        // empty -- an absent `std::optional`, or a `ChildOrNone` holding the keyword -- which
        // `forAllChildNodes` skips and so does this.
        void single(const Child* child)
        {
            if (found || !child)
                return;
            if (!remaining) {
                found = child;
                return;
            }
            --remaining;
        }
    };
    Caller caller { .remaining = index };
    WTF::apply([&](const auto& ...x) { (..., caller(x)); }, root);
    return caller.found;
}

} // namespace CSSCalc
} // namespace WebCore
