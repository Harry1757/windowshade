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
    Float(min(1.25, max(0.25, UserDefaults.standard.object(forKey: "ownerTolerance") as? Double ?? 0.9)))
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

// 다른 사람에게는 더 넓은 각도(limit)를 적용해 곁눈질·고개 돌림도 잡는다.
private func facesScreen(yaw: Double?, pitch: Double?, bothEyesVisible: Bool, limit: Double = 0.65) -> Bool {
    if let yaw, abs(yaw) > limit { return false }
    if let pitch, abs(pitch) > 0.65 { return false }
    return yaw != nil || pitch != nil || bothEyesVisible
}

// 본인 얼굴이 잠깐 오인식돼도 직전 위치·크기와 이어지면 본인으로 본다.
private func continuesOwner(box: CGRect, last: CGRect?, age: CFTimeInterval,
                            distance: Float, tolerance: Float) -> Bool {
    guard let last, age <= 1.5, distance <= tolerance + 0.25 else { return false }
    let ratio = box.width / last.width
    return hypot(box.midX - last.midX, box.midY - last.midY) < 0.12 && ratio > 0.7 && ratio < 1.4
}

// 다른 사람 얼굴이 1초 안에 커지거나(다가옴) 정면으로 돌아오면(고개 돌림) 경보.
private struct VisitorWatch {
    private var history: [(t: CFTimeInterval, box: CGRect, yaw: Double)] = []

    mutating func alarm(_ faces: [(box: CGRect, yaw: Double?)], now: CFTimeInterval) -> Bool {
        history.removeAll { now - $0.t > 1.0 }
        var hit = false
        for face in faces {
            let yaw = abs(face.yaw ?? 0)
            guard let old = history.first(where: {
                hypot($0.box.midX - face.box.midX, $0.box.midY - face.box.midY) < 0.15 }) else { continue }
            let grew = face.box.width >= 0.07 && face.box.width / old.box.width >= 1.2
            let turning = yaw < 1.2 && old.yaw - yaw >= 0.25
            if grew || turning { hit = true }
        }
        history += faces.map { (now, $0.box, abs($0.yaw ?? 0)) }
        return hit
    }
}

private struct Torso {
    let left: CGPoint
    let right: CGPoint

    init(left: CGPoint, right: CGPoint) {
        self.left = left
        self.right = right
    }

    init?(_ pose: VNHumanBodyPoseObservation) {
        guard let left = try? pose.recognizedPoint(.leftShoulder), left.confidence >= 0.2,
              let right = try? pose.recognizedPoint(.rightShoulder), right.confidence >= 0.2 else { return nil }
        self.init(left: left.location, right: right.location)
    }

    var span: CGFloat { abs(left.x - right.x) }
    var order: Int { left.x > right.x ? 1 : -1 }
    var centerX: CGFloat { (left.x + right.x) / 2 }
    var crop: CGRect {
        CGRect(x: min(left.x, right.x) - span * 0.25,
               y: min(left.y, right.y) - span * 1.2,
               width: span * 1.5, height: span * 1.65)
    }

    func containsFace(_ box: CGRect) -> Bool {
        abs(box.midX - centerX) <= span * 0.8 && box.midY >= min(left.y, right.y) - 0.08
    }

    func isCloseAndFront(order expectedOrder: Int, minSpan: CGFloat) -> Bool {
        span >= minSpan && abs(left.y - right.y) <= span * 0.4 &&
            (expectedOrder == 0 || order == expectedOrder)
    }
}

private func bodyProximityThreshold() -> CGFloat {
    CGFloat(min(0.4, max(0.14, UserDefaults.standard.object(forKey: "bodyProximityThreshold") as? Double ?? 0.22)))
}

private func broadUpperBody(_ box: CGRect, confidence: Float, minSpan: CGFloat) -> Bool {
    confidence >= 0.6 && box.width >= max(0.42, minSpan * 1.8) && box.height >= 0.52
}

private func lowerBodyCrop(_ box: CGRect) -> CGRect {
    CGRect(x: box.minX, y: box.minY, width: box.width, height: box.height * 0.65)
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

private struct Edges: OptionSet {
    let rawValue: Int
    static let left = Edges(rawValue: 1)
    static let right = Edges(rawValue: 2)
    static let top = Edges(rawValue: 4)
    static let bottom = Edges(rawValue: 8)
}

private func editedFrame(_ start: CGRect, dx: CGFloat, dy: CGFloat, edges: Edges) -> CGRect {
    var frame = start
    if edges.isEmpty {
        frame.origin.x += dx
        frame.origin.y += dy
        return frame
    }
    let minWidth: CGFloat = 120, minHeight: CGFloat = 60
    if edges.contains(.left) {
        let width = max(minWidth, start.width - dx)
        frame.origin.x = start.minX + start.width - width
        frame.size.width = width
    }
    if edges.contains(.right) { frame.size.width = max(minWidth, start.width + dx) }
    if edges.contains(.bottom) {
        let height = max(minHeight, start.height - dy)
        frame.origin.y = start.minY + start.height - height
        frame.size.height = height
    }
    if edges.contains(.top) { frame.size.height = max(minHeight, start.height + dy) }
    return frame
}

private final class TintView: NSView {
    var color: NSColor = .black { didSet { needsDisplay = true } }
    var opacity: CGFloat = 0.35 { didSet { needsDisplay = true } }
    var spotlight = false { didSet { needsDisplay = true } }
    var spotlightRadius: CGFloat = 70 { didSet { needsDisplay = true } }
    var border = false { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    var editing = false { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var onEditFrameChange: (() -> Void)?
    private var dragEdges: Edges = []
    private var dragStart: (mouse: NSPoint, frame: NSRect)?
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
        if cornerRadius > 0 {
            NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
        }
        if let visibleRects {
            let clip = NSBezierPath()
            for rect in visibleRects { clip.appendRect(rect) }
            clip.addClip()
        }
        color.withAlphaComponent(editing ? min(opacity, 0.3) : opacity).setFill()
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
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2),
                                    xRadius: max(0, cornerRadius - 2), yRadius: max(0, cornerRadius - 2))
            path.lineWidth = 3
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        if editing { drawEditingOverlay() }
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func edges(at point: NSPoint) -> Edges {
        let grab: CGFloat = 14
        var result: Edges = []
        if point.x <= grab { result.insert(.left) }
        if point.x >= bounds.maxX - grab { result.insert(.right) }
        if point.y <= grab { result.insert(.bottom) }
        if point.y >= bounds.maxY - grab { result.insert(.top) }
        return result
    }

    override func mouseDown(with event: NSEvent) {
        guard editing, let window else { return super.mouseDown(with: event) }
        dragEdges = edges(at: convert(event.locationInWindow, from: nil))
        dragStart = (NSEvent.mouseLocation, window.frame)
    }

    override func mouseDragged(with event: NSEvent) {
        guard editing, let window, let start = dragStart else { return }
        let mouse = NSEvent.mouseLocation
        window.setFrame(editedFrame(start.frame, dx: mouse.x - start.mouse.x, dy: mouse.y - start.mouse.y,
                                    edges: dragEdges), display: true)
        onEditFrameChange?()
    }

    override func resetCursorRects() {
        guard editing else { return }
        let grab: CGFloat = 14
        let b = bounds
        addCursorRect(b.insetBy(dx: grab, dy: grab), cursor: .openHand)
        addCursorRect(NSRect(x: grab, y: 0, width: max(0, b.width - 2 * grab), height: grab), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: grab, y: b.maxY - grab, width: max(0, b.width - 2 * grab), height: grab), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: grab, width: grab, height: max(0, b.height - 2 * grab)), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: b.maxX - grab, y: grab, width: grab, height: max(0, b.height - 2 * grab)), cursor: .resizeLeftRight)
        let corners: [(CGFloat, CGFloat)] = [(0, 0), (b.maxX - grab, 0), (0, b.maxY - grab), (b.maxX - grab, b.maxY - grab)]
        for (x, y) in corners { addCursorRect(NSRect(x: x, y: y, width: grab, height: grab), cursor: .crosshair) }
    }

    private func drawEditingOverlay() {
        let accent = NSColor.systemBlue
        accent.setStroke()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
                                   xRadius: max(0, cornerRadius - 1.5), yRadius: max(0, cornerRadius - 1.5))
        outline.lineWidth = 3
        outline.stroke()
        let inset: CGFloat = 8
        let xs = [bounds.minX + inset, bounds.midX, bounds.maxX - inset]
        let ys = [bounds.minY + inset, bounds.midY, bounds.maxY - inset]
        for (column, x) in xs.enumerated() {
            for (row, y) in ys.enumerated() where !(column == 1 && row == 1) {
                let dot = NSBezierPath(ovalIn: CGRect(x: x - 6, y: y - 6, width: 12, height: 12))
                NSColor.white.setFill()
                dot.fill()
                dot.lineWidth = 2
                dot.stroke()
            }
        }
        guard bounds.width >= 280, bounds.height >= 90 else { return }
        let hint = NSAttributedString(string: "끌어서 이동 · 가장자리를 당겨 크기 조절", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white])
        let size = hint.size()
        let pill = CGRect(x: bounds.midX - size.width / 2 - 14, y: bounds.midY - size.height / 2 - 7,
                          width: size.width + 28, height: size.height + 14)
        NSColor(calibratedWhite: 0, alpha: 0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        hint.draw(at: CGPoint(x: pill.minX + 14, y: pill.minY + 7))
    }
}

