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

import Foundation
import Metal
import WebGPU_Internal.BindableResource
import WebGPU_Internal.CxxBridging
import WebGPU_Internal.Device

/// The pipelines that clamp a draw or dispatch to what the buffers behind it can
/// actually supply, and the pipelines that encode an indirect draw into an ICB
/// slot on the GPU.
///
/// Every one of these is a vertex function with rasterization disabled: it reads
/// the app's arguments and writes a shadow copy with the counts reduced to
/// whatever is in bounds, which the real draw then uses. Nothing here draws
/// anything.
///
/// `Device` owns this and nothing else reaches it. Ownership runs one way: the
/// two `Device` facts these shaders need are passed to `init` rather than reached
/// back for -- `maxVerticesPerDrawCall`, which is interpolated into three of the
/// shaders, and the ICB container's buffer index, which `Device` spells as a
/// preprocessor macro so that its own shader text can paste it in.
///
/// A class rather than a value: `Device.h` can only name this as a forward
/// declaration -- the header that completes it is generated from Swift that
/// imports `Device.h` -- and an incomplete type can be held by pointer but not by
/// value. `DeviceErrorScopes` is held for the same reason.
@_expose(Cxx)
final class DeviceClampPipelines {
    /// The Metal device these pipelines are built on. A `Device` can be created
    /// invalid, with no Metal device, and then every one of these returns nothing.
    ///
    /// Held as an honest `Optional` rather than the implicitly-unwrapped handle a
    /// C++ `id<MTLDevice>` imports as, so that the absent case is one the compiler
    /// makes this file account for.
    private let device: (any MTLDevice)?

    /// The vertex count above which a draw is not clamped but treated as having
    /// lost the device. Interpolated into the indirect and indexed-indirect
    /// shaders, which compare the app's counts against it.
    private let maxVerticesPerDrawCall: UInt32

    /// The buffer index the ICB container is bound at. The shaders that take a
    /// container name this index in their `[[buffer(n)]]` attribute, so it arrives
    /// as a value and is interpolated into the shader source.
    private let icbContainerBufferIndex: Int32

    /// Which cached pipeline a request names. The three axes are what the pipeline
    /// does, which index width it reads, and whether the render pass it runs in is
    /// multisampled.
    private struct PipelineKey: Hashable {
        enum Kind {
            case indexBufferClamp
            case indexedIndirectBufferClamp
            case indirectBufferClamp
            case icbIndirectEncode
            case icbCommandClamp
        }

        /// `only` for the pipelines that read no index buffer, `draw` for the
        /// non-indexed ICB encode.
        enum Variant {
            case only
            case draw
            case uint16
            case uint32
        }

        let kind: Kind
        let variant: Variant
        let multisampled: Bool
    }

    private var renderPipelineStates: [PipelineKey: any MTLRenderPipelineState] = [:]

    /// The pipeline that runs the indirect-dispatch clamp. Keyed on nothing: the
    /// function it is built from is the caller's, and the first one wins.
    private var dispatchCallPipelineState: (any MTLComputePipelineState)?

    /// Declared rather than left implicit, so that the generated header carries it:
    /// Device.mm is the only caller, and constructs one per Device.
    init(device: (any MTLDevice)?, maxVerticesPerDrawCall: UInt32, icbContainerBufferIndex: Int32) {
        self.device = device
        self.maxVerticesPerDrawCall = maxVerticesPerDrawCall
        self.icbContainerBufferIndex = icbContainerBufferIndex
    }

    // MARK: - The pipelines

    /// The compute pipeline that clamps an indirect dispatch's threadgroup counts.
    ///
    /// The first caller's `function` is the one this is built from, and later
    /// callers get that pipeline whatever function they pass.
    func dispatchCallPipelineState(function: any MTLFunction) -> (any MTLComputePipelineState)? {
        guard let device else {
            return nil
        }
        if let dispatchCallPipelineState {
            return dispatchCallPipelineState
        }
        do {
            dispatchCallPipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            CxxBridging.logMetalFailure(error as NSError)
        }
        return dispatchCallPipelineState
    }

    /// Clamps each index a draw reads to the last index in the bound index buffer,
    /// and zeroes the draw when a clamped index would still be out of range of the
    /// vertex buffers.
    func indexBufferClampPipeline(indexType: MTLIndexType, rasterSampleCount: UInt) -> (any MTLRenderPipelineState)? {
        let isUint16 = indexType == .uint16
        return renderPipelineState(
            PipelineKey(kind: .indexBufferClamp, variant: isUint16 ? .uint16 : .uint32, multisampled: rasterSampleCount > 1),
            rasterSampleCount: rasterSampleCount,
            vertexFunction: indexBufferClampFunction(isUint16: isUint16))
    }

