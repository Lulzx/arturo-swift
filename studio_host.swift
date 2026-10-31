import SwiftUI
import AppKit
import Darwin
import Metal
import MetalKit
import Observation
import QuartzCore

// MARK: - FFI result codes

private enum StudioResult: Int32 {
    case ok = 0
    case notInitialized = -1
    case badSlot = -2
    case compileFailed = 1
}

// MARK: - Control model

enum ControlKind {
    case slider(min: Float, max: Float)
    case toggle
    case color
}

struct ControlSpec: Identifiable {
    let id: Int
    let label: String
    let kind: ControlKind
}

// MARK: - Observable store

@Observable
final class StudioStore {
    var controls: [ControlSpec] = []
    var params: [Float] = Array(repeating: 0, count: 56)
    var compilerError: String?
    var compileTimeMs: Double = 0
    var fps: Int = 0
    var frameMs: Double = 0

    // Input state is read by the renderer each frame; not observed by any view.
    var mouseX: Float = 0.5
    var mouseY: Float = 0.5
    var mouseDown: Bool = false

    @ObservationIgnored private var initializedSlots: Set<Int> = []

    func initialize(slot: Int, defaultValue: Float) {
        guard !initializedSlots.contains(slot) else { return }
        initializedSlots.insert(slot)
        params[slot] = defaultValue
    }

    func resetForSpec() {
        controls.removeAll()
        compilerError = nil
    }
}

// MARK: - Renderer

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let store: StudioStore

    private var pipeline: MTLRenderPipelineState?
    private let startTime = CACurrentMediaTime()
    private var lastFrameTime = CACurrentMediaTime()
    private var frameIndex: Float = 0
    private var fpsWindowStart = CACurrentMediaTime()
    private var fpsFrames = 0

    weak var view: OrbitMTKView?

    init(store: StudioStore) {
        self.store = store
        self.device = MTLCreateSystemDefaultDevice()
        self.queue = device?.makeCommandQueue()
        super.init()
    }

    @discardableResult
    func compile(source: String) -> Bool {
        guard let device else {
            store.compilerError = "No Metal device available on this system."
            return false
        }

        let began = CFAbsoluteTimeGetCurrent()
        defer { store.compileTimeMs = (CFAbsoluteTimeGetCurrent() - began) * 1000 }

        let options = MTLCompileOptions()

        do {
            let library = try device.makeLibrary(source: source, options: options)
            guard let vertex = library.makeFunction(name: "vs_main"),
                  let fragment = library.makeFunction(name: "fs_main") else {
                store.compilerError = "MSL must define vs_main and fs_main."
                return false
            }

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb

            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            store.compilerError = nil
            return true
        } catch {
            store.compilerError = (error as NSError).localizedDescription
            return false
        }
    }

    func renderFrame() {
        view?.draw()
    }

    func draw(in view: MTKView) {
        guard let pipeline,
              let queue,
              view.drawableSize.width > 0,
              view.drawableSize.height > 0,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        let now = CACurrentMediaTime()
        let delta = Float(now - lastFrameTime)
        lastFrameTime = now
        frameIndex += 1

        var uniforms = [Float](repeating: 0, count: 64)
        uniforms[0] = Float(now - startTime)
        uniforms[1] = delta
        uniforms[2] = Float(view.drawableSize.width)
        uniforms[3] = Float(view.drawableSize.height)
        uniforms[4] = store.mouseX
        uniforms[5] = store.mouseY
        uniforms[6] = store.mouseDown ? 1 : 0
        uniforms[7] = frameIndex
        for slot in 0..<56 {
            uniforms[8 + slot] = store.params[slot]
        }

        encoder.setRenderPipelineState(pipeline)
        uniforms.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                encoder.setFragmentBytes(base, length: 256, index: 0)
            }
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()

        fpsFrames += 1
        let elapsed = now - fpsWindowStart
        if elapsed >= 0.5 {
            store.fps = Int((Double(fpsFrames) / elapsed).rounded())
            store.frameMs = Double(delta) * 1000
            fpsFrames = 0
            fpsWindowStart = now
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

// MARK: - Metal view

final class OrbitMTKView: MTKView {
    weak var store: StudioStore?
    private var trackingAreaRef: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseDown(with event: NSEvent) {
        store?.mouseDown = true
        updateCursor(event)
    }

    override func mouseDragged(with event: NSEvent) {
        updateCursor(event)
    }

    override func mouseUp(with event: NSEvent) {
        store?.mouseDown = false
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(event)
    }

    private func updateCursor(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return }
        store?.mouseX = Float(point.x / bounds.width)
        store?.mouseY = Float(point.y / bounds.height)
    }
}

