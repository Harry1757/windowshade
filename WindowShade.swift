import AppKit
import AVFoundation
import Carbon
import CoreGraphics
import CoreImage
import CoreMedia
import Security
import Vision

private let mirrorBundleID = "com.apple.ScreenContinuity"

private struct ScreenWindow {
    let id: Int
    let pid: pid_t
    let name: String
    let title: String
    let frame: CGRect
    var displayName: String { title.isEmpty || title == name ? name : "\(name) · \(title)" }

    init?(_ info: [String: Any]) {
        guard let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
        func coordinate(_ key: String) -> CGFloat? {
            if let value = bounds[key] as? NSNumber { return CGFloat(truncating: value) }
            if let value = bounds[key] as? String, let number = Double(value) { return CGFloat(number) }
            return nil
        }
        guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
              let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
              layer == 0,
              let x = coordinate("X"), let y = coordinate("Y"),
              let width = coordinate("Width"), let height = coordinate("Height"),
              width > 60, height > 60 else { return nil }
        self.id = id
        self.pid = pid
        self.name = info[kCGWindowOwnerName as String] as? String ?? "창"
        self.title = info[kCGWindowName as String] as? String ?? ""
        self.frame = CGRect(x: x, y: y, width: width, height: height)
    }
}

private func visibleWindows() -> [ScreenWindow] {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return info.compactMap(ScreenWindow.init)
}

private func cocoaFrame(_ quartzFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: quartzFrame.minX,
           y: primaryHeight - quartzFrame.maxY,
           width: quartzFrame.width,
           height: quartzFrame.height)
}

private func quartzFrame(_ cocoaFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: cocoaFrame.minX, y: primaryHeight - cocoaFrame.maxY,
           width: cocoaFrame.width, height: cocoaFrame.height)
}

private func regionFrame(_ region: CGRect, in window: CGRect) -> CGRect {
    CGRect(x: window.minX + region.minX * window.width,
           y: window.minY + region.minY * window.height,
           width: region.width * window.width,
           height: region.height * window.height).intersection(window)
}

private func normalizedRegion(for area: CGRect, in window: CGRect) -> CGRect? {
    let clipped = area.intersection(window)
    guard !clipped.isNull, clipped.width >= 10, clipped.height >= 10 else { return nil }
    return CGRect(x: (clipped.minX - window.minX) / window.width,
                  y: (clipped.minY - window.minY) / window.height,
                  width: clipped.width / window.width,
                  height: clipped.height / window.height)
}

private func visitorBoost(_ faces: [(box: CGRect, facing: Bool)], ownerIndex: Int?,
                          requireFacing: Bool = true) -> CGFloat {
    guard !faces.isEmpty else { return 0 }
    return faces.enumerated().contains {
        $0.offset != ownerIndex && (!requireFacing || $0.element.facing)
    } ? 1 : 0
}

private func ownerTolerance() -> Float {
    Float(min(1.25, max(0.55, UserDefaults.standard.object(forKey: "ownerTolerance") as? Double ?? 0.9)))
}

private func matchesOwner(faceDistance: Float?, appearanceDistance: Float?, tolerance: Float) -> Bool {
    guard let faceDistance else { return false }
    return faceDistance <= tolerance ||
        (faceDistance <= tolerance + 0.15 && appearanceDistance.map { $0 <= 0.45 } == true)
}

private struct ThreatLatch {
    private(set) var boost: CGFloat = 0
    private var lastSeen: CFTimeInterval = 0

    mutating func update(facing: CGFloat, present: CGFloat, now: CFTimeInterval) -> CGFloat {
        if facing > 0 || (boost > 0 && present > 0) {
            boost = max(boost, facing, present)
            lastSeen = now
        } else if boost > 0 && now - lastSeen >= 2.5 {
            boost = 0
        }
        return boost
    }
}

private func facesScreen(yaw: Double?, pitch: Double?, bothEyesVisible: Bool) -> Bool {
    if let yaw, abs(yaw) > 0.65 { return false }
    if let pitch, abs(pitch) > 0.65 { return false }
    return yaw != nil || pitch != nil || bothEyesVisible
}

private func subtract(_ source: CGRect, by obstacle: CGRect) -> [CGRect] {
    let overlap = source.intersection(obstacle)
    if overlap.isNull { return [source] }
    var remaining: [CGRect] = []
    if overlap.minY > source.minY {
        remaining.append(CGRect(x: source.minX, y: source.minY, width: source.width, height: overlap.minY - source.minY))
    }
    if overlap.maxY < source.maxY {
        remaining.append(CGRect(x: source.minX, y: overlap.maxY, width: source.width, height: source.maxY - overlap.maxY))
    }
    if overlap.minX > source.minX {
        remaining.append(CGRect(x: source.minX, y: overlap.minY, width: overlap.minX - source.minX, height: overlap.height))
    }
    if overlap.maxX < source.maxX {
        remaining.append(CGRect(x: overlap.maxX, y: overlap.minY, width: source.maxX - overlap.maxX, height: overlap.height))
    }
    return remaining
}