    /// Clamps an indexed indirect draw's arguments, writing both an indexed and a
    /// non-indexed shadow copy: the draw becomes non-indexed when the index buffer
    /// cannot supply the indices the arguments ask for.
    func indexedIndirectBufferClampPipeline(rasterSampleCount: UInt) -> (any MTLRenderPipelineState)? {
        renderPipelineState(
            PipelineKey(kind: .indexedIndirectBufferClamp, variant: .only, multisampled: rasterSampleCount > 1),
            rasterSampleCount: rasterSampleCount,
            vertexFunction: indexedIndirectBufferClampFunction())
    }

    /// Clamps a non-indexed indirect draw's vertex and instance counts to what the
    /// bound buffers hold.
    func indirectBufferClampPipeline(rasterSampleCount: UInt) -> (any MTLRenderPipelineState)? {
        renderPipelineState(
            PipelineKey(kind: .indirectBufferClamp, variant: .only, multisampled: rasterSampleCount > 1),
            rasterSampleCount: rasterSampleCount,
            vertexFunction: indirectBufferClampFunction())
    }

    /// Encodes an indirect draw into an ICB slot on the GPU, reading the draw
    /// counts from the args buffer -- clamped shadow args, or the app's raw buffer
    /// when no clamping is required -- at executeBundles() time.
    func icbIndirectEncodePipeline(isIndexed: Bool, indexType: MTLIndexType, rasterSampleCount: UInt) -> (any MTLRenderPipelineState)? {
        let variant: PipelineKey.Variant
        if !isIndexed {
            variant = .draw
        } else {
            variant = indexType == .uint16 ? .uint16 : .uint32
        }
        return renderPipelineState(
            PipelineKey(kind: .icbIndirectEncode, variant: variant, multisampled: rasterSampleCount > 1),
            rasterSampleCount: rasterSampleCount,
            vertexFunction: icbIndirectEncodeFunction(isIndexed: isIndexed, indexType: indexType))
    }

    /// Replaces an already-encoded ICB command with a zero-index draw when the
    /// indices it reads are out of range of the vertex buffers, and records the
    /// out-of-bounds read in the container.
    func icbCommandClampPipeline(indexType: MTLIndexType, rasterSampleCount: UInt) -> (any MTLRenderPipelineState)? {
        let isUint16 = indexType == .uint16
        return renderPipelineState(
            PipelineKey(kind: .icbCommandClamp, variant: isUint16 ? .uint16 : .uint32, multisampled: rasterSampleCount > 1),
            rasterSampleCount: rasterSampleCount,
            vertexFunction: icbCommandClampFunction(indexType: indexType))
    }

    /// The vertex function `icbCommandClampPipeline` is built from.
    /// RenderBundleEncoder builds its own pipeline from this one too.
    func icbCommandClampFunction(indexType: MTLIndexType) -> (any MTLFunction)? {
        guard let device else {
            return nil
        }
        let name = indexType == .uint16 ? "vsUshortICB" : "vsICB"
        let function = Self.icbCommandClampFunctions.function(named: name, on: device) {
            Self.icbCommandClampSource(
                icbContainerBufferIndex: self.icbContainerBufferIndex,
                indexDataSize: MemoryLayout<WebGPU.IndexData>.size)
        }
        // A failure to compile these leaves nothing that can clamp an already-encoded
        // ICB command.
        precondition(function != nil)
        return function
    }

    // MARK: - Building a pipeline from a function

    /// Returns the cached pipeline for `key`, building it from `vertexFunction` on
    /// the first request.
    ///
    /// Every pipeline here is the same descriptor: a vertex function, no fragment
    /// function, rasterization off, and points as the topology, because these run
    /// to write buffers rather than to produce pixels.
    private func renderPipelineState(_ key: PipelineKey, rasterSampleCount: UInt, vertexFunction: @autoclosure () -> (any MTLFunction)?) -> (any MTLRenderPipelineState)? {
        guard let device else {
            return nil
        }
        if let existing = renderPipelineStates[key] {
            return existing
        }
        guard let vertexFunction = vertexFunction() else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.isRasterizationEnabled = false
        descriptor.rasterSampleCount = Int(rasterSampleCount)
        descriptor.fragmentFunction = nil
        descriptor.inputPrimitiveTopology = .point

        do {
            let state = try device.makeRenderPipelineState(descriptor: descriptor)
            renderPipelineStates[key] = state
            return state
        } catch {
            CxxBridging.logMetalFailure(error as NSError)
            return nil
        }
    }