private final class ChipButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private func chip(_ title: String, symbol: String, fill: NSColor, tip: String,
                  target: AnyObject, action: Selector) -> ChipButton {
    let button = ChipButton()
    button.isBordered = false
    button.wantsLayer = true
    button.layer?.cornerRadius = 8
    button.layer?.backgroundColor = fill.cgColor
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
        .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
    button.imagePosition = .imageLeading
    button.imageHugsTitle = true
    button.alignment = .center
    button.contentTintColor = .white
    button.attributedTitle = NSAttributedString(string: " " + title, attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white])
    button.toolTip = tip
    button.target = target
    button.action = action
    return button
}

private final class EditPanel: NSPanel {
    var onReturn: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?() }
    }
}

private final class Mask: NSObject, NSWindowDelegate {
    enum Target {
        case mirror
        case window(Int)
        case floating
    }

    let target: Target
    let panel: NSPanel
    let tint = TintView()
    weak var owner: ShadeApp?
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
    var cornerRadius: CGFloat = 0 { didSet { tint.cornerRadius = cornerRadius } }
    var contentOnly = false
    var topInset: CGFloat = 40
    var customRegion: CGRect?
    var controlFrame: CGRect { customRegion == nil ? anchorFrame ?? panel.frame : panel.frame }
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
        panel = EditPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.delegate = self
        tint.opacity = opacity
        tint.spotlightRadius = spotlightRadius
        tint.frame = panel.contentView?.bounds ?? frame
        tint.autoresizingMask = [.width, .height]
        panel.contentView = tint
        tint.onEditFrameChange = { [weak self] in self?.syncEditToolbar() }
        (panel as? EditPanel)?.onReturn = { [weak self] in self?.finishEditing() }
    }

    private func updateOpacity() {
        tint.opacity = min(1, opacity + (1 - opacity) * privacyBoost)
        tint.color = privacyBoost > 0 ? .black : color
    }

    func setEditing(_ value: Bool) {
        guard editing != value else { return }
        editing = value
        tint.editing = value
        if value { visibleRects = nil } else { editToolbar.orderOut(nil) }
        panel.ignoresMouseEvents = clickThrough && !value
        panel.orderFrontRegardless()
        syncEditToolbar()
    }

    func syncEditToolbar() {
        guard editing else { return }
        guard panel.isVisible else { editToolbar.orderOut(nil); return }
        let size = editToolbar.frame.size
        let frame = panel.frame
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? frame
        let x = min(max(frame.maxX - size.width, visible.minX + 4), visible.maxX - size.width - 4)
        let y = frame.maxY + size.height + 8 <= visible.maxY ? frame.maxY + 8 : frame.maxY - size.height - 8
        editToolbar.setFrameOrigin(CGPoint(x: x, y: y))
        if !editToolbar.isVisible { editToolbar.orderFrontRegardless() }
    }

    private lazy var editToolbar: NSPanel = {
        let toolbar = ControlPanel(contentRect: NSRect(x: 0, y: 0, width: 250, height: 30),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        toolbar.level = .statusBar
        toolbar.isOpaque = false
        toolbar.backgroundColor = .clear
        toolbar.hasShadow = false
        toolbar.hidesOnDeactivate = false
        toolbar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 30))
        let remove = chip("삭제", symbol: "trash", fill: NSColor.systemRed.withAlphaComponent(0.92),
                          tip: "이 가리개 삭제", target: self, action: #selector(deleteSelf))
        let settings = chip("설정", symbol: "gearshape", fill: NSColor(calibratedWhite: 0.16, alpha: 0.96),
                            tip: "어둡기·색 등 설정", target: self, action: #selector(showSettings(_:)))
        let done = chip("고정", symbol: "checkmark", fill: NSColor.systemGreen,
                        tip: "이 영역으로 고정 (Return)", target: self, action: #selector(finishEditing))
        remove.frame = NSRect(x: 4, y: 2, width: 66, height: 26)
        settings.frame = NSRect(x: 100, y: 2, width: 66, height: 26)
        done.frame = NSRect(x: 174, y: 2, width: 72, height: 26)
        for button in [remove, settings, done] { view.addSubview(button) }
        toolbar.contentView = view
        return toolbar
    }()

    @objc private func deleteSelf() { owner?.deleteMask(self) }
    @objc private func showSettings(_ sender: NSButton) { owner?.showSettings(for: self, at: sender) }
    @objc private func finishEditing() { owner?.finishEditing(self) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        owner?.deleteMask(self)
        return false
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

// 미리보기 창에 보여줄 프레임별 분석 결과.
private struct CameraDebug {
    struct Face { var box: CGRect; var distance: Float?; var owner: Bool; var facing: Bool }
    struct Body { var left: CGPoint; var right: CGPoint; var span: CGFloat; var owner: Bool }
    var faces: [Face]
    var bodies: [Body]
    var boost: CGFloat
    var alarm: Bool
}

extension CameraDebug {
    // 지금 슬라이더 값으로 가려질지 즉시 계산한다(미리보기 전용).
    func verdict(face: Double, body: Double) -> (hidden: Bool, reason: String) {
        for item in faces {
            guard let distance = item.distance, Double(distance) > face else { continue }
            if item.owner { return (true, "내 얼굴이 '남'으로 판단됨 → 선을 오른쪽으로") }
            if item.facing { return (true, "다른 사람이 화면을 보고 있어 가려집니다") }
        }
        if bodies.contains(where: { !$0.owner && Double($0.span) >= body }) {
            return (true, "다른 사람이 가까이 있어 가려집니다")
        }
        if alarm { return (true, "다른 사람이 다가오거나 돌아봐서 가려집니다") }
        return (false, "")
    }
}

private final class CameraGuard: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    var captureSession: AVCaptureSession { session }
    var onDebug: ((CameraDebug) -> Void)?
    private var lastBodies: [CameraDebug.Body] = []
    private let analysisQueue = DispatchQueue(label: "local.windowshade.camera", qos: .userInitiated)
    private var configured = false
    private var starting = false
    private var generation = 0
    private var pendingEnrollment = false
    private var enrollmentRequested = false
    private var lastAnalysis: CFTimeInterval = 0
    private var lastBodyAnalysis: CFTimeInterval = 0
    private var lastBodyCount = 0
    private var threatLatch = ThreatLatch()
    private var visitorWatch = VisitorWatch()
    private var lastOwnerBox: CGRect?
    private var lastOwnerSeen: CFTimeInterval = 0
    private var approachAlarm = false
    private var ownerPrint: VNFeaturePrintObservation?
    private var ownerAppearancePrint: VNFeaturePrintObservation?
    private var ownerTorsoPrint: VNFeaturePrintObservation?
    private var ownerHumanPrint: VNFeaturePrintObservation?
    private var lastAppearanceUpdate: CFTimeInterval = 0
    private var lastOwnerTorsoUpdate: CFTimeInterval = 0
    private var lastOwnerHumanUpdate: CFTimeInterval = 0
    private var ownerShoulderOrder = UserDefaults.standard.integer(forKey: "ownerShoulderOrder")

    private(set) var isEnabled = false
    private(set) var hasOwner: Bool
    private(set) var status: String
    var onBoost: ((CGFloat) -> Void)?
    var onStatus: ((String) -> Void)?
    var onEnrollment: ((Bool) -> Void)?

    override init() {
        hasOwner = false
        status = CommandLine.arguments.contains("--self-test") ? "본인 미등록" : "본인 정보 확인 중"
        super.init()
    }

    func loadOwner() {
        guard !CommandLine.arguments.contains("--self-test"),
              !CommandLine.arguments.contains("--no-keychain") else { return }
        analysisQueue.async { [weak self] in
            guard let self else { return }
            let stored = OwnerFaceStore.load()
            self.ownerPrint = stored
            DispatchQueue.main.async {
                self.hasOwner = stored != nil
                self.updateStatus(stored == nil ? "본인 미등록" : "본인 등록됨 · 꺼짐")
            }
        }
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
            self.visitorWatch = VisitorWatch()
            self.lastOwnerBox = nil
            self.ownerAppearancePrint = nil
            self.ownerTorsoPrint = nil
            self.ownerHumanPrint = nil
            self.lastBodyAnalysis = 0
            self.lastBodyCount = 0
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
                self?.ownerTorsoPrint = nil
                self?.ownerHumanPrint = nil
                self?.ownerShoulderOrder = 0
            }
            UserDefaults.standard.removeObject(forKey: "ownerShoulderOrder")
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
        guard now - lastAnalysis >= 0.2,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = now
        let faceRequest = VNDetectFaceLandmarksRequest()
        let bodyRequest = VNDetectHumanBodyPoseRequest()
        let humanRequest = VNDetectHumanRectanglesRequest()
        humanRequest.upperBodyOnly = true
        let analyzeBodies = now - lastBodyAnalysis >= 0.5
        let requests: [VNRequest] = analyzeBodies ? [faceRequest, bodyRequest, humanRequest] : [faceRequest]
        guard (try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up).perform(requests)) != nil else { return }
        if analyzeBodies {
            lastBodyAnalysis = now
            lastBodyCount = humanRequest.results?.count ?? 0
            lastBodies = []
        }
        let faces = faceRequest.results ?? []

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
                ownerTorsoPrint = nil
                ownerHumanPrint = nil
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
        var ownerIndex: Int?
        var distances = [Float?](repeating: nil, count: faces.count)
        if let ownerPrint, !faces.isEmpty {
            var bestDistance = Float.greatestFiniteMagnitude
            var ownerDirect = false
            let tolerance = ownerTolerance()
            for (index, face) in faces.enumerated() {
                guard let print = featurePrint(for: face, in: pixelBuffer) else { continue }
                var distance: Float = 0
                guard (try? print.computeDistance(&distance, to: ownerPrint)) != nil else { continue }
                distances[index] = distance
                var appearanceDistance: Float?
                if distance > tolerance, distance <= tolerance + 0.15,
                   let ownerAppearancePrint,
                   let appearance = appearancePrint(for: face, in: pixelBuffer) {
                    var value: Float = 0
                    if (try? appearance.computeDistance(&value, to: ownerAppearancePrint)) != nil {
                        appearanceDistance = value
                    }
                }
                let direct = matchesOwner(faceDistance: distance, appearanceDistance: appearanceDistance, tolerance: tolerance)
                let continued = continuesOwner(box: face.boundingBox, last: lastOwnerBox, age: now - lastOwnerSeen,
                                               distance: distance, tolerance: tolerance)
                if direct || continued, distance < bestDistance {
                    bestDistance = distance
                    ownerIndex = index
                    ownerDirect = direct
                }
            }
            if let ownerIndex, ownerDirect {
                lastOwnerBox = faces[ownerIndex].boundingBox
                lastOwnerSeen = now
            }
            if let ownerIndex, bestDistance <= tolerance, now - lastAppearanceUpdate >= 4 {
                ownerAppearancePrint = appearancePrint(for: faces[ownerIndex], in: pixelBuffer)
                lastAppearanceUpdate = now
            }
            // ponytail: Generic image prints can confuse similar faces; use a dedicated face model for stronger identity assurance.
            let observations = faces.enumerated().map {
                (box: $0.element.boundingBox, facing: isFacing($0.element, limit: $0.offset == ownerIndex ? 0.65 : 0.95))
            }
            facingBoost = visitorBoost(observations, ownerIndex: ownerIndex)
            presenceBoost = visitorBoost(observations, ownerIndex: ownerIndex, requireFacing: false)
            let visitors = faces.enumerated().filter { $0.offset != ownerIndex }
                .map { (box: $0.element.boundingBox, yaw: $0.element.yaw?.doubleValue) }
            approachAlarm = visitorWatch.alarm(visitors, now: now)
            if approachAlarm { facingBoost = 1; presenceBoost = 1 }
        }
        if analyzeBodies, ownerPrint != nil {
            let minSpan = bodyProximityThreshold()
            let humans = humanRequest.results ?? []
            var matchedHumans = Set<Int>()
            for pose in bodyRequest.results ?? [] {
                guard let torso = Torso(pose) else { continue }
                guard let humanIndex = humans.indices.first(where: {
                    humans[$0].confidence >= 0.55 && humans[$0].boundingBox.contains(
                        CGPoint(x: torso.centerX, y: (torso.left.y + torso.right.y) / 2))
                }) else { continue }
                matchedHumans.insert(humanIndex)
                let pairedFace = faces.indices.filter { torso.containsFace(faces[$0].boundingBox) }
                    .min { abs(faces[$0].boundingBox.midX - torso.centerX) <
                           abs(faces[$1].boundingBox.midX - torso.centerX) }
                lastBodies.append(.init(left: torso.left, right: torso.right, span: torso.span,
                                        owner: pairedFace != nil && pairedFace == ownerIndex))
                if let ownerIndex, pairedFace == ownerIndex {
                    if isFacing(faces[ownerIndex]), torso.isCloseAndFront(order: 0, minSpan: 0.16) {
                        ownerShoulderOrder = torso.order
                        UserDefaults.standard.set(torso.order, forKey: "ownerShoulderOrder")
                        if now - lastOwnerTorsoUpdate >= 4 {
                            ownerTorsoPrint = imagePrint(for: torso.crop, in: pixelBuffer)
                            lastOwnerTorsoUpdate = now
                        }
                    }
                    if now - lastOwnerHumanUpdate >= 4 {
                        ownerHumanPrint = imagePrint(for: lowerBodyCrop(humans[humanIndex].boundingBox), in: pixelBuffer)
                        lastOwnerHumanUpdate = now
                    }
                    continue
                }
                guard torso.span >= minSpan * 0.65 else { continue }
                if pairedFace == nil, let ownerTorsoPrint,
                   let print = imagePrint(for: torso.crop, in: pixelBuffer) {
                    var distance: Float = 0
                    if (try? print.computeDistance(&distance, to: ownerTorsoPrint)) != nil,
                       distance <= ownerTolerance() * 0.7 { continue }
                }
                presenceBoost = 1
                if torso.isCloseAndFront(order: ownerShoulderOrder, minSpan: minSpan) { facingBoost = 1 }
            }
            // ponytail: A broad upper-body box cannot separate front from back; use a body orientation model if false triggers matter.
            for (index, human) in humans.enumerated() where !matchedHumans.contains(index) {
                let box = human.boundingBox
                guard broadUpperBody(box, confidence: human.confidence, minSpan: minSpan) else { continue }
                let pairedFace = faces.indices.filter { box.contains(CGPoint(x: faces[$0].boundingBox.midX,
                                                                              y: faces[$0].boundingBox.midY)) }
                    .min { abs(faces[$0].boundingBox.midX - box.midX) <
                           abs(faces[$1].boundingBox.midX - box.midX) }
                if let ownerIndex, pairedFace == ownerIndex {
                    if now - lastOwnerHumanUpdate >= 4 {
                        ownerHumanPrint = imagePrint(for: lowerBodyCrop(box), in: pixelBuffer)
                        lastOwnerHumanUpdate = now
                    }
                    continue
                }
                if pairedFace == nil, let ownerHumanPrint,
                   let print = imagePrint(for: lowerBodyCrop(box), in: pixelBuffer) {
                    var distance: Float = 0
                    if (try? print.computeDistance(&distance, to: ownerHumanPrint)) != nil,
                       distance <= ownerTolerance() * 0.7 { continue }
                }
                presenceBoost = 1
                facingBoost = 1
            }
        }
        let target = threatLatch.update(facing: facingBoost, present: presenceBoost, now: now)
        let boost = target
        let faceCount = faces.count
        let bodyCount = lastBodyCount
        if let onDebug {
            let debug = CameraDebug(
                faces: faces.enumerated().map {
                    .init(box: $0.element.boundingBox, distance: distances[$0.offset], owner: $0.offset == ownerIndex,
                          facing: isFacing($0.element, limit: $0.offset == ownerIndex ? 0.65 : 0.95))
                },
                bodies: lastBodies, boost: boost, alarm: approachAlarm)
            DispatchQueue.main.async { onDebug(debug) }
        }
        DispatchQueue.main.async {
            self.onBoost?(boost)
            self.updateStatus(boost > 0.1 ? (self.approachAlarm ? "다른 사람이 다가오거나 돌아봄 · 가리개 강화" : "다른 사람 감지 · 가리개 강화") :
                              self.hasOwner ? "카메라 감지 중 · 얼굴 \(faceCount)명 · 몸 \(bodyCount)명" : "본인 등록이 필요합니다")
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

    private func isFacing(_ face: VNFaceObservation, limit: Double = 0.65) -> Bool {
        facesScreen(yaw: face.yaw?.doubleValue, pitch: face.pitch?.doubleValue,
                    bothEyesVisible: face.landmarks?.leftEye != nil && face.landmarks?.rightEye != nil, limit: limit)
    }

    private func updateStatus(_ value: String) {
        guard status != value else { return }
        status = value
        onStatus?(value)
    }
}

// 기준선을 끌어 조절하는 눈금. 측정값이 마커로 함께 표시된다.
private final class ThresholdMeter: NSView {
    let lo: Double, hi: Double, limitLo: Double, limitHi: Double
    let leftText: String, rightText: String
    let minText: String, maxText: String
    let leftColor: NSColor, rightColor: NSColor
    var threshold: Double { didSet { needsDisplay = true } }
    var markers: [(value: Double, color: NSColor, label: String)] = [] { didSet { needsDisplay = true } }
    var onChange: ((Double) -> Void)?
    private let inset: CGFloat = 14

    init(frame: NSRect, range: ClosedRange<Double>, limits: ClosedRange<Double>, threshold: Double,
         left: (String, NSColor), right: (String, NSColor), ends: (String, String)) {
        lo = range.lowerBound; hi = range.upperBound
        limitLo = limits.lowerBound; limitHi = limits.upperBound
        self.threshold = threshold
        leftText = left.0; leftColor = left.1; rightText = right.0; rightColor = right.1
        minText = ends.0; maxText = ends.1
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    func x(_ value: Double) -> CGFloat {
        inset + CGFloat((min(hi, max(lo, value)) - lo) / (hi - lo)) * (bounds.width - 2 * inset)
    }
    func value(atX x: CGFloat) -> Double {
        let fraction = Double((x - inset) / (bounds.width - 2 * inset))
        return min(limitHi, max(limitLo, lo + fraction * (hi - lo)))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { drag(event) }
    override func mouseDragged(with event: NSEvent) { drag(event) }
    private func drag(_ event: NSEvent) {
        threshold = value(atX: convert(event.locationInWindow, from: nil).x)
        onChange?(threshold)
    }

    private func text(_ string: String, at point: NSPoint, color: NSColor, size: CGFloat = 10.5, centered: Bool = false) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .medium),
                                                         .foregroundColor: color]
        let width = (string as NSString).size(withAttributes: attributes).width
        (string as NSString).draw(at: NSPoint(x: centered ? point.x - width / 2 : point.x, y: point.y), withAttributes: attributes)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bar = NSRect(x: inset, y: 30, width: bounds.width - 2 * inset, height: 20)
        let line = x(threshold)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bar, xRadius: 6, yRadius: 6).addClip()
        leftColor.withAlphaComponent(0.5).setFill()
        NSRect(x: bar.minX, y: bar.minY, width: line - bar.minX, height: bar.height).fill()
        rightColor.withAlphaComponent(0.5).setFill()
        NSRect(x: line, y: bar.minY, width: bar.maxX - line, height: bar.height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let font: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium)]
        let leftWidth = (leftText as NSString).size(withAttributes: font).width
        let rightWidth = (rightText as NSString).size(withAttributes: font).width
        if line - bar.minX >= leftWidth + 24 { text(leftText, at: NSPoint(x: bar.minX + 8, y: bar.minY + 3), color: .white) }
        if bar.maxX - line >= rightWidth + 24 { text(rightText, at: NSPoint(x: bar.maxX - rightWidth - 8, y: bar.minY + 3), color: .white) }
        NSColor.white.setFill()
        NSRect(x: line - 1.5, y: bar.minY - 6, width: 3, height: bar.height + 12).fill()
        NSBezierPath(ovalIn: NSRect(x: line - 8, y: bar.midY - 8, width: 16, height: 16)).fill()
        let dim = NSColor.secondaryLabelColor
        text(minText, at: NSPoint(x: bar.minX, y: 8), color: dim, size: 10.5)
        let maxWidth = (maxText as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium)]).width
        text(maxText, at: NSPoint(x: bar.maxX - maxWidth, y: 8), color: dim, size: 10.5)
        for (index, marker) in markers.enumerated() {
            let center = x(marker.value)
            marker.color.setFill()
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: center - 6, y: bar.maxY + 10))
            triangle.line(to: NSPoint(x: center + 6, y: bar.maxY + 10))
            triangle.line(to: NSPoint(x: center, y: bar.maxY + 1))
            triangle.fill()
            text("\(marker.label) \(String(format: "%.2f", marker.value))",
                 at: NSPoint(x: center, y: bar.maxY + 13 + CGFloat(index % 2) * 13), color: marker.color, centered: true)
        }
    }
}