private final class TintView: NSView {
    var color: NSColor = .black { didSet { needsDisplay = true } }
    var opacity: CGFloat = 0.35 { didSet { needsDisplay = true } }
    var spotlight = false { didSet { needsDisplay = true } }
    var spotlightRadius: CGFloat = 70 { didSet { needsDisplay = true } }
    var border = false { didSet { needsDisplay = true } }
    var pointer: NSPoint = .zero {
        didSet {
            guard spotlight, abs(pointer.x - oldValue.x) + abs(pointer.y - oldValue.y) > 1 else { return }
            let radius = spotlightRadius + 3
            let oldCircle = CGRect(x: oldValue.x - radius, y: oldValue.y - radius,
                                   width: radius * 2, height: radius * 2)
            let newCircle = CGRect(x: pointer.x - radius, y: pointer.y - radius,
                                   width: radius * 2, height: radius * 2)
            setNeedsDisplay(oldCircle.union(newCircle))
        }
    }
    var visibleRects: [CGRect]? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        if let visibleRects {
            let clip = NSBezierPath()
            for rect in visibleRects { clip.appendRect(rect) }
            clip.addClip()
        }
        color.withAlphaComponent(opacity).setFill()
        if spotlight && bounds.contains(pointer) {
            let path = NSBezierPath(rect: bounds)
            path.appendOval(in: NSRect(x: pointer.x - spotlightRadius, y: pointer.y - spotlightRadius,
                                       width: spotlightRadius * 2, height: spotlightRadius * 2))
            path.windingRule = .evenOdd
            path.fill()
        } else {
            bounds.fill()
        }
        if border {
            color.withAlphaComponent(0.8).setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
            path.lineWidth = 3
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

private final class Mask: NSObject {
    enum Target {
        case mirror
        case window(Int)
        case floating
    }

    let target: Target
    let panel: NSPanel
    let tint = TintView()
    var anchorFrame: CGRect?
    var controlOccluders: [CGRect] = []
    var name: String
    var enabled = true
    var opacity: CGFloat = 0.35 { didSet { updateOpacity() } }
    var privacyBoost: CGFloat = 0 { didSet { updateOpacity() } }
    var cameraTrackingEnabled = false
    var color: NSColor = .black { didSet { updateOpacity() } }
    var spotlight = false { didSet { tint.spotlight = spotlight } }
    var spotlightRadius: CGFloat = 70 { didSet { tint.spotlightRadius = spotlightRadius } }
    var border = false { didSet { tint.border = border } }
    var contentOnly = false
    var topInset: CGFloat = 40
    var customRegion: CGRect?
    var editing = false
    var clickThrough = true { didSet { panel.ignoresMouseEvents = clickThrough && !editing } }
    var visibleRects: [CGRect]? {
        didSet {
            if visibleRects == oldValue { return }
            tint.visibleRects = visibleRects
        }
    }

    init(target: Target, name: String, frame: CGRect = CGRect(x: 240, y: 240, width: 300, height: 220)) {
        self.target = target
        self.name = name
        panel = NSPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        tint.opacity = opacity
        tint.spotlightRadius = spotlightRadius
        tint.frame = panel.contentView?.bounds ?? frame
        tint.autoresizingMask = [.width, .height]
        panel.contentView = tint
    }

    private func updateOpacity() {
        tint.opacity = min(1, opacity + (1 - opacity) * privacyBoost)
        tint.color = privacyBoost > 0 ? .black : color
    }

    func setEditing(_ value: Bool) {
        guard editing != value else { return }
        if value {
            let contentFrame = panel.frame
            panel.styleMask = [.titled, .resizable]
            panel.setFrame(panel.frameRect(forContentRect: contentFrame), display: true)
            panel.isMovableByWindowBackground = true
            visibleRects = nil
        } else {
            let contentFrame = panel.contentRect(forFrameRect: panel.frame)
            panel.styleMask = [.borderless]
            panel.setFrame(contentFrame, display: true)
            panel.isMovableByWindowBackground = false
        }
        editing = value
        panel.title = "가리개 위치·크기 조절 후 메뉴에서 완료"
        panel.ignoresMouseEvents = clickThrough && !value
        panel.orderFrontRegardless()
    }
}

private enum OwnerFaceStore {
    private static let service = "local.hwangsoonhwan.windowshade.owner-face"
    private static let account = "owner"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> VNFeaturePrintObservation? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }

    static func save(_ print: VNFeaturePrintObservation) -> Bool {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: print, requiringSecureCoding: true) else { return false }
        let update = [kSecValueData as String: data]
        let result = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if result == errSecSuccess { return true }
        guard result == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "창 가리개 본인 얼굴 특징"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func clear() -> Bool {
        let result = SecItemDelete(query as CFDictionary)
        return result == errSecSuccess || result == errSecItemNotFound
    }
}

private final class CameraGuard: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let analysisQueue = DispatchQueue(label: "local.windowshade.camera", qos: .userInitiated)
    private var configured = false
    private var starting = false
    private var generation = 0
    private var pendingEnrollment = false
    private var enrollmentRequested = false
    private var lastAnalysis: CFTimeInterval = 0
    private var threatLatch = ThreatLatch()
    private var ownerPrint: VNFeaturePrintObservation?
    private var ownerAppearancePrint: VNFeaturePrintObservation?
    private var lastAppearanceUpdate: CFTimeInterval = 0

    private(set) var isEnabled = false
    private(set) var hasOwner: Bool
    private(set) var status: String
    var onBoost: ((CGFloat) -> Void)?
    var onStatus: ((String) -> Void)?
    var onEnrollment: ((Bool) -> Void)?

    override init() {
        let stored = CommandLine.arguments.contains("--self-test") ? nil : OwnerFaceStore.load()
        ownerPrint = stored
        hasOwner = stored != nil
        status = stored == nil ? "본인 미등록" : "본인 등록됨 · 꺼짐"
        super.init()
    }

