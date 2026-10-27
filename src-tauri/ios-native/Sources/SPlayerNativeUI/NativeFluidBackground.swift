#if os(iOS)
  import MetalKit
  import SwiftUI

  /// 以 Metal 执行上游网格着色器，UIKit 仅提供原生绘制表面
  struct NativeFluidBackground: UIViewRepresentable {
    let mesh: NativeFluidMesh
    let identity: String
    let active: Bool
    let moving: Bool
    let fps: Int
    let speed: Double
    let scale: Double
    let volume: Double
    @Binding var failure: String?

    /// 每个可见播放器持有一个渲染器，退出时释放 GPU 资源
    func makeCoordinator() -> Renderer { Renderer() }
    /// 初始化原生 Metal 表面并编译随包携带的着色器
    func makeUIView(context: Context) -> MTKView {
      let view = NativeMetalSurface(frame: .zero, device: MTLCreateSystemDefaultDevice())
      #if DEBUG
        view.isAccessibilityElement = ProcessInfo.processInfo.arguments.contains("--uitest-import")
      #endif
      view.enableSetNeedsDisplay = true
      view.accessibilityLabel = "流体背景"
      view.isOpaque = false
      view.autoResizeDrawable = false
      view.backgroundColor = .clear
      view.colorPixelFormat = .bgra8Unorm
      view.clearColor = MTLClearColorMake(0, 0, 0, 0)
      do { try context.coordinator.prepare(view) } catch {
        DispatchQueue.main.async { failure = "流体渲染失败：\(error.localizedDescription)" }
      }
      view.delegate = context.coordinator
      return view
    }
    /// 更新与原版同单位的帧率、渲染比例、流速及暂停状态
    func updateUIView(_ view: MTKView, context: Context) {
      let renderer = context.coordinator
      renderer.speed = moving ? speed : 0
      renderer.moving = moving
      renderer.scale = scale
      renderer.volume = volume
      view.preferredFramesPerSecond = fps
      renderer.resize(view)
      if renderer.identity != identity {
        renderer.install(mesh, identity: identity, view: view)
      }
      if view.isPaused && active { renderer.lastTime = CACurrentMediaTime() }
      view.isPaused = !active || (!moving && renderer.layers.last?.alpha ?? 0 >= 1.1)
      if active { view.setNeedsDisplay() }
    }
    /// 不可见后停止显示时钟与委托，避免后台 GPU 工作
    static func dismantleUIView(_ view: MTKView, coordinator: Renderer) {
      view.isPaused = true
      view.delegate = nil
    }

    /// 静止帧仍需响应旋转后的尺寸变化，不必重启连续动画
    final class NativeMetalSurface: MTKView {
      private var previousSize: CGSize = .zero
      override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != previousSize {
          previousSize = bounds.size
          setNeedsDisplay()
        }
      }
    }

    final class Renderer: NSObject, MTKViewDelegate {
      struct Layer {
        let vertices: MTLBuffer
        let indices: MTLBuffer
        let count: Int
        let texture: MTLTexture
        var alpha: Double
      }
      struct Uniforms {
        var aspect: Float
        var angle: Float
        var volume: Float = 0.1
        var alpha: Float = 1
        var height: Float
      }
      var layers: [Layer] = []
      var identity = ""
      var marked = false
      var speed = 4.0
      var volume = 0.1
      var scale = 0.5
      var moving = true
      var time = 0.0
      var lastTime = CACurrentMediaTime()
      private var queue: MTLCommandQueue?
      private var meshPipeline: MTLRenderPipelineState?
      private var quadPipeline: MTLRenderPipelineState?
      private var intermediate: MTLTexture?

      /// 原版先独立渲染网格，再按正弦缓动 alpha 合成，避免重叠网格重复混色
      func prepare(_ view: MTKView) throws {
        guard let device = view.device,
          let url = Bundle.module.url(forResource: "AMLLMesh.metal", withExtension: "txt")
        else { throw CocoaError(.featureUnsupported) }
        let library = try device.makeLibrary(source: String(contentsOf: url), options: nil)
        queue = device.makeCommandQueue()
        for name in ["mesh", "quad"] {
          let descriptor = MTLRenderPipelineDescriptor()
          descriptor.vertexFunction = library.makeFunction(name: name + "Vertex")
          descriptor.fragmentFunction = library.makeFunction(name: name + "Fragment")
          let color = descriptor.colorAttachments[0]!
          color.pixelFormat = .bgra8Unorm
          if name == "quad" {
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = .sourceAlpha
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = .one
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
          }
          let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
          if name == "mesh" { meshPipeline = pipeline } else { quadPipeline = pipeline }
        }
      }
      /// 按像素密度和用户比例分配一次离屏纹理，尺寸不变时复用
      func resize(_ view: MTKView) {
        let density = view.window?.screen.scale ?? UIScreen.main.scale
        let size = CGSize(
          width: max(1, ceil(view.bounds.width * density * scale)),
          height: max(1, ceil(view.bounds.height * density * scale)))
        if view.drawableSize != size { view.drawableSize = size }
        if intermediate?.width != Int(size.width) || intermediate?.height != Int(size.height) {
          let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height),
            mipmapped: false)
          d.usage = [.renderTarget, .shaderRead]
          intermediate = view.device?.makeTexture(descriptor: d)
        }
      }
      /// 切歌只保留新旧两份网格和 32px 纹理
      func install(_ mesh: NativeFluidMesh, identity: String, view: MTKView) {
        guard let device = view.device,
          let vertices = device.makeBuffer(bytes: mesh.vertices, length: mesh.vertices.count * 4),
          let indices = device.makeBuffer(bytes: mesh.indices, length: mesh.indices.count * 2),
          let texture = device.makeTexture(
            descriptor: .texture2DDescriptor(
              pixelFormat: .rgba8Unorm, width: 32, height: 32, mipmapped: false))
        else { return }
        texture.replace(
          region: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0, withBytes: mesh.pixels,
          bytesPerRow: 128)
        layers = Array(layers.suffix(1))
        layers.append(
          Layer(
            vertices: vertices, indices: indices, count: mesh.indices.count, texture: texture,
            alpha: 0))
        self.identity = identity
        lastTime = CACurrentMediaTime()
      }
      /// 横竖屏变化只重建离屏目标，不重建封面网格
      func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
      /// 使用累计运动时间保证暂停与恢复不会跳帧
      func draw(in view: MTKView) {
        resize(view)
        guard let drawable = view.currentDrawable, let target = intermediate,
          let command = queue?.makeCommandBuffer(), let meshPipeline, let quadPipeline
        else { return }
        let now = CACurrentMediaTime()
        let delta = (now - lastTime) * 1000
        lastTime = now
        time += delta * speed
        if !layers.isEmpty {
          layers[layers.count - 1].alpha = min(1.1, layers.last!.alpha + delta / 500)
          if layers.last!.alpha >= 1.1 { layers = Array(layers.suffix(1)) }
        }
        for (index, layer) in layers.enumerated() {
          var uniforms = Uniforms(
            aspect: Float(target.width) / Float(target.height),
            angle: Float((time / 10000 + volume) * 2), volume: Float(volume),
            height: Float(target.height))
          let pass = MTLRenderPassDescriptor()
          pass.colorAttachments[0].texture = target
          pass.colorAttachments[0].loadAction = .clear
          pass.colorAttachments[0].storeAction = .store
          if let encoder = command.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setRenderPipelineState(meshPipeline)
            encoder.setVertexBuffer(layer.vertices, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(layer.texture, index: 0)
            encoder.drawIndexedPrimitives(
              type: .triangle, indexCount: layer.count, indexType: .uint16,
              indexBuffer: layer.indices, indexBufferOffset: 0)
            encoder.endEncoding()
          }
          pass.colorAttachments[0].texture = drawable.texture
          pass.colorAttachments[0].loadAction = index == 0 ? .clear : .load
          uniforms.alpha = Float(-(cos(.pi * min(1, layer.alpha)) - 1) / 2)
          if let encoder = command.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setRenderPipelineState(quadPipeline)
            encoder.setFragmentTexture(target, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()
          }
        }
        if !layers.isEmpty && !marked {
          marked = true
          command.addCompletedHandler { [weak view] buffer in
            guard buffer.status == .completed else { return }
            DispatchQueue.main.async { view?.accessibilityIdentifier = "native.fluid.rendered" }
          }
        }
        command.present(drawable)
        command.commit()
        if !moving && layers.last?.alpha ?? 0 >= 1.1 { view.isPaused = true }
      }
    }
  }
#endif
