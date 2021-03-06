//
//  CameraImageRenderer.swift
//  LiDARBasedKinectFusion
//
//  Created by 陈俊杰 on 2021/1/14.
//

import Foundation
import Metal
import MetalKit
import ARKit

class CameraImageRenderer {
    private var renderer: Renderer!
    
    // MARK: - Properties from Renderer
    private var session: ARSession { renderer.session }
    private var device: MTLDevice { renderer.device }
    private var renderDestination: RenderDestinationProvider { renderer.renderDestination }
    private var library: MTLLibrary { renderer.library }
    private var relaxedStencilState: MTLDepthStencilState { renderer.relaxedStencilState }
    private var currentCameraParameterUniformBuffer: MetalBuffer<CameraParameterUniforms> { renderer.currentCameraParameterUniformBuffer }
    
    // MARK: - Self owned properties
    private lazy var cameraImagePipelineState: MTLRenderPipelineState =  makeCameraImageRenderPipelineState()!
    private var capturedImageTextureY: CVMetalTexture?
    private var capturedImageTextureCbCr: CVMetalTexture?
    
    // MARK: - Main Methods
    
    init(renderer: Renderer) {
        self.renderer = renderer
    }
    
    func encodeCommands(into commandBuffer: MTLCommandBuffer) {
        if let currentFrame = renderer.currentFrame {
            updateCapturedImageTextures(frame: currentFrame)
        }
        
        // Retain our CVMetalTextures for the duration of the rendering cycle. The MTLTextures
        //   we use from the CVMetalTextures are not valid unless their parent CVMetalTextures
        //   are retained. Since we may release our CVMetalTexture ivars during the rendering
        //   cycle, we must retain them separately here.
        var textures = [capturedImageTextureY, capturedImageTextureCbCr]
        commandBuffer.addCompletedHandler{ _ in
            textures.removeAll()
        }
        
        if let renderPassDescriptor = renderDestination.currentRenderPassDescriptor,
           let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
            
            renderEncoder.label = "CemeraImageRenderEncoder"
            
            drawCapturedImage(renderEncoder: renderEncoder)
            
            // We're done encoding commands
            renderEncoder.endEncoding()
        }
    }
    
    // Summary: Update Y'CbCr textures from image captured via camera.
    private func updateCapturedImageTextures(frame: ARFrame) {
        // Create two textures (Y and CbCr) from the provided frame's captured image
        let pixelBuffer = frame.capturedImage
        
        if (CVPixelBufferGetPlaneCount(pixelBuffer) < 2) {
            return
        }
        
        capturedImageTextureY = renderer.createTexture(fromPixelBuffer: pixelBuffer, pixelFormat:.r8Unorm, planeIndex:0)
        capturedImageTextureCbCr = renderer.createTexture(fromPixelBuffer: pixelBuffer, pixelFormat:.rg8Unorm, planeIndex:1)
    }
    
    private func drawCapturedImage(renderEncoder: MTLRenderCommandEncoder) {
        guard let textureY = capturedImageTextureY,
              let textureCbCr = capturedImageTextureCbCr
        else { return }
        
        // Push a debug group allowing us to identify render commands in the GPU Frame Capture tool
        renderEncoder.pushDebugGroup("DrawCapturedImage")
        
        // Set render command encoder state
        renderEncoder.setRenderPipelineState(cameraImagePipelineState)
        renderEncoder.setDepthStencilState(relaxedStencilState)
        
        // Set mesh's vertex buffers
        renderEncoder.setVertexResource(currentCameraParameterUniformBuffer)
        
        // Set any textures read/sampled from our render pipeline
        renderEncoder.setFragmentResource(Texture(texture: CVMetalTextureGetTexture(textureY)!, index: kTextureIndexY.rawValue))
        renderEncoder.setFragmentResource(Texture(texture: CVMetalTextureGetTexture(textureCbCr)!, index: kTextureIndexCbCr.rawValue))
        
        // Draw each submesh of our mesh
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        
        renderEncoder.popDebugGroup()
    }
}

// MARK: - Metal Setup

extension CameraImageRenderer {
    
    private func makeCameraImageRenderPipelineState() -> MTLRenderPipelineState? {
        let capturedImageVertexFunction = library.makeFunction(name: "capturedImageVertexTransform")!
        let capturedImageFragmentFunction = library.makeFunction(name: "capturedImageFragmentShader")!
        
        // Create a pipeline state for rendering the captured image
        let capturedImagePipelineStateDescriptor = MTLRenderPipelineDescriptor()
        capturedImagePipelineStateDescriptor.label = "MyCapturedImagePipeline"
        capturedImagePipelineStateDescriptor.sampleCount = renderDestination.sampleCount
        capturedImagePipelineStateDescriptor.vertexFunction = capturedImageVertexFunction
        capturedImagePipelineStateDescriptor.fragmentFunction = capturedImageFragmentFunction
        capturedImagePipelineStateDescriptor.colorAttachments[0].pixelFormat = renderDestination.colorPixelFormat
        capturedImagePipelineStateDescriptor.depthAttachmentPixelFormat = renderDestination.depthStencilPixelFormat
        capturedImagePipelineStateDescriptor.stencilAttachmentPixelFormat = renderDestination.depthStencilPixelFormat
        
        return try? device.makeRenderPipelineState(descriptor: capturedImagePipelineStateDescriptor)
    }
    
}
