// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

#if USE_SWIFT_TRANSFORMATION_MATRIX

internal import WebCore_Private.Core.TransformationMatrix
// Operators that WebCore's headers declare use these JavaScriptCore and WTF types. Without their definitions, * and +
// do not typecheck in this file.
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
internal import wtf.Core.Stopwatch
#if arch(arm64)
internal import func simd.fma
#endif

private typealias Matrix4 = WebCore.TransformationMatrix.Matrix4

// sum + a * b, rounded once on ARM64 and twice elsewhere, matching TransformationMatrix.cpp on each CPU.
@inline(always)
private func multiplyAdd(_ sum: SIMD2<Double>, _ a: SIMD2<Double>, _ b: Double) -> SIMD2<Double> {
    #if arch(arm64)
    fusedMultiplyAdd(sum, a, b)
    #else
    sum + a * b
    #endif
}

// The rows of the right-hand matrix of a product, each split into two vectors.
private struct MatrixRows {
    typealias Row = (low: SIMD2<Double>, high: SIMD2<Double>)

    let row1Low: SIMD2<Double>, row1High: SIMD2<Double>, row2Low: SIMD2<Double>, row2High: SIMD2<Double>
    let row3Low: SIMD2<Double>, row3High: SIMD2<Double>, row4Low: SIMD2<Double>, row4High: SIMD2<Double>