    func start() {
        guard !isEnabled, !starting else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: beginCapture()
        case .notDetermined:
            updateStatus("카메라 권한 확인 중")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.beginCapture() }
                    else { self?.updateStatus("카메라 권한이 필요합니다") }
                }
            }
        default: updateStatus("카메라 권한이 꺼져 있습니다")
        }
    }

    func stop() {
        generation += 1
        starting = false
        isEnabled = false
        pendingEnrollment = false
        updateStatus(hasOwner ? "본인 등록됨 · 꺼짐" : "본인 미등록")
        onBoost?(0)
        analysisQueue.async { [weak self] in
            guard let self else { return }
            self.enrollmentRequested = false
            self.threatLatch = ThreatLatch()
            self.ownerAppearancePrint = nil
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func enroll() {
        pendingEnrollment = true
        if !isEnabled { start(); return }
        pendingEnrollment = false
        updateStatus("혼자 카메라를 정면으로 보세요")
        analysisQueue.async { [weak self] in self?.enrollmentRequested = true }
    }

    func resetOwner() -> Bool {
        if isEnabled || starting { stop() }
        let cleared = OwnerFaceStore.clear()
        if cleared {
            hasOwner = false
            updateStatus("본인 미등록")
            onBoost?(0)
            analysisQueue.async { [weak self] in
                self?.ownerPrint = nil
                self?.ownerAppearancePrint = nil
            }
        }
        return cleared
    }

    private func beginCapture() {
        guard !isEnabled, !starting else { return }
        starting = true
        generation += 1
        let token = generation
        updateStatus("카메라 준비 중")
        analysisQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configureIfNeeded()
                self.session.startRunning()
                DispatchQueue.main.async {
                    guard token == self.generation, self.session.isRunning else {
                        self.analysisQueue.async { if self.session.isRunning { self.session.stopRunning() } }
                        return
                    }
                    self.starting = false
                    self.isEnabled = true
                    self.updateStatus(self.hasOwner ? "카메라 감지 중" : "본인 등록이 필요합니다")
                    if self.pendingEnrollment { self.enroll() }
                }
            } catch {
                DispatchQueue.main.async {
                    self.starting = false
                    self.updateStatus("카메라를 시작하지 못했습니다")
                }
            }
        }
    }

    private func configureIfNeeded() throws {
        guard !configured else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video) else { throw NSError(domain: "WindowShade", code: 1) }

        let wideFormat = device.formats.filter { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return size.width > size.height && Double(size.width) / Double(size.height) < 1.5
        }.max { lhs, rhs in
            let a = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return Int(a.width) * Int(a.height) < Int(b.width) * Int(b.height)
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw NSError(domain: "WindowShade", code: 2) }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: analysisQueue)
        guard session.canAddOutput(output) else { throw NSError(domain: "WindowShade", code: 3) }
        session.addOutput(output)
        if let wideFormat, (try? device.lockForConfiguration()) != nil {
            device.activeFormat = wideFormat
            device.unlockForConfiguration()
        }
        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAnalysis >= 0.25,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = now
        let request = VNDetectFaceLandmarksRequest()
        guard (try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up).perform([request])) != nil else { return }
        let faces = request.results ?? []

        if enrollmentRequested {
            guard faces.count == 1, isFacing(faces[0]),
                  faces[0].boundingBox.width >= 0.12,
                  let print = featurePrint(for: faces[0], in: pixelBuffer) else {
                enrollmentRequested = false
                DispatchQueue.main.async {
                    self.updateStatus("혼자 정면을 보고 다시 시도하세요")
                    self.onEnrollment?(false)
                }
                return
            }
            let saved = OwnerFaceStore.save(print)
            enrollmentRequested = false
            if saved {
                ownerPrint = print
                ownerAppearancePrint = appearancePrint(for: faces[0], in: pixelBuffer)
            }
            DispatchQueue.main.async {
                self.hasOwner = saved
                self.updateStatus(saved ? "본인 등록됨 · 카메라 감지 중" : "본인 정보를 저장하지 못했습니다")
                self.onEnrollment?(saved)
            }
            return
        }

        var facingBoost: CGFloat = 0
        var presenceBoost: CGFloat = 0
        if let ownerPrint, !faces.isEmpty {
            var bestDistance = Float.greatestFiniteMagnitude
            var ownerIndex: Int?
            let tolerance = ownerTolerance()
            for (index, face) in faces.enumerated() {
                guard let print = featurePrint(for: face, in: pixelBuffer) else { continue }
                var distance: Float = 0
                guard (try? print.computeDistance(&distance, to: ownerPrint)) != nil else { continue }
                var appearanceDistance: Float?
                if distance > tolerance, distance <= tolerance + 0.15,
                   let ownerAppearancePrint,
                   let appearance = appearancePrint(for: face, in: pixelBuffer) {
                    var value: Float = 0
                    if (try? appearance.computeDistance(&value, to: ownerAppearancePrint)) != nil {
                        appearanceDistance = value
                    }
                }
                if matchesOwner(faceDistance: distance, appearanceDistance: appearanceDistance, tolerance: tolerance),
                   distance < bestDistance {
                    bestDistance = distance
                    ownerIndex = index
                }
            }
            if let ownerIndex, bestDistance <= tolerance, now - lastAppearanceUpdate >= 4 {
                ownerAppearancePrint = appearancePrint(for: faces[ownerIndex], in: pixelBuffer)
                lastAppearanceUpdate = now
            }
            // ponytail: Generic image prints can confuse similar faces; use a dedicated face model for stronger identity assurance.
            let observations = faces.map { (box: $0.boundingBox, facing: isFacing($0)) }
            facingBoost = visitorBoost(observations, ownerIndex: ownerIndex)
            presenceBoost = visitorBoost(observations, ownerIndex: ownerIndex, requireFacing: false)
        }
        let target = threatLatch.update(facing: facingBoost, present: presenceBoost, now: now)
        let boost = target
        let faceCount = faces.count
        DispatchQueue.main.async {
            self.onBoost?(boost)
            self.updateStatus(boost > 0.1 ? "다른 얼굴 감지 · 가리개 강화" :
                              self.hasOwner ? "카메라 감지 중 · 얼굴 \(faceCount)명" : "본인 등록이 필요합니다")
        }
    }

    private func featurePrint(for face: VNFaceObservation, in buffer: CVPixelBuffer) -> VNFeaturePrintObservation? {
        let box = face.boundingBox
        return imagePrint(for: box, in: buffer)
    }

    private func appearancePrint(for face: VNFaceObservation, in buffer: CVPixelBuffer) -> VNFeaturePrintObservation? {
        let box = face.boundingBox
        let area = CGRect(x: box.minX - box.width * 0.35, y: box.minY - box.height * 1.5,
                          width: box.width * 1.7, height: box.height * 2.85)
        return imagePrint(for: area, in: buffer)
    }

    private func imagePrint(for box: CGRect, in buffer: CVPixelBuffer) -> VNFeaturePrintObservation? {
        let image = CIImage(cvPixelBuffer: buffer)
        let rect = CGRect(x: box.minX * image.extent.width, y: box.minY * image.extent.height,
                          width: box.width * image.extent.width, height: box.height * image.extent.height)
        let crop = rect.insetBy(dx: -rect.width * 0.1, dy: -rect.height * 0.1).intersection(image.extent)
        guard !crop.isNull, crop.width >= 40, crop.height >= 40 else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        guard (try? VNImageRequestHandler(ciImage: image.cropped(to: crop), orientation: .up).perform([request])) != nil else { return nil }
        return request.results?.first
    }

    private func isFacing(_ face: VNFaceObservation) -> Bool {
        facesScreen(yaw: face.yaw?.doubleValue, pitch: face.pitch?.doubleValue,
                    bothEyesVisible: face.landmarks?.leftEye != nil && face.landmarks?.rightEye != nil)
    }

    private func updateStatus(_ value: String) {
        guard status != value else { return }
        status = value
        onStatus?(value)
    }
}

private final class ControlPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class MaskBar: NSObject {
    let panel: NSPanel
    let slider = NSSlider()
    let spotlightButton = NSButton()
    let closeButton = NSButton()
    let settingsButton = NSButton()
    weak var owner: ShadeApp?
    weak var mask: Mask?