    // MARK: - The shader functions, compiled once for every Device

    /// The five shader sources, each compiled by the first `Device` that asks for
    /// one of its functions and shared by every `Device` after that.
    ///
    /// The pipelines above are per-`Device` because a pipeline state belongs to the
    /// device that built it. These functions are not.
    private static let indexBufferClampFunctions = SharedShaderFunctions()
    private static let indexedIndirectBufferClampFunctions = SharedShaderFunctions()
    private static let indirectBufferClampFunctions = SharedShaderFunctions()
    private static let icbIndirectEncodeFunctions = SharedShaderFunctions()
    private static let icbCommandClampFunctions = SharedShaderFunctions()

    private func indexBufferClampFunction(isUint16: Bool) -> (any MTLFunction)? {
        guard let device else {
            return nil
        }
        let name = isUint16 ? "vsUshortIndexClamp" : "vsUintIndexClamp"
        let function = Self.indexBufferClampFunctions.function(named: name, on: device) {
            Self.indexBufferClampSource()
        }
        // A failure to compile these leaves no way to keep a draw inside its index
        // buffer.
        precondition(function != nil)
        return function
    }

    private func indexedIndirectBufferClampFunction() -> (any MTLFunction)? {
        guard let device else {
            return nil
        }
        let function = Self.indexedIndirectBufferClampFunctions.function(named: "vsIndexedIndirect", on: device) {
            Self.indexedIndirectBufferClampSource(maxVerticesPerDrawCall: self.maxVerticesPerDrawCall)
        }
        precondition(function != nil)
        return function
    }

    private func indirectBufferClampFunction() -> (any MTLFunction)? {
        guard let device else {
            return nil
        }
        let function = Self.indirectBufferClampFunctions.function(named: "vsIndirect", on: device) {
            Self.indirectBufferClampSource(maxVerticesPerDrawCall: self.maxVerticesPerDrawCall)
        }
        precondition(function != nil)
        return function
    }

    private func icbIndirectEncodeFunction(isIndexed: Bool, indexType: MTLIndexType) -> (any MTLFunction)? {
        guard let device else {
            return nil
        }
        let name: String
        if !isIndexed {
            name = "vsICBIndirectDraw"
        } else {
            name = indexType == .uint16 ? "vsICBIndirectIndexedUshort" : "vsICBIndirectIndexedUint"
        }
        let function = Self.icbIndirectEncodeFunctions.function(named: name, on: device) {
            Self.icbIndirectEncodeSource(icbContainerBufferIndex: self.icbContainerBufferIndex)
        }
        precondition(function != nil)
        return function
    }
}

/// One Metal library's functions, compiled on first use and shared from then on.
///
/// SAFETY: every access to the compiled functions happens under `lock`, which is
/// the whole of this type's mutable state, so no two threads can be inside the
/// compile or the lookup at once.
///
/// What the lock does not make safe is the use of a returned `MTLFunction` on
/// several threads at once. That is Metal's guarantee, not this one's.
private final class SharedShaderFunctions: @unchecked Sendable {
    private let lock = NSLock()
    private var functions: [String: any MTLFunction]?

    /// The function named `name`, compiling `source` on `device` if this is the
    /// first request.
    ///
    /// The first device to ask is the one the library is built on, and every later
    /// caller gets that library's functions whatever device it passes. A
    /// compilation that fails is not retried, because the failure is a property of
    /// the source.
    func function(named name: String, on device: any MTLDevice, source: () -> String) -> (any MTLFunction)? {
        lock.lock()
        defer { lock.unlock() }
        if functions == nil {
            functions = Self.compile(source(), on: device)
        }
        return functions?[name]
    }

    private static func compile(_ source: String, on device: any MTLDevice) -> [String: any MTLFunction] {
        let options = MTLCompileOptions()
        options.mathMode = .fast

        let library: any MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: options)
        } catch {
            CxxBridging.logMetalFailure(error as NSError)
            return [:]
        }

        var functions: [String: any MTLFunction] = [:]
        for name in library.functionNames {
            if let function = library.makeFunction(name: name) {
                functions[name] = function
            }
        }
        return functions
    }
}