    // The row (a, b, c, d) times this matrix.
    @inline(always)
    func product(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Row {
        let low = multiplyAdd(multiplyAdd(multiplyAdd(row1Low * a, row2Low, b), row3Low, c), row4Low, d)
        let high = multiplyAdd(multiplyAdd(multiplyAdd(row1High * a, row2High, b), row3High, c), row4High, d)
        return (low, high)
    }
}

@inline(always)
private func store(
    _ result1: MatrixRows.Row,
    _ result2: MatrixRows.Row,
    _ result3: MatrixRows.Row,
    _ result4: MatrixRows.Row,
    to matrix: inout WebCore.TransformationMatrix
) {
    matrix.setM11(result1.low.x)
    matrix.setM12(result1.low.y)
    matrix.setM13(result1.high.x)
    matrix.setM14(result1.high.y)
    matrix.setM21(result2.low.x)
    matrix.setM22(result2.low.y)
    matrix.setM23(result2.high.x)
    matrix.setM24(result2.high.y)
    matrix.setM31(result3.low.x)
    matrix.setM32(result3.low.y)
    matrix.setM33(result3.high.x)
    matrix.setM34(result3.high.y)
    matrix.setM41(result4.low.x)
    matrix.setM42(result4.low.y)
    matrix.setM43(result4.high.x)
    matrix.setM44(result4.high.y)
}

// matrix = other * matrix. All of other is read before matrix is written, since C++ callers may pass the same matrix
// for both. Out of line so that callers pass other by reference: with its elements in registers, the compiler merges a
// caller's sin() and cos() into one sincos call, whose results can differ in the last bit.
@_expose(Cxx)
@inline(never)
func transformationMatrixMultiply(_ matrix: inout WebCore.TransformationMatrix, _ other: WebCore.TransformationMatrix) {
    multiplyRows(
        SIMD2(other.m11(), other.m12()),
        SIMD2(other.m13(), other.m14()),
        SIMD2(other.m21(), other.m22()),
        SIMD2(other.m23(), other.m24()),
        SIMD2(other.m31(), other.m32()),
        SIMD2(other.m33(), other.m34()),
        SIMD2(other.m41(), other.m42()),
        SIMD2(other.m43(), other.m44()),
        into: &matrix
    )
}

// matrix = other * matrix, with the rows of `other` passed as values. Out of line on ARM64, where the eight vectors
// arrive in v0-v7. Inlined elsewhere: the Windows x64 convention passes each 16-byte vector by reference, so a call
// costs eight stores to the stack, eight pointers and eight loads per product.
#if arch(arm64)
@inline(never)
#else
@inline(always)
#endif
private func multiplyRows(
    _ other1Low: SIMD2<Double>,
    _ other1High: SIMD2<Double>,
    _ other2Low: SIMD2<Double>,
    _ other2High: SIMD2<Double>,
    _ other3Low: SIMD2<Double>,
    _ other3High: SIMD2<Double>,
    _ other4Low: SIMD2<Double>,
    _ other4High: SIMD2<Double>,
    into matrix: inout WebCore.TransformationMatrix
) {
    let rows = MatrixRows(
        row1Low: SIMD2(matrix.m11(), matrix.m12()),
        row1High: SIMD2(matrix.m13(), matrix.m14()),
        row2Low: SIMD2(matrix.m21(), matrix.m22()),
        row2High: SIMD2(matrix.m23(), matrix.m24()),
        row3Low: SIMD2(matrix.m31(), matrix.m32()),
        row3High: SIMD2(matrix.m33(), matrix.m34()),
        row4Low: SIMD2(matrix.m41(), matrix.m42()),
        row4High: SIMD2(matrix.m43(), matrix.m44())
    )
    store(
        rows.product(other1Low.x, other1Low.y, other1High.x, other1High.y),
        rows.product(other2Low.x, other2Low.y, other2High.x, other2High.y),
        rows.product(other3Low.x, other3Low.y, other3High.x, other3High.y),
        rows.product(other4Low.x, other4Low.y, other4High.x, other4High.y),
        to: &matrix
    )
}

#if arch(arm64)

// sum + a * b and sum - a * b, each a single fused vector operation.
@inline(always)
private func fusedMultiplyAdd(_ sum: SIMD2<Double>, _ a: SIMD2<Double>, _ b: Double) -> SIMD2<Double> {
    simd.fma(a, SIMD2(repeating: b), sum)
}

@inline(always)
private func fusedMultiplySubtract(_ sum: SIMD2<Double>, _ a: SIMD2<Double>, _ b: Double) -> SIMD2<Double> {
    simd.fma(a, SIMD2(repeating: -b), sum)
}

// Two rows of the inverse, from the 2x2 minors of the column pair d and the other column pair l. Each vector holds two
// adjacent elements of a row. Signs are applied with the scale, as the ARM64 assembly in TransformationMatrix.cpp does.
@inline(always)
private func scaledAdjointRows(
    _ d1: SIMD2<Double>,
    _ d2: SIMD2<Double>,
    _ d3: SIMD2<Double>,
    _ d4: SIMD2<Double>,
    _ l1: SIMD2<Double>,
    _ l2: SIMD2<Double>,
    _ l3: SIMD2<Double>,
    _ l4: SIMD2<Double>,
    _ scale: Double
)
    -> (SIMD2<Double>, SIMD2<Double>, SIMD2<Double>, SIMD2<Double>)
{
    let d21x = SIMD2(d2.x, d1.x)
    let d21y = SIMD2(d2.y, d1.y)
    let l21x = SIMD2(l2.x, l1.x)
    let l21y = SIMD2(l2.y, l1.y)
    let l43x = SIMD2(l4.x, l3.x)
    let l43y = SIMD2(l4.y, l3.y)
    let minor12 = (d1.x * d2.y).addingProduct(-d1.y, d2.x)
    let minor34 = (d3.x * d4.y).addingProduct(-d3.y, d4.x)
    let minors24And14 = fusedMultiplySubtract(d21x * d4.y, d21y, d4.x)
    let minors23And13 = fusedMultiplySubtract(d21x * d3.y, d21y, d3.x)
    let minors24And23 = SIMD2(minors24And14.x, minors23And13.x)
    let minors14And13 = SIMD2(minors24And14.y, minors23And13.y)

    let cofactorsY = fusedMultiplyAdd(fusedMultiplySubtract(l21y * minor34, minors24And14, l3.y), minors23And13, l4.y)
    let cofactorsYHigh = fusedMultiplyAdd(fusedMultiplySubtract(minors24And23 * l1.y, minors14And13, l2.y), l43y, minor12)
    let cofactorsX = fusedMultiplyAdd(fusedMultiplySubtract(l21x * minor34, minors24And14, l3.x), minors23And13, l4.x)
    let cofactorsXHigh = fusedMultiplyAdd(fusedMultiplySubtract(minors24And23 * l1.x, minors14And13, l2.x), l43x, minor12)

    let negatedSecond = SIMD2(scale, -scale)
    let negatedFirst = SIMD2(-scale, scale)
    return (
        cofactorsY * negatedSecond, cofactorsYHigh * negatedSecond, cofactorsX * negatedFirst,
        cofactorsXHigh * negatedFirst
    )
}

// result = adjoint(matrix) * inverseDeterminant.
@_expose(Cxx)
func transformationMatrixScaledAdjoint(
    _ matrix: WebCore.TransformationMatrix.Matrix4,
    _ inverseDeterminant: Double,
    _ result: inout WebCore.TransformationMatrix.Matrix4
) {
    let row1 = matrix[0]
    let row2 = matrix[1]
    let row3 = matrix[2]
    let row4 = matrix[3]
    let low1 = SIMD2(row1[0], row1[1])
    let high1 = SIMD2(row1[2], row1[3])
    let low2 = SIMD2(row2[0], row2[1])
    let high2 = SIMD2(row2[2], row2[3])
    let low3 = SIMD2(row3[0], row3[1])
    let high3 = SIMD2(row3[2], row3[3])
    let low4 = SIMD2(row4[0], row4[1])
    let high4 = SIMD2(row4[2], row4[3])

    let top = scaledAdjointRows(high1, high2, high3, high4, low1, low2, low3, low4, inverseDeterminant)
    let bottom = scaledAdjointRows(low1, low2, low3, low4, high1, high2, high3, high4, inverseDeterminant)
    store(top.0, top.1, to: &result, row: 0)
    store(top.2, top.3, to: &result, row: 1)
    store(bottom.0, bottom.1, to: &result, row: 2)
    store(bottom.2, bottom.3, to: &result, row: 3)
}

#else

@inline(always)
private func determinant2x2(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
    a * d - b * c
}

@inline(always)
private func determinant3x3(
    _ a1: Double,
    _ a2: Double,
    _ a3: Double,
    _ b1: Double,
    _ b2: Double,
    _ b3: Double,
    _ c1: Double,
    _ c2: Double,
    _ c3: Double
) -> Double {
    a1 * determinant2x2(b2, b3, c2, c3) - b1 * determinant2x2(a2, a3, c2, c3) + c1 * determinant2x2(a2, a3, b2, b3)
}

// result = adjoint(matrix) * inverseDeterminant. Adapted from Matrix Inversion by Richard Carling, Graphics Gems.
@_expose(Cxx)
func transformationMatrixScaledAdjoint(
    _ matrix: WebCore.TransformationMatrix.Matrix4,
    _ inverseDeterminant: Double,
    _ result: inout WebCore.TransformationMatrix.Matrix4
) {
    let a1 = matrix[0][0]
    let b1 = matrix[0][1]
    let c1 = matrix[0][2]
    let d1 = matrix[0][3]
    let a2 = matrix[1][0]
    let b2 = matrix[1][1]
    let c2 = matrix[1][2]
    let d2 = matrix[1][3]
    let a3 = matrix[2][0]
    let b3 = matrix[2][1]
    let c3 = matrix[2][2]
    let d3 = matrix[2][3]
    let a4 = matrix[3][0]
    let b4 = matrix[3][1]
    let c4 = matrix[3][2]
    let d4 = matrix[3][3]
    let s = inverseDeterminant

    result[0][0] = determinant3x3(b2, b3, b4, c2, c3, c4, d2, d3, d4) * s
    result[1][0] = -determinant3x3(a2, a3, a4, c2, c3, c4, d2, d3, d4) * s
    result[2][0] = determinant3x3(a2, a3, a4, b2, b3, b4, d2, d3, d4) * s
    result[3][0] = -determinant3x3(a2, a3, a4, b2, b3, b4, c2, c3, c4) * s

    result[0][1] = -determinant3x3(b1, b3, b4, c1, c3, c4, d1, d3, d4) * s
    result[1][1] = determinant3x3(a1, a3, a4, c1, c3, c4, d1, d3, d4) * s
    result[2][1] = -determinant3x3(a1, a3, a4, b1, b3, b4, d1, d3, d4) * s
    result[3][1] = determinant3x3(a1, a3, a4, b1, b3, b4, c1, c3, c4) * s

    result[0][2] = determinant3x3(b1, b2, b4, c1, c2, c4, d1, d2, d4) * s
    result[1][2] = -determinant3x3(a1, a2, a4, c1, c2, c4, d1, d2, d4) * s
    result[2][2] = determinant3x3(a1, a2, a4, b1, b2, b4, d1, d2, d4) * s
    result[3][2] = -determinant3x3(a1, a2, a4, b1, b2, b4, c1, c2, c4) * s

    result[0][3] = -determinant3x3(b1, b2, b3, c1, c2, c3, d1, d2, d3) * s
    result[1][3] = determinant3x3(a1, a2, a3, c1, c2, c3, d1, d2, d3) * s
    result[2][3] = -determinant3x3(a1, a2, a3, b1, b2, b3, d1, d2, d3) * s
    result[3][3] = determinant3x3(a1, a2, a3, b1, b2, b3, c1, c2, c3) * s
}

#endif

@inline(always)
private func store(_ low: SIMD2<Double>, _ high: SIMD2<Double>, to result: inout Matrix4, row: Int) {
    result[row][0] = low.x
    result[row][1] = low.y
    result[row][2] = high.x
    result[row][3] = high.y
}

// The scalar form of the vector multiplyAdd() above.
@inline(always)
private func multiplyAdd(_ sum: Double, _ a: Double, _ b: Double) -> Double {
    #if arch(arm64)
    sum.addingProduct(a, b)
    #else
    sum + a * b
    #endif
}

private struct Vector3 {
    let x: Double, y: Double, z: Double