    init(owner: ShadeApp) {
        self.owner = owner
        panel = ControlPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = NSView(frame: panel.contentView?.bounds ?? .zero)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.94).cgColor
        content.layer?.cornerRadius = 10
        slider.minValue = 0.05
        slider.maxValue = 1
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changeOpacity(_:))
        content.addSubview(slider)
        for (button, symbol, tip, action) in [
            (spotlightButton, "viewfinder", "마우스 주변 밝게", #selector(toggleSpotlight)),
            (closeButton, "xmark", "조절 바 닫기", #selector(closeBar)),
            (settingsButton, "slider.horizontal.3", "가리개별 설정", #selector(showSettings))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.toolTip = tip
            button.isBordered = false
            button.target = self
            button.action = action
            content.addSubview(button)
        }
        panel.contentView = content
    }

    func show(_ mask: Mask, frame: CGRect) {
        self.mask = mask
        if abs(slider.doubleValue - Double(mask.opacity)) > 0.001 { slider.doubleValue = Double(mask.opacity) }
        spotlightButton.contentTintColor = mask.spotlight ? .systemBlue : .white
        let width = min(280, max(200, frame.width - 8))
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? frame
        let x = min(max(frame.maxX - width - 4, visible.minX + 4), visible.maxX - width - 4)
        let y = frame.maxY + 44 <= visible.maxY - 4 ? frame.maxY : frame.maxY - 48
        let barFrame = CGRect(x: x, y: y, width: width, height: 44)
        if mask.controlOccluders.contains(where: { $0.intersects(barFrame) }) { hide(); return }
        if panel.frame != barFrame {
            panel.setFrame(barFrame, display: true)
            slider.frame = CGRect(x: 10, y: 10, width: width - 112, height: 24)
            for (index, button) in [spotlightButton, closeButton, settingsButton].enumerated() {
                button.frame = CGRect(x: width - 96 + CGFloat(index * 30), y: 8, width: 28, height: 28)
            }
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() { panel.orderOut(nil); mask = nil }

    @objc private func changeOpacity(_ sender: NSSlider) {
        guard let mask else { return }
        owner?.setOpacity(mask, value: sender.doubleValue)
    }
    @objc private func toggleSpotlight() { if let mask { owner?.toggleSpotlightFor(mask) } }
    @objc private func closeBar() { owner?.closeBar() }
    @objc private func showSettings() {
        guard let mask else { return }
        owner?.showSettings(for: mask, at: settingsButton)
    }
}

private final class MaskHandle: NSObject {
    let panel: NSPanel
    weak var owner: ShadeApp?
    weak var mask: Mask?

    init(owner: ShadeApp, mask: Mask) {
        self.owner = owner
        self.mask = mask
        panel = ControlPanel(contentRect: NSRect(x: 0, y: 0, width: 32, height: 32),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "가리개 조절 열기")
        button.toolTip = "클릭해서 이 가리개 조절"
        button.isBordered = false
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.94).cgColor
        button.layer?.cornerRadius = 9
        button.target = self
        button.action = #selector(openBar)
        panel.contentView = button
    }

    func place(near frame: CGRect) {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? frame
        let x = min(max(frame.maxX - 32, visible.minX + 4), visible.maxX - 36)
        let y = frame.maxY + 32 <= visible.maxY - 4 ? frame.maxY : frame.maxY - 34
        let position = CGRect(x: x, y: y, width: 32, height: 32)
        if mask?.controlOccluders.contains(where: { $0.intersects(position) }) == true { hide(); return }
        if panel.frame != position { panel.setFrame(position, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() { panel.orderOut(nil) }
    @objc private func openBar() { if let mask { owner?.toggleBar(for: mask) } }
}

private final class ShadeApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var masks: [Mask] = []
    private var selected: Mask?
    private var colorTarget: Mask?
    private let cameraGuard = CameraGuard()
    private var cameraBoost: CGFloat = 0
    private var hidden = false
    private var timer: Timer?
    private var mouseTimer: Timer?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private lazy var bar = MaskBar(owner: self)
    private var handles: [ObjectIdentifier: MaskHandle] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◐"
        statusItem.button?.toolTip = "창 가리개"
        menu.delegate = self
        statusItem.menu = menu
        cameraGuard.onBoost = { [weak self] boost in
            guard let self else { return }
            self.cameraBoost = boost
            for mask in self.masks {
                mask.privacyBoost = mask.cameraTrackingEnabled ? boost : 0
            }
        }
        cameraGuard.onStatus = { [weak self] status in
            self?.statusItem.button?.toolTip = "창 가리개 · \(status)"
        }
        cameraGuard.onEnrollment = { success in
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = success ? "본인 얼굴을 지정했습니다" : "본인 정보를 저장하지 못했습니다"
            alert.informativeText = success ? "얼굴 특징만 이 Mac의 키체인에 보관합니다. 메뉴에서 언제든 다시 지정하거나 삭제할 수 있습니다." : "잠시 후 다시 시도해 주세요."
            alert.runModal()
        }

        let mirror = Mask(target: .mirror, name: "아이폰 미러링")
        mirror.contentOnly = true
        mirror.opacity = CGFloat(UserDefaults.standard.double(forKey: "mirrorOpacity"))
        if mirror.opacity == 0 { mirror.opacity = 0.35 }
        masks.append(mirror)
        selected = mirror
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.refresh() }
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.refreshPointer() }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            Unmanaged<ShadeApp>.fromOpaque(context).takeUnretainedValue().toggleAll()
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        let keyID = EventHotKeyID(signature: OSType(0x574E5348), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(cmdKey | shiftKey), keyID,
                            GetApplicationEventTarget(), 0, &hotKey)
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        cameraGuard.stop()
    }

    private func refresh() {
        let windows = visibleWindows()
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for mask in masks {
            if hidden || !mask.enabled { mask.panel.orderOut(nil); continue }
            switch mask.target {
            case .floating:
                mask.controlOccluders = []
                if !mask.panel.isVisible { mask.panel.orderFrontRegardless() }
            case .mirror, .window:
                let index = windows.firstIndex { window in
                    switch mask.target {
                    case .mirror:
                        return NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier == mirrorBundleID
                    case .window(let id):
                        return window.id == id
                    case .floating:
                        return false
                    }
                }
                guard let index else { mask.panel.orderOut(nil); continue }
                let target = windows[index]
                mask.anchorFrame = cocoaFrame(target.frame, primaryHeight: primaryHeight)
                mask.controlOccluders = windows[..<index]
                    .filter { $0.pid != getpid() && $0.pid != target.pid }
                    .map { cocoaFrame($0.frame, primaryHeight: primaryHeight) }
                if mask.editing {
                    mask.visibleRects = nil
                    if !mask.panel.isVisible { mask.panel.orderFrontRegardless() }
                    continue
                }
                let top = mask.contentOnly ? min(mask.topInset, target.frame.height - 1) : 0
                let area = mask.customRegion.map { regionFrame($0, in: target.frame) }
                    ?? CGRect(x: target.frame.minX, y: target.frame.minY + top,
                              width: target.frame.width, height: target.frame.height - top)
                var exposed = [CGRect(origin: .zero, size: area.size)]
                for obstacle in windows[..<index] where obstacle.pid != getpid() && obstacle.pid != target.pid {
                    let overlap = area.intersection(obstacle.frame)
                    if overlap.isNull { continue }
                    let local = CGRect(x: overlap.minX - area.minX,
                                       y: area.maxY - overlap.maxY,
                                       width: overlap.width, height: overlap.height)
                    exposed = exposed.flatMap { subtract($0, by: local) }
                    if exposed.isEmpty { break }
                }
                if exposed.isEmpty { mask.panel.orderOut(nil); continue }
                let frame = cocoaFrame(area, primaryHeight: primaryHeight)
                if mask.panel.frame != frame { mask.panel.setFrame(frame, display: true) }
                mask.visibleRects = exposed
                if !mask.panel.isVisible { mask.panel.orderFrontRegardless() }
            }
        }
        refreshControls()
    }

    private func refreshControls() {
        let active = Set(masks.map(ObjectIdentifier.init))
        for id in handles.keys.filter({ !active.contains($0) }) {
            handles[id]?.hide()
            handles.removeValue(forKey: id)
        }
        for mask in masks {
            let id = ObjectIdentifier(mask)
            let handle = handles[id] ?? MaskHandle(owner: self, mask: mask)
            handles[id] = handle
            guard !hidden, mask.enabled, mask.panel.isVisible, !mask.editing else { handle.hide(); continue }
            if bar.mask === mask && bar.panel.isVisible {
                handle.hide()
                bar.show(mask, frame: mask.anchorFrame ?? mask.panel.frame)
            } else {
                handle.place(near: mask.anchorFrame ?? mask.panel.frame)
            }
        }
        if let mask = bar.mask, hidden || !mask.enabled || !mask.panel.isVisible { bar.hide() }
    }

    func toggleBar(for mask: Mask) {
        if bar.mask === mask && bar.panel.isVisible { bar.hide() }
        else { bar.show(mask, frame: mask.anchorFrame ?? mask.panel.frame) }
        refreshControls()
    }

    func closeBar() { bar.hide(); refreshControls() }

    private func refreshPointer() {
        let pointer = NSEvent.mouseLocation
        for mask in masks where mask.spotlight && mask.panel.isVisible {
            let local = mask.tint.convert(mask.panel.convertPoint(fromScreen: pointer), from: nil)
            if abs(local.x - mask.tint.pointer.x) + abs(local.y - mask.tint.pointer.y) > 1 {
                mask.tint.pointer = local
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("아이폰 미러링 가리개", #selector(selectMirror)))
        menu.addItem(item("현재 창에 가리개 붙이기", #selector(addCurrentWindow)))
        let pick = NSMenuItem(title: "창 선택해서 붙이기", action: nil, keyEquivalent: "")
        let choices = NSMenu()
        for window in visibleWindows() where window.pid != getpid() &&
            NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier != mirrorBundleID {
            let choice = item(String(window.displayName.prefix(60)), #selector(addChosenWindow))
            choice.tag = window.id
            choices.addItem(choice)
        }
        pick.submenu = choices
        menu.addItem(pick)
        menu.addItem(item("떠 있는 가리개 추가", #selector(addFloating)))
        let camera = NSMenuItem(title: cameraGuard.isEnabled ? "카메라 트래킹 ●" : "카메라 트래킹", action: nil, keyEquivalent: "")
        let cameraMenu = NSMenu()
        let toggleCamera = item(cameraGuard.isEnabled ? "트래킹 끄기" : "트래킹 켜기", #selector(toggleCameraTracking))
        cameraMenu.addItem(toggleCamera)
        cameraMenu.addItem(disabledLabel(cameraGuard.status))
        cameraMenu.addItem(disabledLabel("반응할 가리개 \(masks.filter(\.cameraTrackingEnabled).count)개"))
        cameraMenu.addItem(disabledLabel("본인 판별 기준 · 낮을수록 엄격"))
        cameraMenu.addItem(sliderItem(Double(ownerTolerance()), 0.55, 1.25, 0, #selector(changeOwnerTolerance(_:))))
        cameraMenu.addItem(.separator())
        cameraMenu.addItem(item(cameraGuard.hasOwner ? "나로 다시 지정…" : "나로 지정…", #selector(enrollOwner)))
        if cameraGuard.hasOwner { cameraMenu.addItem(item("본인 등록 정보 삭제…", #selector(resetOwner))) }
        camera.submenu = cameraMenu
        menu.addItem(camera)
        menu.addItem(.separator())

        for (index, mask) in masks.enumerated() {
            let row = item("\(mask.enabled ? "● " : "○ ")\(mask.name)", #selector(selectMask))
            row.tag = index
            let submenu = NSMenu()
            let show = item("표시", #selector(toggleMask))
            show.tag = index
            show.state = mask.enabled ? .on : .off
            submenu.addItem(show)
            submenu.addItem(.separator())
            submenu.addItem(disabledLabel("어둡기"))
            submenu.addItem(sliderItem(Double(mask.opacity), 0.05, 1, index, #selector(changeOpacity(_:))))
            let spotlight = item("마우스 주변 밝게", #selector(toggleSpotlight(_:)))
            spotlight.tag = index
            spotlight.state = mask.spotlight ? .on : .off
            submenu.addItem(spotlight)
            let tracking = item("카메라 반응", #selector(toggleMaskTracking(_:)))
            tracking.tag = index
            tracking.state = mask.cameraTrackingEnabled ? .on : .off
            submenu.addItem(tracking)
            if mask.spotlight {
                submenu.addItem(disabledLabel("밝게 보일 범위"))
                submenu.addItem(sliderItem(Double(mask.spotlightRadius), 30, 200, index, #selector(changeSpotlightRadius(_:))))
            }
            let border = item("테두리 표시", #selector(toggleBorder(_:)))
            border.tag = index
            border.state = mask.border ? .on : .off
            submenu.addItem(border)
            let color = NSMenuItem(title: "가리개 색", action: nil, keyEquivalent: "")
            let colorChoices = NSMenu()
            for (title, shade) in [
                ("검정", NSColor.black),
                ("짙은 회색", NSColor(calibratedWhite: 0.18, alpha: 1)),
                ("남색", NSColor(calibratedRed: 0.04, green: 0.10, blue: 0.27, alpha: 1)),
                ("갈색", NSColor(calibratedRed: 0.26, green: 0.14, blue: 0.08, alpha: 1)),
                ("흰색", NSColor.white)
            ] {
                let preset = item(title, #selector(setPresetColor(_:)))
                preset.tag = index
                preset.representedObject = shade
                preset.state = mask.color == shade ? .on : .off
                colorChoices.addItem(preset)
            }
            colorChoices.addItem(.separator())
            let custom = item("더 많은 색…", #selector(chooseColor(_:)))
            custom.tag = index
            colorChoices.addItem(custom)
            color.submenu = colorChoices
            submenu.addItem(color)
            let click = item("클릭 통과", #selector(toggleClickThrough(_:)))
            click.tag = index
            click.state = mask.clickThrough ? .on : .off
            submenu.addItem(click)
            if case .floating = mask.target {
            } else {
                submenu.addItem(.separator())
                let area = NSMenuItem(title: "가리는 영역", action: nil, keyEquivalent: "")
                let areaMenu = NSMenu()
                let isMirror: Bool
                if case .mirror = mask.target { isMirror = true } else { isMirror = false }
                let full = item(isMirror ? "조작부까지 가리기" : "창 전체", #selector(showEntireWindow(_:)))
                full.tag = index
                full.state = mask.customRegion == nil && !mask.contentOnly ? .on : .off
                areaMenu.addItem(full)
                let content = item(isMirror ? "아이폰 화면만 가리기" : "내용만", #selector(showContentOnly(_:)))
                content.tag = index
                content.state = mask.customRegion == nil && mask.contentOnly ? .on : .off
                areaMenu.addItem(content)
                if mask.customRegion == nil && mask.contentOnly {
                    areaMenu.addItem(disabledLabel("상단에서 제외할 높이"))
                    areaMenu.addItem(sliderItem(Double(mask.topInset), 20, 120, index, #selector(changeTopInset(_:))))
                }
                areaMenu.addItem(.separator())
                let editRegion = item(mask.editing ? "영역 조절 마치기" : "자유 영역 조절…", #selector(toggleEditing(_:)))
                editRegion.tag = index
                editRegion.state = mask.customRegion != nil ? .on : .off
                areaMenu.addItem(editRegion)
                area.submenu = areaMenu
                submenu.addItem(area)
                let another = item("같은 창에 새 영역 추가", #selector(addRegionSameWindow(_:)))
                another.tag = index
                submenu.addItem(another)
            }
            if case .floating = mask.target {
                submenu.addItem(.separator())
                let edit = item(mask.editing ? "위치 조절 마치기" : "위치·크기 조절", #selector(toggleEditing))
                edit.tag = index
                submenu.addItem(edit)
            }
            if index != 0 {
                submenu.addItem(.separator())
                let remove = item("삭제", #selector(removeMask))
                remove.tag = index
                submenu.addItem(remove)
            }
            row.submenu = submenu
            menu.addItem(row)
        }

        menu.addItem(.separator())
        menu.addItem(item(hidden ? "가리개 모두 표시  ⌘⇧D" : "가리개 모두 숨기기  ⌘⇧D", #selector(toggleAll)))
        menu.addItem(item("종료", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func disabledLabel(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func sliderItem(_ value: Double, _ minimum: Double, _ maximum: Double,
                            _ index: Int, _ action: Selector) -> NSMenuItem {
        let slider = NSSlider(value: value, minValue: minimum, maxValue: maximum, target: self, action: action)
        slider.tag = index
        slider.frame = NSRect(x: 15, y: 7, width: 190, height: 25)
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 39))
        holder.addSubview(slider)
        let item = NSMenuItem()
        item.view = holder
        return item
    }

    @objc private func selectMirror() { selected = masks[0]; masks[0].enabled = true; hidden = false; refresh() }
    @objc private func selectMask(_ sender: NSMenuItem) { selected = masks[sender.tag] }
    @objc private func toggleMask(_ sender: NSMenuItem) {
        let mask = masks[sender.tag]
        mask.enabled.toggle()
        if !mask.enabled && bar.mask === mask { bar.hide() }
        refresh()
    }

    @objc private func addCurrentWindow() {
        let window = visibleWindows().first {
            $0.pid != getpid() && NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier != mirrorBundleID
        }
        guard let window else { NSSound.beep(); return }
        let mask = Mask(target: .window(window.id), name: window.displayName)
        masks.append(mask)
        selected = mask
        refresh()
    }

    @objc private func addChosenWindow(_ sender: NSMenuItem) {
        guard let window = visibleWindows().first(where: { $0.id == sender.tag }) else { NSSound.beep(); return }
        let mask = Mask(target: .window(window.id), name: window.displayName)
        masks.append(mask)
        selected = mask
        refresh()
    }

    @objc private func addFloating() {
        let mask = Mask(target: .floating, name: "떠 있는 가리개 \(masks.count)")
        masks.append(mask)
        selected = mask
        mask.setEditing(true)
        refresh()
    }

    @objc private func addRegionSameWindow(_ sender: NSMenuItem) {
        let source = masks[sender.tag]
        if case .floating = source.target { return }
        let baseName = source.name.components(separatedBy: " · 영역").first ?? source.name
        let count = masks.filter { $0.name.hasPrefix(baseName + " · 영역") }.count + 1
        let mask = Mask(target: source.target, name: "\(baseName) · 영역 \(count)")
        mask.customRegion = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.35)
        mask.opacity = source.opacity
        mask.color = source.color
        masks.append(mask)
        selected = mask
        refresh()
        if mask.panel.isVisible { mask.setEditing(true); refreshControls() }
    }

    @objc private func toggleEditing(_ sender: NSMenuItem) {
        let mask = masks[sender.tag]
        if mask.editing {
            mask.setEditing(false)
            switch mask.target {
            case .floating: break
            case .mirror, .window:
                if let anchor = mask.anchorFrame {
                    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                    let target = quartzFrame(anchor, primaryHeight: primaryHeight)
                    let area = quartzFrame(mask.panel.frame, primaryHeight: primaryHeight)
                    if let region = normalizedRegion(for: area, in: target) { mask.customRegion = region }
                }
            }
            refresh()
        } else {
            mask.enabled = true
            hidden = false
            refresh()
            mask.setEditing(true)
            if bar.mask === mask { bar.hide() }
            refreshControls()
        }
    }

    @objc private func removeMask(_ sender: NSMenuItem) {
        let mask = masks.remove(at: sender.tag)
        mask.panel.orderOut(nil)
        if bar.mask === mask { bar.hide() }
        if colorTarget === mask { colorTarget = nil; NSColorPanel.shared.orderOut(nil) }
        if selected === mask { selected = masks.first }
    }

    @objc private func changeOpacity(_ slider: NSSlider) { setOpacity(masks[slider.tag], value: slider.doubleValue) }

    func setOpacity(_ mask: Mask, value: Double) {
        mask.opacity = CGFloat(value)
        if mask === masks.first { UserDefaults.standard.set(value, forKey: "mirrorOpacity") }
    }

    func hideMask(_ mask: Mask) {
        mask.enabled = false
        bar.hide()
        refresh()
    }

    func showSettings(for mask: Mask, at view: NSView) {
        guard let index = masks.firstIndex(where: { $0 === mask }) else { return }
        let copy = NSMenu()
        menuWillOpen(copy)
        copy.items.first(where: { $0.tag == index && $0.submenu?.items.first?.title == "표시" })?
            .submenu?.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY), in: view)
    }

    @objc private func changeSpotlightRadius(_ slider: NSSlider) {
        masks[slider.tag].spotlightRadius = CGFloat(slider.doubleValue)
    }
    @objc private func toggleCameraTracking() {
        if cameraGuard.isEnabled { cameraGuard.stop() } else { cameraGuard.start() }
    }
    @objc private func changeOwnerTolerance(_ slider: NSSlider) {
        UserDefaults.standard.set(slider.doubleValue, forKey: "ownerTolerance")
    }
    @objc private func enrollOwner() {
        let alert = NSAlert()
        alert.messageText = "본인 얼굴 지정"
        alert.informativeText = "카메라 앞에 혼자 앉아 화면 쪽을 바라봐 주세요. 사진은 저장하지 않고 얼굴 특징만 키체인에 보관합니다."
        alert.addButton(withTitle: "시작")
        alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { cameraGuard.enroll() }
    }
    @objc private func resetOwner() {
        let alert = NSAlert()
        alert.messageText = "본인 얼굴 등록 정보를 삭제할까요?"
        alert.informativeText = "삭제 후에는 다시 지정해야 카메라 트래킹을 사용할 수 있습니다."
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if !cameraGuard.resetOwner() { NSSound.beep() }
            cameraBoost = 0
            for mask in masks { mask.privacyBoost = 0 }
        }
    }
    @objc private func toggleMaskTracking(_ sender: NSMenuItem) {
        let mask = masks[sender.tag]
        mask.cameraTrackingEnabled.toggle()
        mask.privacyBoost = mask.cameraTrackingEnabled && cameraGuard.isEnabled ? cameraBoost : 0
    }
    @objc private func changeTopInset(_ slider: NSSlider) {
        masks[slider.tag].topInset = CGFloat(slider.doubleValue)
        refresh()
    }
    @objc private func showEntireWindow(_ sender: NSMenuItem) {
        let mask = masks[sender.tag]
        if mask.editing { mask.setEditing(false) }
        mask.customRegion = nil
        mask.contentOnly = false
        refresh()
    }
    @objc private func showContentOnly(_ sender: NSMenuItem) {
        let mask = masks[sender.tag]
        if mask.editing { mask.setEditing(false) }
        mask.customRegion = nil
        mask.contentOnly = true
        refresh()
    }
    @objc private func toggleSpotlight(_ sender: NSMenuItem) { toggleSpotlightFor(masks[sender.tag]) }
    func toggleSpotlightFor(_ mask: Mask) { mask.spotlight.toggle() }
    @objc private func toggleBorder(_ sender: NSMenuItem) { masks[sender.tag].border.toggle() }
    @objc private func chooseColor(_ sender: NSMenuItem) {
        let mask = masks[sender.tag]
        colorTarget = mask
        let panel = NSColorPanel.shared
        panel.level = .popUpMenu
        panel.color = mask.color
        panel.setTarget(self)
        panel.setAction(#selector(changeColor(_:)))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
    @objc private func setPresetColor(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? NSColor else { return }
        masks[sender.tag].color = color
    }
    @objc private func changeColor(_ sender: NSColorPanel) { colorTarget?.color = sender.color }
    @objc private func toggleClickThrough(_ sender: NSMenuItem) { masks[sender.tag].clickThrough.toggle() }
    @objc private func toggleAll() { hidden.toggle(); refresh() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

if CommandLine.arguments.contains("--self-test") {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let frame = cocoaFrame(CGRect(x: 10, y: 20, width: 100, height: 200), primaryHeight: 900)
    precondition(frame == CGRect(x: 10, y: 680, width: 100, height: 200))
    let sample: [String: Any] = [
        kCGWindowNumber as String: NSNumber(value: 1),
        kCGWindowOwnerPID as String: NSNumber(value: 2),
        kCGWindowLayer as String: NSNumber(value: 0),
        kCGWindowBounds as String: ["X": "-1369", "Y": -1170, "Width": 1920, "Height": 1170]
    ]
    precondition(ScreenWindow(sample)?.frame.minX == -1369)
    let targetFrame = CGRect(x: 100, y: 200, width: 400, height: 600)
    let selectedArea = CGRect(x: 200, y: 260, width: 160, height: 120)
    let region = normalizedRegion(for: selectedArea, in: targetFrame)!
    precondition(regionFrame(region, in: targetFrame) == selectedArea)
    precondition(regionFrame(region, in: CGRect(x: 500, y: 500, width: 800, height: 300))
                 == CGRect(x: 700, y: 530, width: 320, height: 60))
    precondition(normalizedRegion(for: CGRect(x: 2000, y: 2000, width: 20, height: 20), in: targetFrame) == nil)
    let ownerFace = (box: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2), facing: true)
    let visitorFace = (box: CGRect(x: 0.7, y: 0.3, width: 0.24, height: 0.24), facing: true)
    precondition(visitorBoost([ownerFace], ownerIndex: 0) == 0)
    precondition(visitorBoost([visitorFace], ownerIndex: nil) == 1)
    precondition(visitorBoost([visitorFace], ownerIndex: nil, requireFacing: false) == 1)
    precondition(visitorBoost([], ownerIndex: nil) == 0)
    precondition(visitorBoost([ownerFace, visitorFace], ownerIndex: 0) == 1)
    precondition(visitorBoost([ownerFace, visitorFace], ownerIndex: nil) == 1)
    precondition(matchesOwner(faceDistance: 0.8, appearanceDistance: nil, tolerance: 0.9))
    precondition(matchesOwner(faceDistance: 1.0, appearanceDistance: 0.3, tolerance: 0.9))
    precondition(!matchesOwner(faceDistance: 1.1, appearanceDistance: 0.3, tolerance: 0.9))
    precondition(!matchesOwner(faceDistance: nil, appearanceDistance: 0.2, tolerance: 0.9))
    precondition(visitorBoost([ownerFace, (box: visitorFace.box, facing: false)], ownerIndex: 0) == 0)
    precondition(visitorBoost([ownerFace, (box: visitorFace.box, facing: false)], ownerIndex: 0, requireFacing: false) == 1)
    var latch = ThreatLatch()
    precondition(latch.update(facing: 0, present: 1, now: 10) == 0)
    precondition(latch.update(facing: 1, present: 1, now: 11) == 1)
    precondition(latch.update(facing: 0, present: 1, now: 12) == 1)
    precondition(latch.update(facing: 0, present: 0, now: 13) == 1)
    precondition(latch.update(facing: 0, present: 0, now: 15) == 0)
    precondition(facesScreen(yaw: 0.1, pitch: 0.2, bothEyesVisible: true))
    precondition(!facesScreen(yaw: 0.9, pitch: 0, bothEyesVisible: true))
    precondition(!facesScreen(yaw: nil, pitch: nil, bothEyesVisible: false))
    let regionMask = Mask(target: .window(1), name: "영역 검사", frame: CGRect(x: 100, y: 200, width: 200, height: 150))
    regionMask.setEditing(true)
    let movedContent = CGRect(x: 135, y: 235, width: 80, height: 60)
    regionMask.panel.setFrame(regionMask.panel.frameRect(forContentRect: movedContent), display: true)
    regionMask.setEditing(false)
    precondition(regionMask.panel.frame == movedContent)
    regionMask.panel.orderOut(nil)
    let left = subtract(CGRect(x: 0, y: 0, width: 100, height: 100),
                        by: CGRect(x: 25, y: 25, width: 50, height: 50))
    precondition(left.count == 4 && left.reduce(0, { $0 + $1.width * $1.height }) == 7500)
    let mask = Mask(target: .floating, name: "검사")
    mask.visibleRects = left
    mask.opacity = 0.2
    mask.color = .white
    mask.privacyBoost = 0.5
    precondition(abs(mask.tint.opacity - 0.6) < 0.001)
    mask.privacyBoost = 1
    precondition(mask.tint.opacity == 1 && mask.tint.color == .black)
    mask.privacyBoost = 0
    precondition(mask.tint.color == .white)
    mask.panel.orderFrontRegardless()
    precondition(mask.panel.isVisible && mask.panel.ignoresMouseEvents)
    let barOwner = ShadeApp()
    let bar = MaskBar(owner: barOwner)
    precondition(bar.panel.canBecomeKey)
    bar.show(mask, frame: mask.panel.frame)
    precondition(bar.panel.frame.minY >= mask.panel.frame.maxY)
    bar.slider.doubleValue = 1
    precondition(NSApp.sendAction(bar.slider.action!, to: bar.slider.target, from: bar.slider))
    precondition(mask.opacity == 1)
    mask.controlOccluders = [bar.panel.frame]
    bar.show(mask, frame: mask.panel.frame)
    precondition(!bar.panel.isVisible)
    mask.controlOccluders = []
    mask.spotlight = true
    mask.tint.pointer = CGPoint(x: 100, y: 100)
    precondition(mask.tint.spotlight)
    mask.spotlight = false
    precondition(!mask.tint.spotlight)
    let handle = MaskHandle(owner: barOwner, mask: mask)
    handle.place(near: mask.panel.frame)
    precondition(handle.panel.isVisible && handle.panel.frame.minY >= mask.panel.frame.maxY)
    mask.controlOccluders = [handle.panel.frame]
    handle.place(near: mask.panel.frame)
    precondition(!handle.panel.isVisible)
    mask.controlOccluders = []
    handle.hide()
    bar.hide()
    mask.panel.orderOut(nil)
    let shade = ShadeApp()
    shade.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let menu = NSMenu()
    shade.menuWillOpen(menu)
    precondition(menu.items.contains(where: { $0.title == "아이폰 미러링 가리개" }))
    precondition(menu.items.first(where: { $0.title == "카메라 트래킹" })?.submenu?.items.contains(where: { $0.title == "트래킹 켜기" }) == true)
    let mirrorControls = menu.items.first(where: { $0.title.contains("아이폰 미러링") && $0.submenu != nil })?.submenu
    precondition(mirrorControls?.items.contains(where: { $0.title == "표시" }) == true)
    precondition(mirrorControls?.items.contains(where: { $0.title == "카메라 반응" }) == true)
    let trackingItem = mirrorControls!.items.first(where: { $0.title == "카메라 반응" })!
    precondition(NSApp.sendAction(trackingItem.action!, to: trackingItem.target, from: trackingItem))
    let trackingMenu = NSMenu()
    shade.menuWillOpen(trackingMenu)
    let trackingControls = trackingMenu.items.first(where: { $0.title.contains("아이폰 미러링") && $0.submenu != nil })!.submenu!
    precondition(trackingControls.items.first(where: { $0.title == "카메라 반응" })?.state == .on)
    precondition(mirrorControls?.items.contains(where: { $0.title.contains("흐림") }) == false)
    precondition(mirrorControls?.items.compactMap { $0.view?.subviews.first as? NSSlider }.contains(where: { $0.maxValue == 1 }) == true)
    precondition(mirrorControls?.items.first(where: { $0.title == "가리는 영역" })?.submenu?.items.contains(where: { $0.title == "아이폰 화면만 가리기" }) == true)
    precondition(mirrorControls?.items.contains(where: { $0.title == "같은 창에 새 영역 추가" }) == true)
    precondition(mirrorControls?.items.first(where: { $0.title == "가리는 영역" })?.submenu?.items.contains(where: { $0.title == "자유 영역 조절…" }) == true)
    let colors = mirrorControls!.items.first(where: { $0.title == "가리개 색" })!.submenu!
    let navy = colors.items.first(where: { $0.title == "남색" })!
    precondition(NSApp.sendAction(navy.action!, to: navy.target, from: navy))
    let colorMenu = NSMenu()
    shade.menuWillOpen(colorMenu)
    let colorControls = colorMenu.items.first(where: { $0.title.contains("아이폰 미러링") && $0.submenu != nil })!.submenu!
    precondition(colorControls.items.first(where: { $0.title == "가리개 색" })!.submenu!.items.first(where: { $0.title == "남색" })!.state == .on)
    let customColor = colorControls.items.first(where: { $0.title == "가리개 색" })!.submenu!.items.first(where: { $0.title == "더 많은 색…" })!
    precondition(NSApp.sendAction(customColor.action!, to: customColor.target, from: customColor))
    precondition(NSColorPanel.shared.isVisible && NSColorPanel.shared.level == .popUpMenu)
    NSColorPanel.shared.orderOut(nil)
    let showItem = mirrorControls!.items.first(where: { $0.title == "표시" })!
    precondition(NSApp.sendAction(showItem.action!, to: showItem.target, from: showItem))
    let secondMenu = NSMenu()
    shade.menuWillOpen(secondMenu)
    let secondControls = secondMenu.items.first(where: { $0.title.contains("아이폰 미러링") && $0.submenu != nil })!.submenu!
    precondition(secondControls.items.first(where: { $0.title == "표시" })?.state == .off)
    print("창 위치·가리개·메뉴 생성 확인 완료")
} else {
    let app = NSApplication.shared
    let delegate = ShadeApp()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