private final class CameraOverlay: NSView {
    var previewLayer: AVCaptureVideoPreviewLayer?
    var bodyThreshold: CGFloat = 0.22
    var faceThreshold: Double = 0.9 { didSet { needsDisplay = true } }
    var covered = false { didSet { needsDisplay = true } }
    var debug: CameraDebug? { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func label(_ string: String, at point: NSPoint, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                         .foregroundColor: NSColor.white]
        let size = (string as NSString).size(withAttributes: attributes)
        let rect = NSRect(x: point.x, y: point.y, width: size.width + 12, height: size.height + 4)
        color.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        (string as NSString).draw(at: NSPoint(x: rect.minX + 6, y: rect.minY + 2), withAttributes: attributes)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layer = previewLayer, let debug else { return }
        if covered {
            NSColor.black.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30, weight: .heavy),
                                                             .foregroundColor: NSColor.white.withAlphaComponent(0.85)]
            let size = ("가려짐" as NSString).size(withAttributes: attributes)
            ("가려짐" as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                                      withAttributes: attributes)
        }
        for face in debug.faces {
            let rect = layer.layerRectConverted(fromMetadataOutputRect:
                CGRect(x: face.box.minX, y: 1 - face.box.maxY, width: face.box.width, height: face.box.height))
            let ownerNow = face.distance.map { Double($0) <= faceThreshold }
            let color: NSColor = ownerNow == nil ? .systemGray : ownerNow! ? .systemGreen :
                face.facing ? .systemRed : .systemOrange
            color.setStroke()
            let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            path.lineWidth = 3
            path.stroke()
            let look = face.facing ? "화면 봄" : "딴 곳 봄"
            let name = ownerNow == nil ? "얼굴 · \(look)" : ownerNow! ? "나로 인정 · \(look)" :
                face.facing ? "다른 사람 · 화면 봄 → 가림" : "다른 사람 · 딴 곳 봄"
            let suffix = face.distance.map { String(format: " %.2f", $0) } ?? ""
            label(name + suffix, at: NSPoint(x: rect.minX, y: rect.maxY + 4), color: color)
        }
        for body in debug.bodies {
            // 얼굴 상자와 같은 변환을 써서 점 위치를 맞춘다.
            func point(_ p: CGPoint) -> CGPoint {
                layer.layerRectConverted(fromMetadataOutputRect: CGRect(x: p.x, y: 1 - p.y, width: 0, height: 0)).origin
            }
            let a = point(body.left), b = point(body.right)
            let color: NSColor = body.owner ? .systemGreen : body.span >= bodyThreshold ? .systemRed : .systemYellow
            color.setStroke()
            let path = NSBezierPath()
            path.move(to: a); path.line(to: b)
            path.lineWidth = 5
            path.lineCapStyle = .round
            path.stroke()
            color.setFill()
            for end in [a, b] { NSBezierPath(ovalIn: NSRect(x: end.x - 6, y: end.y - 6, width: 12, height: 12)).fill() }
            let near = body.span >= bodyThreshold
            let name = body.owner ? "어깨선 · 본인 몸" : near ? "어깨선 · 다른 사람 · 가까움 → 가림" : "어깨선 · 다른 사람 · 멀리 있음"
            label(String(format: "%@ %.2f", name, body.span), at: NSPoint(x: (a.x + b.x) / 2 - 34, y: min(a.y, b.y) - 24), color: color)
        }
    }
}