// MARK: - Runtime singleton

final class StudioRuntime {
    static let shared = StudioRuntime()

    let store: StudioStore
    let renderer: Renderer
    let window: NSWindow

    private init() {
        let store = StudioStore()
        self.store = store
        self.renderer = Renderer(store: store)
        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: StudioRootView(store: store))
    }
}

// MARK: - SwiftUI

struct StudioRootView: View {
    @Bindable var store: StudioStore

    var body: some View {
        NavigationSplitView {
            SidebarControls(store: store)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            ZStack(alignment: .bottom) {
                MetalViewport(renderer: StudioRuntime.shared.renderer, store: store)
                    .ignoresSafeArea()

                if let message = store.compilerError {
                    CompilerErrorOverlay(message: message)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.3), value: store.compilerError)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 480)
    }
}

struct SidebarControls: View {
    @Bindable var store: StudioStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TelemetryHeader(store: store)

                Divider()

                ForEach(store.controls) { control in
                    ControlRow(store: store, control: control)
                }

                if store.controls.isEmpty {
                    Text("No controls declared")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .background(.ultraThinMaterial)
        .navigationTitle("Studio")
    }
}

struct TelemetryHeader: View {
    @Bindable var store: StudioStore

    var body: some View {
        HStack(spacing: 8) {
            MetricPill(value: "\(store.fps)", unit: "fps")
            MetricPill(value: String(format: "%.1f", store.frameMs), unit: "ms")
            MetricPill(value: String(format: "%.0f", store.compileTimeMs), unit: "build")
        }
    }
}

struct MetricPill: View {
    let value: String
    let unit: String

    var body: some View {
        HStack(spacing: 3) {
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
            Text(unit)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }
}

struct ControlRow: View {
    @Bindable var store: StudioStore
    let control: ControlSpec

    var body: some View {
        switch control.kind {
        case .slider(let lower, let upper):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(control.label)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                    Spacer()
                    Text(String(format: "%.3f", store.params[control.id]))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: sliderBinding, in: Double(lower)...Double(upper))
                    .controlSize(.small)
            }

        case .toggle:
            Toggle(isOn: toggleBinding) {
                Text(control.label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

        case .color:
            ColorPicker(control.label, selection: colorBinding, supportsOpacity: false)
                .font(.system(size: 12, weight: .medium, design: .rounded))
        }
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { Double(store.params[control.id]) },
            set: { store.params[control.id] = Float($0) }
        )
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { store.params[control.id] != 0 },
            set: { store.params[control.id] = $0 ? 1 : 0 }
        )
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                Color(nsColor: NSColor(
                    srgbRed: CGFloat(store.params[control.id]),
                    green: CGFloat(store.params[control.id + 1]),
                    blue: CGFloat(store.params[control.id + 2]),
                    alpha: 1
                ))
            },
            set: { newColor in
                let rgb = NSColor(newColor).usingColorSpace(.sRGB) ?? .black
                store.params[control.id] = Float(rgb.redComponent)
                store.params[control.id + 1] = Float(rgb.greenComponent)
                store.params[control.id + 2] = Float(rgb.blueComponent)
            }
        )
    }
}

struct MetalViewport: NSViewRepresentable {
    let renderer: Renderer
    let store: StudioStore

    func makeNSView(context: Context) -> OrbitMTKView {
        let view = OrbitMTKView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.store = store
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColor(red: 0.03, green: 0.03, blue: 0.04, alpha: 1)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 120
        // Frames are driven deterministically by studio_step(), not a display link.
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        renderer.view = view
        return view
    }

    func updateNSView(_ nsView: OrbitMTKView, context: Context) {}
}

struct CompilerErrorOverlay: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 13))

            ScrollView {
                Text(message)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.yellow.opacity(0.35))
        )
        .padding(16)
    }
}

// MARK: - C ABI