// MARK: - The shader sources

extension DeviceClampPipelines {
    /// The layouts the clamping shaders write their shadow arguments into. Both are
    /// declared by a macro in Device.h so that the C++ struct the CPU reads and the
    /// MSL struct the GPU writes are one source; Swift cannot expand a preprocessor
    /// macro, so the expansion is handed over as text.
    private static var drawIndirectArguments: String {
        WebGPU.drawIndirectArgumentsShaderText()
    }

    private static var drawIndexedIndirectArguments: String {
        WebGPU.drawIndexedIndirectArgumentsShaderText()
    }

    private static func indexBufferClampSource() -> String {
        """
        #define vertexCount 0
        #define primitiveRestart 1
        #define indexCountMinusOne 2
            using namespace metal;
            \(drawIndexedIndirectArguments)
            [[vertex]] void vsUshortIndexClamp(device const ushort* indexBuffer [[buffer(0)]], device WebKitMTLDrawIndexedPrimitivesIndirectArguments& wkindexedOutput [[buffer(1)]], const constant uint* data [[buffer(2)]], uint indexId [[vertex_id]])
            {
                device MTLDrawIndexedPrimitivesIndirectArguments& indexedOutput = wkindexedOutput.args;
                ushort indexBufferValue = indexBuffer[min(indexId, data[indexCountMinusOne])];
                uint vertexIndex = uint((ushort)(data[primitiveRestart]) + indexBufferValue);
                if (addsat(vertexIndex, indexedOutput.baseVertex) >= data[vertexCount] + data[primitiveRestart]) {
                    indexedOutput.indexCount = 0u;
                    indexedOutput.instanceCount = 0u;
                    indexedOutput.indexStart = 0u;
                    indexedOutput.baseVertex = 0u;
                    indexedOutput.baseInstance = 0u;
                    wkindexedOutput.lostOrOOBRead = 1;
                }
            }
            [[vertex]] void vsUintIndexClamp(device const uint* indexBuffer [[buffer(0)]], device WebKitMTLDrawIndexedPrimitivesIndirectArguments& wkindexedOutput [[buffer(1)]], const constant uint* data [[buffer(2)]], uint indexId [[vertex_id]])
            {
                device MTLDrawIndexedPrimitivesIndirectArguments& indexedOutput = wkindexedOutput.args;
                uint indexBufferValue = indexBuffer[min(indexId, data[indexCountMinusOne])];
                uint vertexIndex = data[primitiveRestart] + indexBufferValue;
                if (addsat(vertexIndex, indexedOutput.baseVertex) >= data[vertexCount] + data[primitiveRestart]) {
                    indexedOutput.indexCount = 0u;
                    indexedOutput.instanceCount = 0u;
                    indexedOutput.indexStart = 0u;
                    indexedOutput.baseVertex = 0u;
                    indexedOutput.baseInstance = 0u;
                    wkindexedOutput.lostOrOOBRead = 1;
                }
            }
        """
    }

    private static func indexedIndirectBufferClampSource(maxVerticesPerDrawCall: UInt32) -> String {
        """
            using namespace metal;
            \(drawIndirectArguments)
            \(drawIndexedIndirectArguments)
            [[vertex]] void vsIndexedIndirect(device const MTLDrawIndexedPrimitivesIndirectArguments& input [[buffer(0)]], device WebKitMTLDrawIndexedPrimitivesIndirectArguments& wkindexedOutput [[buffer(1)]], device WebKitMTLDrawPrimitivesIndirectArguments& wkoutput [[buffer(2)]], const constant uint* indexBufferCount [[buffer(3)]])
            {
                device MTLDrawPrimitivesIndirectArguments& output = wkoutput.args;
                device MTLDrawIndexedPrimitivesIndirectArguments& indexedOutput = wkindexedOutput.args;
                bool lostCondition = input.indexCount > \(maxVerticesPerDrawCall) || input.instanceCount > \(maxVerticesPerDrawCall) || madsat(input.indexCount, input.instanceCount, 0u) > \(maxVerticesPerDrawCall);
                bool condition = lostCondition
                    || addsat(input.indexCount, input.indexStart) > indexBufferCount[0]
                    || input.indexStart >= indexBufferCount[0]
                    || addsat(input.instanceCount, input.baseInstance) > indexBufferCount[1]
                    || input.baseInstance >= indexBufferCount[1];

                indexedOutput.indexCount = metal::select(input.indexCount, 0u, condition);
                indexedOutput.instanceCount = input.instanceCount;
                indexedOutput.indexStart = metal::select(input.indexStart, 0u, condition);
                indexedOutput.baseVertex = input.baseVertex;
                indexedOutput.baseInstance = input.baseInstance;

                output.vertexCount = metal::select(input.indexCount, 0u, condition);
                output.instanceCount = 1;
                output.vertexStart = input.indexStart;
                output.baseInstance = 0;
                if (lostCondition)
                    wkoutput.lostOrOOBRead = 1;
            }
        """
    }

