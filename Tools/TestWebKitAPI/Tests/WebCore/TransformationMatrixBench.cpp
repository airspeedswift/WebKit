/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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

#include "Helpers/Test.h"
#include <WebCore/TransformationMatrix.h>
#include <bit>
#include <cmath>
#include <cstdlib>
#include <iomanip>
#include <optional>
#include <string_view>
#include <vector>
#include <wtf/MonotonicTime.h>
#include <wtf/StdLibExtras.h>
#include <wtf/text/ASCIILiteral.h>

// Times TransformationMatrix's multiply(), inverse(), rotate3d(), applyPerspective(), decompose4() and blend4(), one test
// per kind of input. Each test checks a checksum of one pass, on ARM64 only because rounding differs by CPU. With
// WEBKIT_RUN_BENCHMARKS=1 it also repeats the pass for about a second and prints the time.

using namespace WebCore;

namespace TestWebKitAPI {

namespace {

constexpr unsigned passSize = 4096;

class Random {
public:
    explicit Random(uint64_t seed)
        : m_state(seed)
    {
    }

    // A value in [low, high).
    double between(double low, double high)
    {
        m_state ^= m_state >> 12;
        m_state ^= m_state << 25;
        m_state ^= m_state >> 27;
        uint64_t bits = m_state * 2685821657736338717ull;
        return low + (high - low) * (static_cast<double>(bits >> 11) * 0x1p-53);
    }

private:
    uint64_t m_state;
};

struct Checksum {
    uint64_t value { 1469598103934665603ull };

    void add(uint64_t word)
    {
        for (unsigned i = 0; i < 8; ++i) {
            value ^= (word >> (8 * i)) & 0xff;
            value *= 1099511628211ull;
        }
    }

    void add(double number)
    {
        add(std::isnan(number) ? 0x7ff8000000000000ull : std::bit_cast<uint64_t>(number));
    }

    void add(const TransformationMatrix& matrix)
    {
        auto numbers = { matrix.m11(), matrix.m12(), matrix.m13(), matrix.m14(), matrix.m21(), matrix.m22(), matrix.m23(), matrix.m24(),
            matrix.m31(), matrix.m32(), matrix.m33(), matrix.m34(), matrix.m41(), matrix.m42(), matrix.m43(), matrix.m44() };
        for (double number : numbers)
            add(number);
    }