// Arturo owns the process main thread; every exported entry point runs there.
nonisolated(unsafe) private var studioInitialized = false

private func string(from pointer: UnsafePointer<CChar>?) -> String {
    guard let pointer else { return "" }
    return String(cString: pointer)
}

// Arturo dlcloses the library after every call. Pin this image so that the
// Swift singleton, window, and renderer survive between foreign calls.
private func pinLibrary() {
    let symbol: @convention(c) (UnsafePointer<CChar>?, Int32, Int32) -> Int32 = studio_init
    var info = Dl_info()
    guard dladdr(unsafeBitCast(symbol, to: UnsafeRawPointer.self), &info) != 0,
          let path = info.dli_fname else { return }
    _ = dlopen(path, RTLD_NOW | 0x80) // 0x80 == RTLD_NODELETE on Darwin
}

// Packed forms, because Arturo's call.external supports at most two arguments.
private func fields(from pointer: UnsafePointer<CChar>?) -> [String] {
    string(from: pointer)
        .split(separator: "|", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
}

private func number(_ fields: [String], _ index: Int, fallback: Double = 0) -> Double {
    guard index < fields.count, let value = Double(fields[index]) else { return fallback }
    return value
}

@_cdecl("studio_init")
public func studio_init(
    _ title: UnsafePointer<CChar>?,
    _ width: Int32,
    _ height: Int32
) -> Int32 {
    let app = NSApplication.shared
    _ = app.setActivationPolicy(.regular)
    app.finishLaunching()

    let runtime = StudioRuntime.shared
    runtime.store.resetForSpec()

    let size = NSSize(width: max(CGFloat(width), 320), height: max(CGFloat(height), 240))
    runtime.window.setContentSize(size)
    runtime.window.title = string(from: title)
    runtime.window.center()
    runtime.window.makeKeyAndOrderFront(nil)
    app.activate()

    studioInitialized = true
    return StudioResult.ok.rawValue
}

@_cdecl("studio_begin_Spec")
public func studio_begin_Spec() -> Int32 {
    guard studioInitialized else { return StudioResult.notInitialized.rawValue }
    StudioRuntime.shared.store.resetForSpec()
    return StudioResult.ok.rawValue
}

@_cdecl("studio_add_slider")
public func studio_add_slider(
    _ slot: Int32,
    _ name: UnsafePointer<CChar>?,
    _ minimum: Double,
    _ maximum: Double,
    _ defaultValue: Double
) -> Int32 {
    guard studioInitialized else { return StudioResult.notInitialized.rawValue }
    let store = StudioRuntime.shared.store
    let index = Int(slot)
    guard (0..<56).contains(index) else { return StudioResult.badSlot.rawValue }

    store.controls.append(
        ControlSpec(
            id: index,
            label: string(from: name),
            kind: .slider(min: Float(minimum), max: Float(maximum))
        )
    )
    store.initialize(slot: index, defaultValue: Float(defaultValue))
    return StudioResult.ok.rawValue
}

@_cdecl("studio_add_toggle")
public func studio_add_toggle(
    _ slot: Int32,
    _ name: UnsafePointer<CChar>?,
    _ defaultValue: Int32
) -> Int32 {
    guard studioInitialized else { return StudioResult.notInitialized.rawValue }
    let store = StudioRuntime.shared.store
    let index = Int(slot)
    guard (0..<56).contains(index) else { return StudioResult.badSlot.rawValue }

    store.controls.append(
        ControlSpec(id: index, label: string(from: name), kind: .toggle)
    )
    store.initialize(slot: index, defaultValue: defaultValue == 0 ? 0 : 1)
    return StudioResult.ok.rawValue
}

@_cdecl("studio_add_color")
public func studio_add_color(
    _ slotR: Int32,
    _ name: UnsafePointer<CChar>?,
    _ red: Double,
    _ green: Double,
    _ blue: Double
) -> Int32 {
    guard studioInitialized else { return StudioResult.notInitialized.rawValue }
    let store = StudioRuntime.shared.store
    let index = Int(slotR)
    guard (0..<54).contains(index) else { return StudioResult.badSlot.rawValue }

    store.controls.append(
        ControlSpec(id: index, label: string(from: name), kind: .color)
    )
    store.initialize(slot: index, defaultValue: Float(red))
    store.initialize(slot: index + 1, defaultValue: Float(green))
    store.initialize(slot: index + 2, defaultValue: Float(blue))
    return StudioResult.ok.rawValue
}

@_cdecl("studio_compile_msl")
public func studio_compile_msl(_ msl: UnsafePointer<CChar>?) -> Int32 {
    guard studioInitialized else { return StudioResult.notInitialized.rawValue }
    guard let msl else { return StudioResult.compileFailed.rawValue }
    let compiled = StudioRuntime.shared.renderer.compile(source: String(cString: msl))
    return compiled ? StudioResult.ok.rawValue : StudioResult.compileFailed.rawValue
}

@_cdecl("studio_report_error")
public func studio_report_error(_ message: UnsafePointer<CChar>?) -> Int32 {
    guard studioInitialized else { return StudioResult.notInitialized.rawValue }
    StudioRuntime.shared.store.compilerError = string(from: message)
    return StudioResult.ok.rawValue
}

@_cdecl("studio_clear_error")
public func studio_clear_error() -> Int32 {
    guard studioInitialized else { return StudioResult.notInitialized.rawValue }
    StudioRuntime.shared.store.compilerError = nil
    return StudioResult.ok.rawValue
}

@_cdecl("studio_step")
public func studio_step() -> Int32 {
    guard studioInitialized else { return 0 }
    let app = NSApplication.shared
    while let event = app.nextEvent(
        matching: .any,
        until: .distantPast,
        inMode: .default,
        dequeue: true
    ) {
        app.sendEvent(event)
    }

    StudioRuntime.shared.renderer.renderFrame()
    RunLoop.current.run(mode: .default, before: .distantPast)

    return StudioRuntime.shared.window.isVisible ? 1 : 0
}

// MARK: - Packed two-argument ABI (Arturo call.external limit)

@_cdecl("studio_init_p")
public func studio_init_p(
    _ title: UnsafePointer<CChar>?,
    _ spec: UnsafePointer<CChar>?
) -> Int32 {
    pinLibrary()
    let parts = fields(from: spec)
    let width = Int32(number(parts, 0, fallback: 1200))
    let height = Int32(number(parts, 1, fallback: 780))
    return studio_init(title, width, height)
}

@_cdecl("studio_add_slider_p")
public func studio_add_slider_p(_ slot: Int32, _ spec: UnsafePointer<CChar>?) -> Int32 {
    let parts = fields(from: spec)
    let name = parts.first ?? ""
    return name.withCString { pointer in
        studio_add_slider(
            slot,
            pointer,
            number(parts, 1, fallback: 0),
            number(parts, 2, fallback: 1),
            number(parts, 3, fallback: 0)
        )
    }
}

@_cdecl("studio_add_toggle_p")
public func studio_add_toggle_p(_ slot: Int32, _ spec: UnsafePointer<CChar>?) -> Int32 {
    let parts = fields(from: spec)
    let name = parts.first ?? ""
    let defaultValue = Int32(number(parts, 1, fallback: 1) == 0 ? 0 : 1)
    return name.withCString { pointer in
        studio_add_toggle(slot, pointer, defaultValue)
    }
}

@_cdecl("studio_add_color_p")
public func studio_add_color_p(_ slotR: Int32, _ spec: UnsafePointer<CChar>?) -> Int32 {
    let parts = fields(from: spec)
    let name = parts.first ?? ""
    let (red, green, blue) = colorComponents(parts)
    return name.withCString { pointer in
        studio_add_color(slotR, pointer, red, green, blue)
    }
}

private func colorComponents(_ parts: [String]) -> (Double, Double, Double) {
    guard let last = parts.last, last.hasPrefix("#") else {
        return (number(parts, 1), number(parts, 2), number(parts, 3))
    }
    var hex = String(last.dropFirst())
    if hex.count == 3 {
        hex = hex.map { "\($0)\($0)" }.joined()
    }
    guard hex.count == 6, let value = UInt32(hex, radix: 16) else {
        return (0.2, 0.6, 1.0)
    }
    return (
        Double((value >> 16) & 0xFF) / 255.0,
        Double((value >> 8) & 0xFF) / 255.0,
        Double(value & 0xFF) / 255.0
    )
}