    private static func indirectBufferClampSource(maxVerticesPerDrawCall: UInt32) -> String {
        """
            using namespace metal;
            \(drawIndirectArguments)
            [[vertex]] void vsIndirect(device const MTLDrawPrimitivesIndirectArguments& input [[buffer(0)]], device WebKitMTLDrawPrimitivesIndirectArguments& wkoutput [[buffer(1)]], const constant uint* minCounts [[buffer(2)]])
            {
                device MTLDrawPrimitivesIndirectArguments& output = wkoutput.args;
                bool lostCondition = input.vertexCount > \(maxVerticesPerDrawCall) || input.instanceCount > \(maxVerticesPerDrawCall) || madsat(input.vertexCount, input.instanceCount, 0u) > \(maxVerticesPerDrawCall);
                bool vertexCondition = lostCondition
                    || addsat(input.vertexCount, input.vertexStart) > minCounts[0]
                    || input.vertexStart >= minCounts[0];
                bool instanceCondition = addsat(input.baseInstance, input.instanceCount) > minCounts[1] || input.baseInstance >= minCounts[1];
                auto minVertexCountMinusVertexStart = minCounts[0] > input.vertexStart ? (minCounts[0] - input.vertexStart) : 0u;
                output.vertexCount = metal::select(input.vertexCount, minVertexCountMinusVertexStart, vertexCondition);
                auto minInstanceCountMinusInstanceStart = minCounts[1] > input.baseInstance ? (minCounts[1] - input.baseInstance) : 0u;
                output.instanceCount = metal::select(input.instanceCount, minInstanceCountMinusInstanceStart, instanceCondition);
                output.vertexStart = input.vertexStart;
                output.baseInstance = input.baseInstance;
                if (lostCondition)
                    wkoutput.lostOrOOBRead = 1;
            }
        """
    }

    private static func icbIndirectEncodeSource(icbContainerBufferIndex: Int32) -> String {
        """
            using namespace metal;
            struct ICBContainer {
                device uint* outOfBoundsRead [[ id(0) ]];
                command_buffer commandBuffer [[ id(1) ]];
            };

            static_assert(sizeof(primitive_type) == sizeof(uint32_t), "API assumes primitive type is sizeof uint32_t");

            // slotData[0] = ICB slot index, slotData[1] = primitive_type.
            [[vertex]] void vsICBIndirectDraw(device const MTLDrawPrimitivesIndirectArguments& args [[buffer(0)]],
                device ICBContainer *icb_container [[buffer(\(icbContainerBufferIndex))]],
                const constant uint* slotData [[buffer(2)]])
            {
                render_command cmd(icb_container->commandBuffer, slotData[0]);
                cmd.draw_primitives(static_cast<primitive_type>(slotData[1]),
                    args.vertexStart,
                    args.vertexCount,
                    args.instanceCount,
                    args.baseInstance);
            }

            // slotData[2] = index buffer element offset.
            [[vertex]] void vsICBIndirectIndexedUint(device const MTLDrawIndexedPrimitivesIndirectArguments& args [[buffer(0)]],
                device ICBContainer *icb_container [[buffer(\(icbContainerBufferIndex))]],
                device uint* indexBuffer [[buffer(2)]],
                const constant uint* slotData [[buffer(3)]])
            {
                render_command cmd(icb_container->commandBuffer, slotData[0]);
                device uint* indexBufferBase = indexBuffer + slotData[2] + args.indexStart;
                cmd.draw_indexed_primitives(static_cast<primitive_type>(slotData[1]),
                    args.indexCount,
                    indexBufferBase,
                    args.instanceCount,
                    args.baseVertex,
                    args.baseInstance);
            }

            [[vertex]] void vsICBIndirectIndexedUshort(device const MTLDrawIndexedPrimitivesIndirectArguments& args [[buffer(0)]],
                device ICBContainer *icb_container [[buffer(\(icbContainerBufferIndex))]],
                device ushort* indexBuffer [[buffer(2)]],
                const constant uint* slotData [[buffer(3)]])
            {
                render_command cmd(icb_container->commandBuffer, slotData[0]);
                device ushort* indexBufferBase = indexBuffer + slotData[2] + args.indexStart;
                cmd.draw_indexed_primitives(static_cast<primitive_type>(slotData[1]),
                    args.indexCount,
                    indexBufferBase,
                    args.instanceCount,
                    args.baseVertex,
                    args.baseInstance);
            }
        """
    }