// 카메라가 실제로 보는 것과 판별 기준을 한 화면에서 보며 조절하는 창.
private final class CameraPreviewPanel: NSPanel, NSWindowDelegate {
    private let camera: CameraGuard
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let overlay = CameraOverlay()
    private let status = NSTextField(labelWithString: "")
    private let faceMeter: ThresholdMeter
    private let bodyMeter: ThresholdMeter
    private var timer: Timer?
    private var startedCamera = false
    private var lastDebug: CameraDebug?
    private let faceTitle = NSTextField(labelWithString: "")
    private let bodyTitle = NSTextField(labelWithString: "")
    var onClose: (() -> Void)?

    init(camera: CameraGuard) {
        self.camera = camera
        previewLayer = AVCaptureVideoPreviewLayer(session: camera.captureSession)
        faceMeter = ThresholdMeter(frame: NSRect(x: 20, y: 0, width: 480, height: 96), range: 0.25...1.25,
                                   limits: 0.25...1.25, threshold: Double(ownerTolerance()),
                                   left: ("← 나 · 안 가림", .systemGreen), right: ("남 · 가림 →", .systemRed),
                                   ends: ("0.25 · 가장 까다롭게", "1.25 · 가장 너그럽게"))
        bodyMeter = ThresholdMeter(frame: NSRect(x: 20, y: 0, width: 480, height: 96), range: 0.14...0.4,
                                   limits: 0.14...0.4, threshold: Double(bodyProximityThreshold()),
                                   left: ("← 멀리 · 안 가림", .systemGray), right: ("가까이 · 가림 →", .systemRed),
                                   ends: ("0.14 · 멀리 있어도 가림", "0.40 · 바짝 와야 가림"))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "카메라 트래킹 미리보기"
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        delegate = self

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 700))
        func caption(_ head: NSTextField, _ detail: String, y: CGFloat) {
            head.font = .systemFont(ofSize: 13, weight: .bold)
            head.frame = NSRect(x: 20, y: y + 17, width: 480, height: 18)
            let body = NSTextField(labelWithString: detail)
            body.font = .systemFont(ofSize: 11.5)
            body.textColor = .secondaryLabelColor
            body.frame = NSRect(x: 20, y: y, width: 480, height: 16)
            content.addSubview(head)
            content.addSubview(body)
        }
        var y: CGFloat = 12
        bodyMeter.frame.origin.y = y; content.addSubview(bodyMeter); y += 96
        caption(bodyTitle, "오른쪽 = 아주 가까워야 가림 · 왼쪽 = 멀리 있어도 가림", y: y); y += 40
        faceMeter.frame.origin.y = y; content.addSubview(faceMeter); y += 96
        caption(faceTitle, "오른쪽 = 너그럽게(웬만하면 나로 인정) · 왼쪽 = 까다롭게(낯선 얼굴을 잘 가림)", y: y); y += 42
        let legend = NSTextField(wrappingLabelWithString: "네모 = 얼굴 인식 · 선 = 어깨선(몸 감지) · 초록 = 본인\n빨강 = 가림 대상 · 주황 = 딴 곳 보는 다른 사람 · 노랑 = 멀리 있는 몸")
        legend.font = .systemFont(ofSize: 11)
        legend.textColor = .secondaryLabelColor
        legend.frame = NSRect(x: 20, y: y, width: 480, height: 32)
        content.addSubview(legend)
        y += 38
        refreshTitles()
        let preview = NSView(frame: NSRect(x: 20, y: y, width: 480, height: 290))
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.black.cgColor
        preview.layer?.cornerRadius = 10
        preview.layer?.masksToBounds = true
        previewLayer.videoGravity = .resizeAspect
        previewLayer.frame = preview.bounds
        preview.layer?.addSublayer(previewLayer)
        content.addSubview(preview)
        overlay.frame = preview.frame
        overlay.previewLayer = previewLayer
        content.addSubview(overlay)
        y += 298
        status.font = .systemFont(ofSize: 14, weight: .bold)
        status.frame = NSRect(x: 20, y: y, width: 480, height: 22)
        content.addSubview(status)
        y += 34
        content.frame.size.height = y
        contentView = content
        setContentSize(NSSize(width: 520, height: y))

        overlay.bodyThreshold = CGFloat(bodyMeter.threshold)
        overlay.faceThreshold = faceMeter.threshold
        faceMeter.onChange = { [weak self] in
            UserDefaults.standard.set($0, forKey: "ownerTolerance")
            self?.overlay.faceThreshold = $0
            self?.refreshTitles()
            self?.refreshLive()
        }
        bodyMeter.onChange = { [weak self] in
            UserDefaults.standard.set($0, forKey: "bodyProximityThreshold")
            self?.overlay.bodyThreshold = CGFloat($0)
            self?.refreshTitles()
            self?.refreshLive()
        }
    }

    func present() {
        startedCamera = !camera.isEnabled
        if startedCamera { camera.start() }
        camera.onDebug = { [weak self] in self?.update($0) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.mirrorPreview()
            guard let self, self.overlay.debug == nil else { return }
            self.show(self.camera.status, .secondaryLabelColor)
        }
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    private func refreshTitles() {
        faceTitle.stringValue = String(format: "① 본인 인식 기준 · 현재 %.2f", faceMeter.threshold)
        bodyTitle.stringValue = String(format: "② 다가옴 감지 거리 · 현재 %.2f", bodyMeter.threshold)
    }

    // 거울처럼 좌우를 뒤집어 보여준다. 연결은 카메라가 시작된 뒤에 생기므로 매번 확인한다.
    private func mirrorPreview() {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported,
              !connection.isVideoMirrored || connection.automaticallyAdjustsVideoMirroring else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }

    private func show(_ text: String, _ color: NSColor) {
        status.stringValue = "● " + text
        status.textColor = color
    }

    // 기준선을 끄는 즉시 마지막 프레임을 새 기준으로 다시 판정해 보여준다.
    private func refreshLive() { if let lastDebug { update(lastDebug) } }

    private func update(_ debug: CameraDebug) {
        lastDebug = debug
        mirrorPreview()
        overlay.debug = debug
        let verdict = debug.verdict(face: faceMeter.threshold, body: bodyMeter.threshold)
        overlay.covered = verdict.hidden
        faceMeter.markers = debug.faces.compactMap { face in
            face.distance.map { distance in
                let mine = Double(distance) <= faceMeter.threshold
                return (Double(distance), mine ? NSColor.systemGreen : NSColor.systemRed, mine ? "나" : "타인")
            }
        }
        bodyMeter.markers = debug.bodies.map { (Double($0.span), $0.owner ? NSColor.systemGreen : Double($0.span) >= Double(overlay.bodyThreshold) ? NSColor.systemRed : NSColor.systemYellow, $0.owner ? "본인" : "타인") }
        if !camera.hasOwner { show("본인이 등록되지 않았습니다 — ◐ → 카메라 트래킹 → 나로 지정…", .systemOrange) }
        else if verdict.hidden { show("가려짐 — " + verdict.reason, .systemRed) }
        else if debug.faces.isEmpty { show("얼굴이 보이지 않습니다", .secondaryLabelColor) }
        else if debug.faces.contains(where: { !$0.owner && ($0.distance.map { Double($0) <= faceMeter.threshold } ?? false) }) {
            show("안 가려짐 — 다른 얼굴도 '나'로 인정됨 → 선을 왼쪽으로", .systemOrange)
        } else { show("안 가려짐 — 본인만 보입니다", .systemGreen) }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        camera.onDebug = nil
        if startedCamera { camera.stop() }
        onClose?()
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
    let settingsButton = NSButton()
    let deleteButton = NSButton()
    let closeButton = NSButton()
    weak var owner: ShadeApp?
    weak var mask: Mask?
    private let barWidth: CGFloat = 330
    private let barHeight: CGFloat = 50

    init(owner: ShadeApp) {
        self.owner = owner
        panel = ControlPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 50),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = NSView(frame: NSRect(x: 0, y: 0, width: barWidth, height: barHeight))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96).cgColor
        content.layer?.cornerRadius = 12
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.28).cgColor
        let buttons: [(NSButton, String, String, Selector)] = [
            (spotlightButton, "cursorarrow.rays", "마우스 주변 밝게", #selector(toggleSpotlight)),
            (settingsButton, "gearshape", "가리개 설정", #selector(showSettings)),
            (deleteButton, "trash", "이 가리개 삭제", #selector(deleteMask)),
            (closeButton, "chevron.up", "조절 바 접기", #selector(closeBar))
        ]
        let start = barWidth - CGFloat(buttons.count) * 36 - 6
        slider.frame = CGRect(x: 16, y: 13, width: start - 26, height: 24)
        slider.minValue = 0.05
        slider.maxValue = 1
        slider.isContinuous = true
        slider.toolTip = "어둡기 · 오른쪽 끝은 완전히 가림"
        slider.target = self
        slider.action = #selector(changeOpacity(_:))
        content.addSubview(slider)
        for (index, (button, symbol, tip, action)) in buttons.enumerated() {
            button.frame = CGRect(x: start + CGFloat(index) * 36, y: 9, width: 32, height: 32)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
            button.toolTip = tip
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.09).cgColor
            button.contentTintColor = symbol == "trash" ? NSColor(calibratedRed: 1, green: 0.45, blue: 0.42, alpha: 1) : .white
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
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? frame
        let x = min(max(frame.maxX - barWidth - 4, visible.minX + 4), visible.maxX - barWidth - 4)
        let y = frame.maxY + barHeight + 6 <= visible.maxY - 4 ? frame.maxY + 6 : frame.maxY - barHeight - 4
        let barFrame = CGRect(x: x, y: y, width: barWidth, height: barHeight)
        if mask.controlOccluders.contains(where: { $0.intersects(barFrame) }) { hide(); return }
        if panel.frame != barFrame { panel.setFrame(barFrame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() { panel.orderOut(nil); mask = nil }

    @objc private func changeOpacity(_ sender: NSSlider) {
        guard let mask else { return }
        owner?.setOpacity(mask, value: sender.doubleValue)
    }
    @objc private func toggleSpotlight() { if let mask { owner?.toggleSpotlightFor(mask) } }
    @objc private func closeBar() { owner?.closeBar() }
    @objc private func deleteMask() { if let mask { owner?.deleteMask(mask) } }
    @objc private func showSettings() {
        guard let mask else { return }
        owner?.showSettings(for: mask, at: settingsButton)
    }
}

private final class MaskHandle: NSObject {
    let panel: NSPanel
    weak var owner: ShadeApp?
    weak var mask: Mask?
    private let size: CGFloat = 36

    init(owner: ShadeApp, mask: Mask) {
        self.owner = owner
        self.mask = mask
        panel = ControlPanel(contentRect: NSRect(x: 0, y: 0, width: 36, height: 36),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let button = ChipButton(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "가리개 조절 열기")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        button.toolTip = "클릭해서 이 가리개 조절"
        button.isBordered = false
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96).cgColor
        button.layer?.cornerRadius = 10
        button.layer?.borderWidth = 1.5
        button.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.55).cgColor
        button.target = self
        button.action = #selector(openBar)
        panel.contentView = button
    }

    func place(near frame: CGRect) {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? frame
        let x = min(max(frame.maxX - size, visible.minX + 4), visible.maxX - size - 4)
        let y = frame.maxY + size + 4 <= visible.maxY - 4 ? frame.maxY + 4 : frame.maxY - size - 4
        let position = CGRect(x: x, y: y, width: size, height: size)
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
    private var cameraPreview: CameraPreviewPanel?
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
        cameraGuard.loadOwner()

        let mirror = Mask(target: .mirror, name: "아이폰 미러링")
        mirror.owner = self
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
                let area = maskArea(mask, in: target.frame)
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
            mask.syncEditToolbar()
            let id = ObjectIdentifier(mask)
            let handle = handles[id] ?? MaskHandle(owner: self, mask: mask)
            handles[id] = handle
            guard !hidden, mask.enabled, mask.panel.isVisible, !mask.editing else { handle.hide(); continue }
            if bar.mask === mask && bar.panel.isVisible {
                handle.hide()
                bar.show(mask, frame: mask.controlFrame)
            } else {
                handle.place(near: mask.controlFrame)
            }
        }
        if let mask = bar.mask, hidden || !mask.enabled || !mask.panel.isVisible { bar.hide() }
    }

    func toggleBar(for mask: Mask) {
        if bar.mask === mask && bar.panel.isVisible { bar.hide() }
        else { bar.show(mask, frame: mask.controlFrame) }
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
        menu.addItem(item("현재 창 전체 가리기", #selector(addCurrentWindow)))
        menu.addItem(item("현재 창 일부만 가리기…", #selector(addCurrentWindowRegion)))
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
        cameraMenu.addItem(item("미리보기로 보며 조절…", #selector(openCameraPreview)))
        cameraMenu.addItem(disabledLabel("① 본인 인식 기준 · 왼쪽=엄격"))
        cameraMenu.addItem(sliderItem(Double(ownerTolerance()), 0.55, 1.25, 0, #selector(changeOwnerTolerance(_:))))
        cameraMenu.addItem(disabledLabel("② 다가옴 감지 거리 · 왼쪽=멀리서 반응"))
        cameraMenu.addItem(sliderItem(Double(bodyProximityThreshold()), 0.14, 0.4, 0, #selector(changeBodyProximity(_:))))
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
            submenu.addItem(disabledLabel("모서리 둥글기 · 0은 각진 모서리"))
            submenu.addItem(sliderItem(Double(mask.cornerRadius), 0, 28, index, #selector(changeCornerRadius(_:))))
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
                let editRegion = item(mask.editing ? "✓ 이 영역으로 고정" : "영역 직접 조절…", #selector(toggleEditing(_:)))
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
                let edit = item(mask.editing ? "✓ 이 위치로 고정" : "위치·크기 조절", #selector(toggleEditing))
                edit.tag = index
                submenu.addItem(edit)
            }
            if case .mirror = mask.target {
            } else {
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

    @objc private func selectMirror() {
        let mirror: Mask
        if let existing = masks.first(where: { if case .mirror = $0.target { true } else { false } }) {
            mirror = existing
        } else {
            mirror = Mask(target: .mirror, name: "아이폰 미러링")
            mirror.owner = self
            mirror.contentOnly = true
            mirror.opacity = CGFloat(UserDefaults.standard.double(forKey: "mirrorOpacity"))
            if mirror.opacity == 0 { mirror.opacity = 0.35 }
            masks.insert(mirror, at: 0)
        }
        selected = mirror
        mirror.enabled = true
        hidden = false
        refresh()
    }
    @objc private func selectMask(_ sender: NSMenuItem) { selected = masks[sender.tag] }
    @objc private func toggleMask(_ sender: NSMenuItem) {
        let mask = masks[sender.tag]
        mask.enabled.toggle()
        if !mask.enabled && bar.mask === mask { bar.hide() }
        refresh()
    }

    private func maskArea(_ mask: Mask, in target: CGRect) -> CGRect {
        let top = mask.contentOnly ? min(mask.topInset, target.height - 1) : 0
        return mask.customRegion.map { regionFrame($0, in: target) }
            ?? CGRect(x: target.minX, y: target.minY + top, width: target.width, height: target.height - top)
    }

    private func beginEditing(_ mask: Mask) {
        mask.enabled = true
        hidden = false
        refresh()
        if let anchor = mask.anchorFrame {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let area = maskArea(mask, in: quartzFrame(anchor, primaryHeight: primaryHeight))
            mask.panel.setFrame(cocoaFrame(area, primaryHeight: primaryHeight), display: true)
        }
        mask.setEditing(true)
        if bar.mask === mask { bar.hide() }
        refreshControls()
        NSApp.activate(ignoringOtherApps: true)
        mask.panel.makeKey()
    }

    @discardableResult
    private func attachCurrentWindow() -> Mask? {
        let candidates = visibleWindows().filter {
            $0.pid != getpid() && NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier != mirrorBundleID
        }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let window = candidates.first { $0.pid == frontPID } ?? candidates.first
        guard let window else { NSSound.beep(); return nil }
        let mask = Mask(target: .window(window.id), name: window.displayName)
        mask.owner = self
        masks.append(mask)
        selected = mask
        refresh()
        return mask
    }

    @objc private func addCurrentWindow() { attachCurrentWindow() }

    @objc private func addCurrentWindowRegion() {
        guard let mask = attachCurrentWindow() else { return }
        mask.customRegion = CGRect(x: 0.15, y: 0.2, width: 0.7, height: 0.5)
        beginEditing(mask)
    }

    @objc private func addChosenWindow(_ sender: NSMenuItem) {
        guard let window = visibleWindows().first(where: { $0.id == sender.tag }) else { NSSound.beep(); return }
        let mask = Mask(target: .window(window.id), name: window.displayName)
        mask.owner = self
        masks.append(mask)
        selected = mask
        refresh()
    }

    @objc private func addFloating() {
        let mask = Mask(target: .floating, name: "떠 있는 가리개 \(masks.count)")
        mask.owner = self
        masks.append(mask)
        selected = mask
        beginEditing(mask)
    }

    @objc private func addRegionSameWindow(_ sender: NSMenuItem) {
        let source = masks[sender.tag]
        if case .floating = source.target { return }
        let baseName = source.name.components(separatedBy: " · 영역").first ?? source.name
        let count = masks.filter { $0.name.hasPrefix(baseName + " · 영역") }.count + 1
        let mask = Mask(target: source.target, name: "\(baseName) · 영역 \(count)")
        mask.owner = self
        mask.customRegion = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.35)
        mask.opacity = source.opacity
        mask.color = source.color
        masks.append(mask)
        selected = mask
        beginEditing(mask)
    }

    @objc private func toggleEditing(_ sender: NSMenuItem) {
        let mask = masks[sender.tag]
        if mask.editing {
            finishEditing(mask)
        } else {
            beginEditing(mask)
        }
    }

    @objc private func removeMask(_ sender: NSMenuItem) {
        guard masks.indices.contains(sender.tag) else { return }
        deleteMask(masks[sender.tag])
    }

    func deleteMask(_ mask: Mask) {
        guard let index = masks.firstIndex(where: { $0 === mask }) else { return }
        masks.remove(at: index)
        mask.setEditing(false)
        mask.panel.orderOut(nil)
        if bar.mask === mask { bar.hide() }
        if colorTarget === mask { colorTarget = nil; NSColorPanel.shared.orderOut(nil) }
        if selected === mask { selected = masks.first }
        refresh()
    }

    func finishEditing(_ mask: Mask) {
        guard mask.editing else { return }
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
    }

    @objc private func changeOpacity(_ slider: NSSlider) { setOpacity(masks[slider.tag], value: slider.doubleValue) }

    func setOpacity(_ mask: Mask, value: Double) {
        mask.opacity = CGFloat(value)
        if case .mirror = mask.target { UserDefaults.standard.set(value, forKey: "mirrorOpacity") }
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

    @objc private func changeCornerRadius(_ slider: NSSlider) {
        masks[slider.tag].cornerRadius = CGFloat(slider.doubleValue.rounded())
    }
    @objc private func changeSpotlightRadius(_ slider: NSSlider) {
        masks[slider.tag].spotlightRadius = CGFloat(slider.doubleValue)
    }
    @objc private func openCameraPreview() {
        if let panel = cameraPreview {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = CameraPreviewPanel(camera: cameraGuard)
        panel.onClose = { [weak self] in self?.cameraPreview = nil }
        cameraPreview = panel
        panel.present()
    }
    @objc private func toggleCameraTracking() {
        if cameraGuard.isEnabled { cameraGuard.stop() } else { cameraGuard.start() }
    }
    @objc private func changeOwnerTolerance(_ slider: NSSlider) {
        UserDefaults.standard.set(slider.doubleValue, forKey: "ownerTolerance")
    }
    @objc private func changeBodyProximity(_ slider: NSSlider) {
        UserDefaults.standard.set(slider.doubleValue, forKey: "bodyProximityThreshold")
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
    let editBase = CGRect(x: 100, y: 100, width: 300, height: 200)
    precondition(editedFrame(editBase, dx: 20, dy: -10, edges: []) == CGRect(x: 120, y: 90, width: 300, height: 200))
    precondition(editedFrame(editBase, dx: 50, dy: 0, edges: .right) == CGRect(x: 100, y: 100, width: 350, height: 200))
    precondition(editedFrame(editBase, dx: 50, dy: 0, edges: .left) == CGRect(x: 150, y: 100, width: 250, height: 200))
    precondition(editedFrame(editBase, dx: 500, dy: 0, edges: .left) == CGRect(x: 280, y: 100, width: 120, height: 200))
    precondition(editedFrame(editBase, dx: 0, dy: 30, edges: .top) == CGRect(x: 100, y: 100, width: 300, height: 230))
    precondition(editedFrame(editBase, dx: 0, dy: 500, edges: .bottom) == CGRect(x: 100, y: 240, width: 300, height: 60))
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
    let meter = ThresholdMeter(frame: NSRect(x: 0, y: 0, width: 528, height: 96), range: 0...1, limits: 0.2...0.8,
                               threshold: 0.5, left: ("", .green), right: ("", .red), ends: ("", ""))
    precondition(abs(meter.value(atX: 264) - 0.5) < 0.001 && meter.value(atX: 0) == 0.2 && meter.value(atX: 600) == 0.8)
    precondition(!facesScreen(yaw: 0.8, pitch: 0, bothEyesVisible: true))
    precondition(facesScreen(yaw: 0.8, pitch: 0, bothEyesVisible: true, limit: 0.95))
    let ob = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
    precondition(continuesOwner(box: ob.offsetBy(dx: 0.05, dy: 0), last: ob, age: 1, distance: 1.05, tolerance: 0.9))
    precondition(!continuesOwner(box: ob.offsetBy(dx: 0.05, dy: 0), last: ob, age: 2, distance: 1.05, tolerance: 0.9))
    precondition(!continuesOwner(box: ob.offsetBy(dx: 0.3, dy: 0), last: ob, age: 1, distance: 1.05, tolerance: 0.9))
    precondition(!continuesOwner(box: ob, last: ob, age: 1, distance: 1.3, tolerance: 0.9))
    precondition(!continuesOwner(box: ob, last: nil, age: 0, distance: 0.5, tolerance: 0.9))
    var watch = VisitorWatch()
    let vbox = CGRect(x: 0.7, y: 0.3, width: 0.1, height: 0.1)
    precondition(!watch.alarm([(vbox, 1.1)], now: 1))
    precondition(!watch.alarm([(vbox, 1.05)], now: 1.4))
    precondition(watch.alarm([(vbox, 0.7)], now: 1.8))
    var watch2 = VisitorWatch()
    precondition(!watch2.alarm([(vbox, 1.5)], now: 5))
    precondition(watch2.alarm([(CGRect(x: 0.68, y: 0.28, width: 0.13, height: 0.13), 1.5)], now: 5.5))
    var watch3 = VisitorWatch()
    precondition(!watch3.alarm([(vbox, 0.1)], now: 9))
    precondition(!watch3.alarm([(vbox, 0.1)], now: 9.6))
    let frontTorso = Torso(left: CGPoint(x: 0.68, y: 0.55), right: CGPoint(x: 0.32, y: 0.54))
    precondition(frontTorso.isCloseAndFront(order: 1, minSpan: 0.22))
    precondition(frontTorso.containsFace(CGRect(x: 0.45, y: 0.6, width: 0.1, height: 0.15)))
    precondition(!frontTorso.containsFace(CGRect(x: 0.8, y: 0.6, width: 0.1, height: 0.15)))
    precondition(!frontTorso.isCloseAndFront(order: -1, minSpan: 0.22))
    precondition(!Torso(left: CGPoint(x: 0.52, y: 0.55), right: CGPoint(x: 0.43, y: 0.54))
        .isCloseAndFront(order: 1, minSpan: 0.22))
    precondition(!Torso(left: CGPoint(x: 0.68, y: 0.75), right: CGPoint(x: 0.32, y: 0.45))
        .isCloseAndFront(order: 1, minSpan: 0.22))
    precondition(broadUpperBody(CGRect(x: 0.14, y: 0, width: 0.72, height: 0.99), confidence: 0.71, minSpan: 0.22))
    precondition(!broadUpperBody(CGRect(x: 0.3, y: 0.2, width: 0.25, height: 0.5), confidence: 0.8, minSpan: 0.22))
    precondition(!broadUpperBody(CGRect(x: 0.14, y: 0, width: 0.72, height: 0.99), confidence: 0.2, minSpan: 0.22))
    let regionMask = Mask(target: .window(1), name: "영역 검사", frame: CGRect(x: 100, y: 200, width: 200, height: 150))
    regionMask.setEditing(true)
    let movedContent = CGRect(x: 135, y: 235, width: 80, height: 60)
    regionMask.panel.setFrame(regionMask.panel.frameRect(forContentRect: movedContent), display: true)
    regionMask.setEditing(false)
    precondition(regionMask.panel.frame == movedContent)
    regionMask.anchorFrame = CGRect(x: 100, y: 200, width: 400, height: 300)
    regionMask.customRegion = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
    precondition(regionMask.controlFrame == movedContent)
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
    precondition(mirrorControls?.items.contains(where: { $0.title.contains("모서리 둥글기") }) == true)
    precondition(mirrorControls?.items.first(where: { $0.title == "가리는 영역" })?.submenu?.items.contains(where: { $0.title == "영역 직접 조절…" }) == true)
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















