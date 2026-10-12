#!/usr/bin/env python3
#
# Copyright (C) 2026 Apple Inc. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1.  Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
# 2.  Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS BE LIABLE FOR
# ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import argparse
import json
import os
import re
import sys

# Generates amended copies of the Swift Windows SDK's vcruntime.modulemap and
# winsdk_um.modulemap, plus a VFS overlay that mounts them over the SDK's own copies.
#
# The overlay is for swiftc's -vfsoverlay, not clang's -ivfsoverlay: the Swift clang
# importer reads SDKROOT/usr/share/*.modulemap through Swift's file system and injects
# them as module.modulemap files in the MSVC and Windows SDK include directories on top
# of any clang overlays, so a clang overlay of those module.modulemap files is silently
# shadowed.
#
# Both amendments fix the same problem: a header that no module declares is owned by
# whichever submodule happens to include it first, so its declarations are invisible to
# code that includes it through some other submodule. With C++23, <queue> and <stack>
# include __msvc_ranges_to.hpp, so std.queue owns std::views::transform and <ranges>
# alone does not provide it. Likewise <windows.h> does not provide HWND, because
# windef.h is owned by whichever WinSDK submodule includes it first.
#
# The STL additions have to go inside `std._Private` rather than into a separate module
# of our own: these headers include other STL headers, and STL headers include them,
# so a separate top-level module would form a cyclic dependency with `std`.
#
# Writes the amended modulemaps and <output-dir>/vfs-overlay.yaml, and prints the path
# of the overlay to stdout for cmake to put on the swiftc command line.

# An aggregate that pulls in the whole STL; giving it a module of its own is not useful.
EXCLUDED_HEADERS = frozenset(['__msvc_all_public_headers.hpp'])

# `module _Private [system] {` inside the `std` module, plus any `requires` lines that
# open it, so that the additions land after them. Anchoring on the containing submodule
# rather than on one of its entries keeps this working if the SDK reshuffles which
# __msvc_*.hpp headers it happens to name.
PRIVATE_MODULE_RE = re.compile(
    r'^(?P<indent>[ \t]*)module _Private\b[^\n]*\{[ \t]*\n'
    r'(?:[ \t]*(?:requires[^\n]*)?\n)*', re.MULTILINE)

# The opening line of the top-level `module WinSDK [system] {` in winsdk_um.modulemap.
WINSDK_MODULE_RE = re.compile(r'^module WinSDK\b[^\n]*\{[ \t]*\n', re.MULTILINE)

# winsdk_um.modulemap lives in um/; windef.h is in the sibling shared/ directory.
WINDEF_HEADER = '../shared/windef.h'


def declared_headers(modulemap_text):
    return frozenset(re.findall(r'header\s+"([^"]+)"', modulemap_text))


def amend_modulemap(modulemap_text, headers):
    already_declared = declared_headers(modulemap_text)
    missing = sorted(h for h in headers if h not in already_declared and h not in EXCLUDED_HEADERS)
    if not missing:
        return modulemap_text, []

    match = PRIVATE_MODULE_RE.search(modulemap_text)
    if not match:
        raise ValueError("could not find the `module _Private` block to extend")

    indent = match.group('indent') + '  '
    additions = ''
    for header in missing:
        module_name = os.path.splitext(header)[0]
        additions += '%sexplicit module %s {\n' % (indent, module_name)
        additions += '%s  header "%s"\n' % (indent, header)
        additions += '%s  export *\n' % indent
        additions += '%s}\n\n' % indent

    insertion_point = match.end()
    return modulemap_text[:insertion_point] + additions + modulemap_text[insertion_point:], missing


def amend_winsdk_um_modulemap(modulemap_text):
    if WINDEF_HEADER in declared_headers(modulemap_text):
        return modulemap_text, []

    match = WINSDK_MODULE_RE.search(modulemap_text)
    if not match:
        raise ValueError("could not find the `module WinSDK` block to extend")

    addition = '  module WinDef {\n    header "%s"\n    export *\n  }\n\n' % WINDEF_HEADER
    insertion_point = match.end()
    return modulemap_text[:insertion_point] + addition + modulemap_text[insertion_point:], [WINDEF_HEADER]


def write_if_changed(path, contents):
    try:
        with open(path, 'r') as f:
            if f.read() == contents:
                return False
    except OSError:
        pass
    with open(path, 'w') as f:
        f.write(contents)
    return True


def vfs_overlay(mounts):
    roots = {}
    for sdk_modulemap, modulemap_path in mounts:
        directory = os.path.dirname(sdk_modulemap).replace('\\', '/')
        roots.setdefault(directory, []).append({
            'name': os.path.basename(sdk_modulemap),
            'type': 'file',
            'external-contents': modulemap_path.replace('\\', '/'),
        })
    return {
        'version': 0,
        'case-sensitive': 'false',
        'roots': [{'name': d, 'type': 'directory', 'contents': c} for d, c in roots.items()],
    }


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk-modulemap', required=True,
                        help='the Swift SDK\'s usr/share/vcruntime.modulemap')
    parser.add_argument('--winsdk-um-modulemap',
                        help='the Swift SDK\'s usr/share/winsdk_um.modulemap')
    parser.add_argument('--output-dir', required=True,
                        help='where to write the amended modulemaps and vfs-overlay.yaml')
    parser.add_argument('--headers', nargs='*', default=[], metavar='HEADER',
                        help='__msvc_*.hpp header names, relative to the MSVC include directory')
    args = parser.parse_args(argv[1:])

    if not args.headers:
        raise ValueError('no __msvc_*.hpp headers given')

    amendments = []
    with open(args.sdk_modulemap, 'r') as f:
        amendments.append((args.sdk_modulemap, *amend_modulemap(f.read(), args.headers)))
    if args.winsdk_um_modulemap:
        with open(args.winsdk_um_modulemap, 'r') as f:
            amendments.append((args.winsdk_um_modulemap, *amend_winsdk_um_modulemap(f.read())))

    amendments = [a for a in amendments if a[2]]
    if not amendments:
        print('the SDK modulemaps already declare every header this script adds', file=sys.stderr)
        return 0

    os.makedirs(args.output_dir, exist_ok=True)
    overlay_path = os.path.join(args.output_dir, 'vfs-overlay.yaml')

    wrote = False
    mounts = []
    for sdk_modulemap, amended, _ in amendments:
        modulemap_path = os.path.join(args.output_dir, os.path.basename(sdk_modulemap))
        wrote |= write_if_changed(modulemap_path, amended)
        mounts.append((os.path.abspath(sdk_modulemap), modulemap_path))
    overlay = json.dumps(vfs_overlay(mounts), indent=2) + '\n'
    wrote |= write_if_changed(overlay_path, overlay)

    if wrote:
        for sdk_modulemap, _, added in amendments:
            print('%s: declared %d header(s): %s' % (os.path.basename(sdk_modulemap), len(added), ' '.join(added)), file=sys.stderr)
    print(overlay_path.replace('\\', '/'))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv))
    except (OSError, ValueError) as error:
        print('%s: %s' % (os.path.basename(sys.argv[0]), error), file=sys.stderr)
        sys.exit(1)