    private static func icbCommandClampSource(icbContainerBufferIndex: Int32, indexDataSize: Int) -> String {
        """
            using namespace metal;
            struct ICBContainer {
                device uint* outOfBoundsRead [[ id(0) ]];
                command_buffer commandBuffer [[ id(1) ]];
            };
            struct IndexDataUshort {
                uint64_t renderCommand { 0 };
                uint32_t minVertexCount { UINT_MAX };
                uint32_t minInstanceCount { UINT_MAX };
                device ushort* indexBuffer;
                uint32_t indexBufferElementCountMinusOne;
                uint32_t indexCount { 0 };
                uint32_t instanceCount { 0 };
                uint32_t firstIndex { 0 };
                uint32_t baseVertex { 0 };
                uint32_t baseInstance { 0 };
                primitive_type primitiveType { primitive_type::triangle };
            };
            struct IndexDataUint {
                uint64_t renderCommand { 0 };
                uint32_t minVertexCount { UINT_MAX };
                uint32_t minInstanceCount { UINT_MAX };
                device uint* indexBuffer;
                uint32_t indexBufferElementCountMinusOne;
                uint32_t indexCount { 0 };
                uint32_t instanceCount { 0 };
                uint32_t firstIndex { 0 };
                uint32_t baseVertex { 0 };
                uint32_t baseInstance { 0 };
                primitive_type primitiveType { primitive_type::triangle };
            };

            static_assert(sizeof(primitive_type) == sizeof(uint32_t), "API assumes primitive type is sizeof uint32_t");
            static_assert(sizeof(IndexDataUshort) == \(indexDataSize), "sizeof(IndexDataUshort) in shader mismatches the API size");
            static_assert(sizeof(IndexDataUint) == \(indexDataSize), "sizeof(IndexDataUint) in shader mismatches the API size");

            [[vertex]] void vsICB(device const IndexDataUint* indexData [[buffer(0)]],
                device ICBContainer *icb_container [[buffer(\(icbContainerBufferIndex))]],
                uint indexId [[vertex_id]])
            {
                device const IndexDataUint& data = *indexData;
                uint32_t k = (data.primitiveType == primitive_type::triangle_strip || data.primitiveType == primitive_type::line_strip) ? 1 : 0;
                uint32_t indexBufferValue = data.indexBuffer[min(data.indexBufferElementCountMinusOne, indexId + data.firstIndex)];
                uint32_t vertexIndex = indexBufferValue + k;
                if (addsat(vertexIndex, data.baseVertex) >= data.minVertexCount + k) {
                    *icb_container->outOfBoundsRead = 1;
                    render_command cmd(icb_container->commandBuffer, data.renderCommand);
                    cmd.draw_indexed_primitives(data.primitiveType,
                        0u,
                        data.indexBuffer,
                        data.instanceCount,
                        data.baseVertex,
                        data.baseInstance);
                }
            }

            [[vertex]] void vsUshortICB(device const IndexDataUshort* indexData [[buffer(0)]],
                device ICBContainer *icb_container [[buffer(\(icbContainerBufferIndex))]],
                uint indexId [[vertex_id]])
            {
                device const IndexDataUshort& data = *indexData;
                uint32_t k = (data.primitiveType == primitive_type::triangle_strip || data.primitiveType == primitive_type::line_strip) ? 1 : 0;
                ushort indexBufferValue = data.indexBuffer[min(data.indexBufferElementCountMinusOne, indexId + data.firstIndex)];
                uint32_t vertexIndex = uint(indexBufferValue) + k;
                if (addsat(vertexIndex, data.baseVertex) >= data.minVertexCount + k) {
                    *icb_container->outOfBoundsRead = 1;
                    render_command cmd(icb_container->commandBuffer, data.renderCommand);
                    cmd.draw_indexed_primitives(data.primitiveType,
                        0u,
                        data.indexBuffer,
                        data.instanceCount,
                        data.baseVertex,
                        data.baseInstance);
                }

            }
        """
    }
}