    var length: Double {
        WebCore.transformationMatrixHypot(x, y, z)
    }

    // The vector divided by its length, unless that is 0.
    func normalized(length: Double) -> Vector3 {
        guard length != 0 else { return self }
        let scale = 1.0 / length
        return Vector3(x: x * scale, y: y * scale, z: z * scale)
    }

    func dot(_ other: Vector3) -> Double {
        multiplyAdd(multiplyAdd(y * other.y, x, other.x), z, other.z)
    }

    func cross(_ other: Vector3) -> Vector3 {
        Vector3(
            x: multiplyAdd(-(z * other.y), y, other.z),
            y: multiplyAdd(-(x * other.z), z, other.x),
            z: multiplyAdd(-(y * other.x), x, other.y)
        )
    }

    func subtracting(_ other: Vector3, scaledBy scale: Double) -> Vector3 {
        Vector3(x: x - scale * other.x, y: y - scale * other.y, z: z - scale * other.z)
    }

    static prefix func - (vector: Vector3) -> Vector3 {
        Vector3(x: -vector.x, y: -vector.y, z: -vector.z)
    }
}

// TransformationMatrix::decompose4(), from Graphics Gems: unmatrix.c. Returns false, leaving `result` unchanged, if the
// matrix is singular.
@_expose(Cxx)
func transformationMatrixDecompose4(
    _ matrix: WebCore.TransformationMatrix,
    _ result: inout WebCore.TransformationMatrix.Decomposed4Type
) -> Bool {
    if matrix.isIdentity() {
        result.scaleX = 1
        result.scaleY = 1
        result.scaleZ = 1
        result.skewXY = 0
        result.skewXZ = 0
        result.skewYZ = 0
        result.quaternion.x = 0
        result.quaternion.y = 0
        result.quaternion.z = 0
        result.quaternion.w = 1
        result.translateX = 0
        result.translateY = 0
        result.translateZ = 0
        result.perspectiveX = 0
        result.perspectiveY = 0
        result.perspectiveZ = 0
        result.perspectiveW = 1
        return true
    }

    // Normalize the matrix by m44.
    let m44 = matrix.m44()
    if m44 == 0 {
        return false
    }
    let m11 = matrix.m11() / m44
    let m12 = matrix.m12() / m44
    let m13 = matrix.m13() / m44
    let m14 = matrix.m14() / m44
    let m21 = matrix.m21() / m44
    let m22 = matrix.m22() / m44
    let m23 = matrix.m23() / m44
    let m24 = matrix.m24() / m44
    let m31 = matrix.m31() / m44
    let m32 = matrix.m32() / m44
    let m33 = matrix.m33() / m44
    let m34 = matrix.m34() / m44
    let m41 = matrix.m41() / m44
    let m42 = matrix.m42() / m44
    let m43 = matrix.m43() / m44

    // The normalized matrix with its perspective partition cleared. It is used to solve for perspective, and it tests
    // the upper 3x3 for singularity.
    var perspectiveMatrix = Matrix4()
    store(SIMD2(m11, m12), SIMD2(m13, 0), to: &perspectiveMatrix, row: 0)
    store(SIMD2(m21, m22), SIMD2(m23, 0), to: &perspectiveMatrix, row: 1)
    store(SIMD2(m31, m32), SIMD2(m33, 0), to: &perspectiveMatrix, row: 2)
    store(SIMD2(m41, m42), SIMD2(m43, 1), to: &perspectiveMatrix, row: 3)
    let determinant = WebCore.transformationMatrixDeterminant4x4(perspectiveMatrix)
    if !determinant.isNormal {
        return false
    }

    // Solve for perspective: the inverse of perspectiveMatrix times the perspective partition.
    let perspective: (x: Double, y: Double, z: Double, w: Double)
    if m14 != 0 || m24 != 0 || m34 != 0 {
        let p1 = m14
        let p2 = m24
        let p3 = m34
        // 1, unless m44 is infinite or NaN, as the C++ normalization gives.
        let p4 = m44 / m44
        var inverse = Matrix4()
        transformationMatrixScaledAdjoint(perspectiveMatrix, 1 / determinant, &inverse)
        func product(_ row: Int) -> Double {
            multiplyAdd(
                multiplyAdd(multiplyAdd(p2 * inverse[row][1], p1, inverse[row][0]), p3, inverse[row][2]),
                p4,
                inverse[row][3]
            )
        }
        perspective = (product(0), product(1), product(2), product(3))
    } else {
        perspective = (0, 0, 0, 1)
    }

    // Scale and shear, from the columns of the upper 3x3 (the specification's pseudocode calls them rows).
    var column1 = Vector3(x: m11, y: m12, z: m13)
    var column2 = Vector3(x: m21, y: m22, z: m23)
    var column3 = Vector3(x: m31, y: m32, z: m33)

    // X scale, and the first column normalized.
    var scaleX = column1.length
    column1 = column1.normalized(length: scaleX)

    // XY shear, making the second column orthogonal to the first; then Y scale.
    var skewXY = column1.dot(column2)
    column2 = column2.subtracting(column1, scaledBy: skewXY)
    var scaleY = column2.length
    column2 = column2.normalized(length: scaleY)
    skewXY /= scaleY

    // XZ and YZ shears, making the third column orthogonal to the others; then Z scale.
    var skewXZ = column1.dot(column3)
    column3 = column3.subtracting(column1, scaledBy: skewXZ)
    var skewYZ = column2.dot(column3)
    column3 = column3.subtracting(column2, scaledBy: skewYZ)
    var scaleZ = column3.length
    column3 = column3.normalized(length: scaleZ)
    skewXZ /= scaleZ
    skewYZ /= scaleZ

    // The columns are now orthonormal. If their determinant is -1, the coordinate system is flipped: negate them and
    // the scales.
    if column1.dot(column2.cross(column3)) < 0 {
        scaleX = -scaleX
        scaleY = -scaleY
        scaleZ = -scaleZ
        column1 = -column1
        column2 = -column2
        column3 = -column3
    }

    // The rotation as a quaternion: from the trace when 1 + trace is not close to 0, otherwise from the largest diagonal
    // element. See https://en.wikipedia.org/wiki/Rotation_matrix#Quaternion.
    let q11 = column1.x
    let q22 = column2.y
    let q33 = column3.z
    let x: Double
    let y: Double
    let z: Double
    let w: Double
    let trace = q11 + q22 + q33
    if 1 + trace > 0.001 {
        let r = (1.0 + trace).squareRoot()
        let s = 0.5 / r
        w = 0.5 * r
        x = (column2.z - column3.y) * s
        y = (column3.x - column1.z) * s
        z = (column1.y - column2.x) * s
    } else if q11 > q22 && q11 > q33 {
        let r = (1.0 + q11 - q22 - q33).squareRoot()
        let s = 0.5 / r
        x = 0.5 * r
        y = (column2.x + column1.y) * s
        z = (column3.x + column1.z) * s
        w = (column2.z - column3.y) * s
    } else if q22 > q33 {
        let r = (1.0 - q11 + q22 - q33).squareRoot()
        let s = 0.5 / r
        x = (column2.x + column1.y) * s
        y = 0.5 * r
        z = (column3.y + column2.z) * s
        w = (column3.x - column1.z) * s
    } else {
        let r = (1.0 - q11 - q22 + q33).squareRoot()
        let s = 0.5 / r
        x = (column3.x + column1.z) * s
        y = (column3.y + column2.z) * s
        z = 0.5 * r
        w = (column1.y - column2.x) * s
    }

    result.scaleX = scaleX
    result.scaleY = scaleY
    result.scaleZ = scaleZ
    result.skewXY = skewXY
    result.skewXZ = skewXZ
    result.skewYZ = skewYZ
    result.quaternion.x = x
    result.quaternion.y = y
    result.quaternion.z = z
    result.quaternion.w = w
    result.translateX = m41
    result.translateY = m42
    result.translateZ = m43
    result.perspectiveX = perspective.x
    result.perspectiveY = perspective.y
    result.perspectiveZ = perspective.z
    result.perspectiveW = perspective.w
    return true
}

#endif // USE_SWIFT_TRANSFORMATION_MATRIX