    void add(const TransformationMatrix::Decomposed4Type& decomposition)
    {
        auto numbers = { decomposition.scaleX, decomposition.scaleY, decomposition.scaleZ, decomposition.skewXY, decomposition.skewXZ, decomposition.skewYZ,
            decomposition.quaternion.x, decomposition.quaternion.y, decomposition.quaternion.z, decomposition.quaternion.w,
            decomposition.translateX, decomposition.translateY, decomposition.translateZ,
            decomposition.perspectiveX, decomposition.perspectiveY, decomposition.perspectiveZ, decomposition.perspectiveW };
        for (double number : numbers)
            add(number);
    }
};

// All sixteen entries in [-1, 1).
TransformationMatrix denseMatrix(Random& random)
{
    double entries[16];
    for (auto& entry : entries)
        entry = random.between(-1, 1);
    return TransformationMatrix(entries[0], entries[1], entries[2], entries[3], entries[4], entries[5], entries[6], entries[7],
        entries[8], entries[9], entries[10], entries[11], entries[12], entries[13], entries[14], entries[15]);
}

// A 2D affine transform close to a scale.
TransformationMatrix affineMatrix(Random& random)
{
    return TransformationMatrix(random.between(1, 2), random.between(-0.5, 0.5), random.between(-0.5, 0.5), random.between(1, 2),
        random.between(-100, 100), random.between(-100, 100));
}

// An invertible 3D transform: a diagonally dominant upper 3x3 and a translation, with small perspective terms if asked.
TransformationMatrix invertibleMatrix(Random& random, bool withPerspective)
{
    auto diagonal = [&] {
        return (random.between(0, 1) < 0.5 ? -1 : 1) * random.between(3, 5);
    };
    auto perspective = [&] {
        return withPerspective ? random.between(-0.01, 0.01) : 0;
    };
    double m11 = diagonal();
    double m12 = random.between(-1, 1);
    double m13 = random.between(-1, 1);
    double m14 = perspective();
    double m21 = random.between(-1, 1);
    double m22 = diagonal();
    double m23 = random.between(-1, 1);
    double m24 = perspective();
    double m31 = random.between(-1, 1);
    double m32 = random.between(-1, 1);
    double m33 = diagonal();
    double m34 = perspective();
    return TransformationMatrix(m11, m12, m13, m14, m21, m22, m23, m24, m31, m32, m33, m34,
        random.between(-100, 100), random.between(-100, 100), random.between(-100, 100), 1);
}

// The matrix with the first column of its upper 3x3 cleared, which makes it singular.
TransformationMatrix singularMatrix(TransformationMatrix matrix)
{
    matrix.setM11(0);
    matrix.setM12(0);
    matrix.setM13(0);
    return matrix;
}

struct Input {
    std::vector<TransformationMatrix> matrices;
    std::vector<double> parameters;
};

template<typename MakeMatrix>
Input makeInput(uint64_t seed, unsigned count, MakeMatrix&& makeMatrix, unsigned parametersPerMatrix = 0, double parameterLow = 0, double parameterHigh = 0)
{
    Random random(seed);
    Input input;
    input.matrices.reserve(count);
    input.parameters.reserve(count * parametersPerMatrix);
    for (unsigned i = 0; i < count; ++i) {
        input.matrices.push_back(makeMatrix(random));
        for (unsigned j = 0; j < parametersPerMatrix; ++j)
            input.parameters.push_back(random.between(parameterLow, parameterHigh));
    }
    return input;
}

bool runsBenchmarks()
{
    auto* value = getenv("WEBKIT_RUN_BENCHMARKS");
    return value && *value && std::string_view(value) != "0";
}

// A pass writes its results to `results`, and adds them to the checksum if it is given one.
template<typename Pass>
void runBenchmark(ASCIILiteral name, const Input& input, unsigned bytesPerPass, unsigned iterations, uint64_t expectedChecksum, const Pass& pass)
{
    std::vector<TransformationMatrix> results;
    Checksum checksum;
    pass(input, results, &checksum);
#if CPU(ARM64)
    EXPECT_EQ(checksum.value, expectedChecksum) << "checksum=" << std::hex << std::setfill('0') << std::setw(16) << checksum.value;
#else
    UNUSED_PARAM(expectedChecksum);
#endif

    if (!runsBenchmarks())
        return;

    auto start = MonotonicTime::now();
    for (unsigned i = 0; i < iterations; ++i)
        pass(input, results, static_cast<Checksum*>(nullptr));
    double seconds = (MonotonicTime::now() - start).seconds();

    Checksum lastPass;
    pass(input, results, &lastPass);
    EXPECT_EQ(lastPass.value, checksum.value);

    SAFE_PRINTF("%s: %.1f ms %.1f MB/s checksum=%016llx\n", name, seconds * 1000, static_cast<double>(bytesPerPass) * iterations / seconds / 1e6, static_cast<unsigned long long>(checksum.value));
}

// Products of chains of `chainLength` matrices, as a list of CSS transform functions is combined.
void multiplyChains(const Input& input, std::vector<TransformationMatrix>& results, Checksum* checksum, unsigned chainLength)
{
    results.resize(input.matrices.size() / chainLength);
    for (size_t chain = 0; chain < results.size(); ++chain) {
        auto product = input.matrices[chain * chainLength];
        for (unsigned i = 1; i < chainLength; ++i)
            product.multiply(input.matrices[chain * chainLength + i]);
        results[chain] = product;
    }
    if (checksum) {
        for (auto& result : results)
            checksum->add(result);
    }
}

void inverses(const Input& input, std::vector<TransformationMatrix>& results, Checksum* checksum)
{
    results.resize(input.matrices.size());
    unsigned invertible = 0;
    for (size_t i = 0; i < input.matrices.size(); ++i) {
        auto inverse = input.matrices[i].inverse();
        invertible += !!inverse;
        results[i] = inverse.value_or(TransformationMatrix { });
    }
    if (checksum) {
        checksum->add(static_cast<uint64_t>(invertible));
        for (auto& result : results)
            checksum->add(result);
    }
}

void addAll(const std::vector<TransformationMatrix>& results, Checksum* checksum)
{
    if (!checksum)
        return;
    for (auto& result : results)
        checksum->add(result);
}

} // namespace

TEST(TransformationMatrixBench, Multiply3D)
{
    auto input = makeInput(1, passSize, denseMatrix);
    runBenchmark("Multiply3D"_s, input, passSize * sizeof(TransformationMatrix), 60000, 0x45a7bea9f8e61ec1ull, [](auto& input, auto& results, auto* checksum) {
        multiplyChains(input, results, checksum, 16);
    });
}

TEST(TransformationMatrixBench, MultiplyAffine)
{
    auto input = makeInput(2, passSize, affineMatrix);
    runBenchmark("MultiplyAffine"_s, input, passSize * sizeof(TransformationMatrix), 75000, 0x9c3eb6d3c9af14beull, [](auto& input, auto& results, auto* checksum) {
        multiplyChains(input, results, checksum, 8);
    });
}

// One matrix in 64 is singular.
TEST(TransformationMatrixBench, Inverse3D)
{
    auto input = makeInput(3, passSize, [index = 0u](Random& random) mutable {
        auto matrix = invertibleMatrix(random, false);
        return index++ % 64 == 63 ? singularMatrix(matrix) : matrix;
    });
    runBenchmark("Inverse3D"_s, input, passSize * sizeof(TransformationMatrix), 30000, 0xfaddb182a4c938a1ull, inverses);
}

TEST(TransformationMatrixBench, InversePerspective)
{
    auto input = makeInput(4, passSize, [](Random& random) {
        return invertibleMatrix(random, true);
    });
    runBenchmark("InversePerspective"_s, input, passSize * sizeof(TransformationMatrix), 30000, 0x1136cb6c1329a106ull, inverses);
}

TEST(TransformationMatrixBench, InverseAffine)
{
    auto input = makeInput(5, passSize, affineMatrix);
    runBenchmark("InverseAffine"_s, input, passSize * sizeof(TransformationMatrix), 65000, 0xdcdfb834bf637c38ull, inverses);
}

TEST(TransformationMatrixBench, Rotate3D)
{
    auto input = makeInput(6, passSize, [](Random& random) {
        return invertibleMatrix(random, false);
    }, 3, -360, 360);
    runBenchmark("Rotate3D"_s, input, passSize * sizeof(TransformationMatrix), 9000, 0x969bd327477aa4d8ull, [](auto& input, auto& results, auto* checksum) {
        results.resize(input.matrices.size());
        for (size_t i = 0; i < input.matrices.size(); ++i) {
            auto matrix = input.matrices[i];
            matrix.rotate3d(input.parameters[3 * i], input.parameters[3 * i + 1], input.parameters[3 * i + 2]);
            results[i] = matrix;
        }
        addAll(results, checksum);
    });
}

TEST(TransformationMatrixBench, ApplyPerspective)
{
    auto input = makeInput(7, passSize, [](Random& random) {
        return invertibleMatrix(random, false);
    }, 1, 100, 2000);
    runBenchmark("ApplyPerspective"_s, input, passSize * sizeof(TransformationMatrix), 42000, 0x03bbb16cb0a6cbd8ull, [](auto& input, auto& results, auto* checksum) {
        results.resize(input.matrices.size());
        for (size_t i = 0; i < input.matrices.size(); ++i) {
            auto matrix = input.matrices[i];
            matrix.applyPerspective(input.parameters[i]);
            results[i] = matrix;
        }
        addAll(results, checksum);
    });
}

// Interpolation between pairs of matrices, as transform animations do. Every other pair has perspective, which
// decompose4() solves for with an inverse. In three pairs out of 64, the matrix decomposed is the identity, has an m44
// of 0, or is singular.
TEST(TransformationMatrixBench, Decompose4Blend4)
{
    unsigned pairs = passSize / 2;
    auto input = makeInput(8, passSize, [index = 0u](Random& random) mutable {
        unsigned pair = index / 2;
        bool isDecomposed = index++ % 2;
        auto matrix = invertibleMatrix(random, pair % 2);
        if (!isDecomposed)
            return matrix;
        switch (pair % 64) {
        case 61:
            return TransformationMatrix { };
        case 62:
            matrix.setM44(0);
            return matrix;
        case 63:
            return singularMatrix(matrix);
        default:
            return matrix;
        }
    }, 1, 0, 1);
    runBenchmark("Decompose4Blend4"_s, input, passSize * sizeof(TransformationMatrix), 3500, 0xabec91736d068d89ull, [pairs](auto& input, auto& results, auto* checksum) {
        results.resize(pairs);
        unsigned decomposed = 0;
        for (unsigned i = 0; i < pairs; ++i) {
            auto& from = input.matrices[2 * i];
            auto to = input.matrices[2 * i + 1];
            TransformationMatrix::Decomposed4Type decomposition { };
            decomposed += to.decompose4(decomposition);
            if (checksum)
                checksum->add(decomposition);
            to.blend4(from, input.parameters[2 * i]);
            results[i] = to;
        }
        if (checksum)
            checksum->add(static_cast<uint64_t>(decomposed));
        addAll(results, checksum);
    });
}

// What a script building a DOMMatrix does: multiply, invert, rotate, in runs of eight steps.
TEST(TransformationMatrixBench, DOMMatrixChain)
{
    auto input = makeInput(9, passSize, [](Random& random) {
        return invertibleMatrix(random, true);
    }, 3, -360, 360);
    runBenchmark("DOMMatrixChain"_s, input, passSize * sizeof(TransformationMatrix), 5200, 0x97f547a68db71271ull, [](auto& input, auto& results, auto* checksum) {
        results.resize(input.matrices.size());
        TransformationMatrix matrix;
        unsigned invertible = 0;
        for (size_t i = 0; i < input.matrices.size(); ++i) {
            if (!(i % 8))
                matrix = TransformationMatrix { };
            matrix.multiply(input.matrices[i]);
            if (auto inverse = matrix.inverse()) {
                matrix = *inverse;
                ++invertible;
            }
            matrix.rotate3d(input.parameters[3 * i], input.parameters[3 * i + 1], input.parameters[3 * i + 2]);
            results[i] = matrix;
        }
        if (checksum)
            checksum->add(static_cast<uint64_t>(invertible));
        addAll(results, checksum);
    });
}

} // namespace TestWebKitAPI
