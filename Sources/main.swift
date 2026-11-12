// SidecarPortrait
// 사이드카 아이패드를 세로로 쓰기 위한 메뉴 막대 앱.
//
// 동작 방식:
//   1. 사이드카 화면의 가로·세로를 뒤바꾼 크기로 가상 디스플레이를 만든다.
//   2. 그 가상 디스플레이를 ScreenCaptureKit으로 캡처한다.
//   3. 캡처한 화면을 90도 돌려 사이드카 화면 위에 전체 화면 창으로 띄운다.
// 사용자는 가상 디스플레이("iPad Portrait")를 일반 모니터처럼 쓰면 된다.
//
// 파일 구성: main.swift(앱 본체), SettingsView.swift(설정 값·설정 패널), StatusIcon.swift(메뉴 막대 아이콘)

import Cocoa
import CoreMedia
import CoreVideo
import IOSurface
import ScreenCaptureKit
import SwiftUI

// MARK: - 로그

private let logQueue = DispatchQueue(label: "log")
private let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/SidecarPortrait.log")

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    logQueue.async {
        guard let data = line.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

// MARK: - 앱

final class AppDelegate: NSObject, NSApplicationDelegate, SCStreamOutput, SCStreamDelegate {
    private let settings = AppSettings()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()

    private var virtualDisplay: CGVirtualDisplay?
    private var virtualID: CGDirectDisplayID = 0
    private var targetID: CGDirectDisplayID = 0
    /// 아이패드 패널의 실제 픽셀 크기(세로 방향 기준). 캡처 결과는 항상 이 크기로 받는다.
    private var pixelSize = (width: 0, height: 0)
    /// 배율 1.0일 때 가상 디스플레이의 포인트 크기와 레티나 배수
    private var basePoints = (width: 0, height: 0)
    private var backingScale = 2
    /// 앱이 배치를 바꾸기 전에 사이드카가 있던 쪽("자동" 위치에 쓴다)
    private var originalSide = Placement.left

    private var stream: SCStream?
    private var startingCapture = false
    private var requestedAccess = false
    private let captureQueue = DispatchQueue(label: "capture", qos: .userInteractive)
    private var frameCount = 0

    private var window: NSWindow?
    private let mirrorLayer = CALayer()

    private var busy = false
    private var lastScreenSummary = ""

    /// 캡처에서 빼고 있는 것: 메뉴 막대를 빼는지, 함께 빼는 창 제목 막대 창들. nil이면 다시 적용해야 한다.
    private struct BarState: Equatable {
        var hide = false
        var titleBars: [CGWindowID] = []
    }
    private var barState: BarState? = BarState()
    private var signalSources: [DispatchSourceSignal] = []
    private var dumpCount = 0
    /// 방금 그린 것과 같은 표면이 다시 들어온 횟수(화면이 갱신되지 않는 문제 추적용)
    private var sameSurfaceCount = 0

    // MARK: 시작·종료

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("launch pid=\(ProcessInfo.processInfo.processIdentifier)")

        if let button = statusItem.button {
            button.image = StatusIcon.image(active: false)
            button.toolTip = "Sidecar Portrait"
            button.target = self
            button.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        let hosting = NSHostingController(rootView: SettingsView(settings: settings))
        // 내용 크기가 바뀌면(상태 문구가 길어지는 등) 패널 크기도 따라가게 한다.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        settings.onChange = { [weak self] change in
            // 화면 갱신 도중에 다시 값을 바꾸지 않도록 한 박자 늦춘다.
            DispatchQueue.main.async { self?.settingsChanged(change) }
        }

        mirrorLayer.contentsGravity = .resize
        mirrorLayer.backgroundColor = NSColor.black.cgColor

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // 마우스가 가려진 사이드카 화면으로 넘어가면 가상 디스플레이로 되돌린다.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in self?.mouseMoved() }
        NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.mouseMoved()
            return event
        }

        installDiagnosticsSignals()
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.updateBarHiding() }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.evaluate() }
        evaluate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        teardown()
        log("terminate")
    }

    @objc private func screensChanged() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(evaluate), object: nil)
        perform(#selector(evaluate), with: nil, afterDelay: 0.7)
    }

    // MARK: 설정 패널

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        // 띄우기 전에 실제 내용 크기를 알려 준다. 그러지 않으면 작은 크기로 위치를 잡은 뒤
        // 내용만큼 위로 자라나서 패널 위쪽이 화면 밖으로 잘린다.
        if let view = popover.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            let size = view.fittingSize
            if size.width > 0, size.height > 0 { popover.contentSize = size }
        }
        NSApp.activate(ignoringOtherApps: true)   // 바깥을 누르면 닫히게 하려면 앱이 활성 상태여야 한다
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        logPopoverFrame("shown")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.logPopoverFrame("settled") }
    }

    /// 패널이 화면 안에 다 들어왔는지 확인할 수 있게 위치를 기록한다.
    private func logPopoverFrame(_ label: String) {
        guard let window = popover.contentViewController?.view.window else { return }
        let visible = window.screen?.visibleFrame ?? .zero
        let overflow = window.frame.maxY - visible.maxY
        log("popover \(label): frame=\(window.frame) content=\(popover.contentSize) screenVisible=\(visible) button=\(statusItem.button?.window?.frame ?? .zero) overflowTop=\(overflow)")
    }

    private func settingsChanged(_ change: AppSettings.Change) {
        switch change {
        case .enabled:
            log("enabled=\(settings.enabled)")
            evaluate()
        case .rotation:
            log("flipped=\(settings.flipped)")
            layoutMirror()
        case .resolution:
            log("resolution scale=\(settings.resolutionScale)")
            reconfigure(reapplyingModes: true)
        case .placement:
            log("placement=\(settings.placement.rawValue)")
            reconfigure(reapplyingModes: false)
        }
    }

    /// 동작 중에 해상도나 위치가 바뀌면 가상 디스플레이는 그대로 두고 설정만 다시 적용한다.
    private func reconfigure(reapplyingModes: Bool) {
        guard virtualDisplay != nil else { return }
        if busy {
            // 다른 설정을 적용하는 중이면 끝난 뒤에 다시 시도한다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
                self?.reconfigure(reapplyingModes: reapplyingModes)
            }
            return
        }
        if reapplyingModes {
            busy = true
            stream?.stopCapture(completionHandler: nil)
            stream = nil
            let applied = applyModes()
            log("re-apply modes applySettings=\(applied)")
            finishConfiguration(showingWindow: false)
        } else {
            let pixels = virtualPixels(for: settings.resolutionScale)
            configureDisplays(pixelW: pixels.width, pixelH: pixels.height, scale: backingScale)
        }
    }

    private func setStatus(_ text: String, _ state: RunState) {
        guard settings.statusText != text || settings.state != state else { return }
        settings.statusText = text
        settings.state = state
        statusItem.button?.image = StatusIcon.image(active: state == .active)
        log("status: \(text)")
    }

    /// 설정 패널에 보여 줄 해상도별 실제 크기
    private func publishResolutionSizes() {
        guard basePoints.width > 0 else { return }
        settings.resolutionSizes = AppSettings.resolutionOptions.map {
            let pixels = virtualPixels(for: $0)
            return "\(pixels.width / backingScale)×\(pixels.height / backingScale)"
        }
    }

    /// 주어진 배율에서 가상 디스플레이가 그려지는 픽셀 크기
    private func virtualPixels(for option: Double) -> (width: Int, height: Int) {
        (Int((Double(basePoints.width) * option).rounded()) * backingScale,
         Int((Double(basePoints.height) * option).rounded()) * backingScale)
    }

    private func logActiveMode() {
        guard virtualID != 0, let mode = CGDisplayCopyDisplayMode(virtualID) else { return }
        log("active mode \(mode.width)x\(mode.height)pt/\(mode.pixelWidth)x\(mode.pixelHeight)px -> panel \(pixelSize.width)x\(pixelSize.height)px")
    }

    // MARK: 상태 판단

    private func findTargetScreen() -> NSScreen? {
        NSScreen.screens.first {
            $0.displayID != virtualID && $0.localizedName.localizedCaseInsensitiveContains("sidecar")
        }
    }

    @objc private func evaluate() {
        guard !busy else { return }

        let summary = NSScreen.screens
            .map { "\($0.localizedName)#\($0.displayID) \($0.frame) x\($0.backingScaleFactor)" }
            .joined(separator: " | ")
        if summary != lastScreenSummary {
            lastScreenSummary = summary
            log("screens: \(summary)")
        }

        guard settings.enabled else {
            teardown()
            setStatus("꺼져 있습니다", .off)
            return
        }
        // 권한이 없으면 화면을 건드리지 않고 기다린다.
        guard CGPreflightScreenCaptureAccess() else {
            teardown()
            if !requestedAccess {
                requestedAccess = true
                CGRequestScreenCaptureAccess()
            }
            setStatus("화면 기록 권한이 필요합니다 (허용 후 앱 재실행)", .problem)
            return
        }
        guard let target = findTargetScreen() else {
            teardown()
            setStatus("사이드카 연결을 기다리는 중", .waiting)
            return
        }
        if virtualDisplay != nil, target.displayID == targetID {
            // 이미 동작 중: 창 위치만 맞추고, 캡처가 꺼져 있으면 다시 켠다.
            if let window, window.frame != target.frame {
                window.setFrame(target.frame, display: true)
                layoutMirror()
            }
            if stream == nil { startCapture() }
            return
        }
        teardown()
        start(on: target)
    }

    // MARK: 가상 디스플레이

    private func start(on target: NSScreen) {
        busy = true
        setStatus("세로 화면을 준비하는 중", .waiting)
        targetID = target.displayID
        let scale = target.backingScaleFactor
        // 가로·세로를 뒤바꾼다.
        let pointW = Int(target.frame.height.rounded())
        let pointH = Int(target.frame.width.rounded())
        let pixelW = Int((CGFloat(pointW) * scale).rounded())
        let pixelH = Int((CGFloat(pointH) * scale).rounded())
        pixelSize = (pixelW, pixelH)
        basePoints = (pointW, pointH)
        backingScale = max(1, Int(scale.rounded()))
        publishResolutionSizes()
        originalSide = side(of: CGDisplayBounds(targetID), relativeTo: CGDisplayBounds(CGMainDisplayID()))
        let largest = virtualPixels(for: AppSettings.resolutionOptions.max() ?? 1)
        log("target #\(targetID) \(target.frame) scale=\(scale) side=\(originalSide.rawValue) -> panel \(pixelW)x\(pixelH)px, base \(pointW)x\(pointH)pt, resolution x\(settings.resolutionScale)")

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "iPad Portrait"
        descriptor.maxPixelsWide = UInt32(largest.width)
        descriptor.maxPixelsHigh = UInt32(largest.height)
        // 아이패드 화면 밀도(약 264ppi) 기준의 물리 크기
        descriptor.sizeInMillimeters = CGSize(width: Double(pixelW) / 264 * 25.4,
                                              height: Double(pixelH) / 264 * 25.4)
        descriptor.vendorID = 0x5350
        descriptor.productID = 0x5052
        descriptor.serialNum = 1

        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            log("CGVirtualDisplay 생성 실패")
            setStatus("가상 디스플레이를 만들지 못했습니다", .problem)
            targetID = 0
            busy = false
            return
        }
        virtualDisplay = display
        virtualID = display.displayID
        let applied = applyModes()
        log("virtual display #\(virtualID) applySettings=\(applied)")
        finishConfiguration(showingWindow: true)
    }

    /// 현재 해상도 배율에 맞는 모드를 가상 디스플레이에 등록한다.
    /// 레티나(HiDPI) 모드는 맨 처음 등록한 모드에 대해서만 쓸 수 있으므로,
    /// 해상도를 바꿀 때마다 원하는 모드를 첫 번째로 해서 다시 등록해야 한다.
    private func applyModes() -> Bool {
        guard let display = virtualDisplay else { return false }
        let pixels = virtualPixels(for: settings.resolutionScale)
        // 모드가 하나뿐이면 레티나 모드가 목록에 나오지 않아서 폭 후보를 함께 넣는다.
        var widths = [pixels.width]
        for multiple in [4, 8, 16, 32] {
            let rounded = pixels.width / multiple * multiple
            if !widths.contains(rounded) { widths.append(rounded) }
        }
        // 폭이 이미 32의 배수면 후보가 하나로 합쳐지므로 하나를 더 넣어 둘 이상을 보장한다.
        if widths.count < 2 { widths.append(pixels.width - 64) }
        let modeSettings = CGVirtualDisplaySettings()
        modeSettings.hiDPI = backingScale >= 2 ? 1 : 0
        modeSettings.modes = widths.map {
            CGVirtualDisplayMode(width: UInt($0), height: UInt(pixels.height), refreshRate: 60)
        }
        return display.apply(modeSettings)
    }

    /// 모드 등록 뒤 시스템이 반영할 시간을 주고, 모드 선택·배치·캡처를 이어서 한다.
    private func finishConfiguration(showingWindow: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            guard self.virtualDisplay != nil else { self.busy = false; return }
            let pixels = self.virtualPixels(for: self.settings.resolutionScale)
            self.configureDisplays(pixelW: pixels.width, pixelH: pixels.height, scale: self.backingScale)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                guard self.virtualDisplay != nil else { self.busy = false; return }
                self.logActiveMode()
                if showingWindow, let screen = self.findTargetScreen() { self.showWindow(on: screen) }
                self.busy = false
                self.startCapture()
            }
        }
    }

    /// 사이드카 화면이 주 화면의 어느 쪽에 붙어 있는지 (전역 좌표, y는 아래로 증가)
    private func side(of target: CGRect, relativeTo main: CGRect) -> Placement {
        if target.minX >= main.maxX { return .right }
        if target.maxX <= main.minX { return .left }
        if target.minY >= main.maxY { return .below }
        return .above
    }

    /// 가상 디스플레이를 사이드카와 같은 배율의 모드로 맞추고, 설정한 쪽(자동이면 사이드카가 있던 쪽)에 놓는다.
    /// 사이드카 화면은 그 바깥쪽으로 민다. 앱이 종료되면 원래대로 돌아간다(.forAppOnly).
    private func configureDisplays(pixelW: Int, pixelH: Int, scale: Int) {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(virtualID, options) as? [CGDisplayMode]) ?? []
        log("modes: " + modes.map { "\($0.width)x\($0.height)pt/\($0.pixelWidth)x\($0.pixelHeight)px" }.joined(separator: ", "))
        // 세로 해상도가 같고 배율이 맞는 모드 중 가장 넓은 것
        let mode = modes
            .filter {
                $0.isUsableForDesktopGUI() && $0.pixelWidth == $0.width * scale
                    && $0.pixelHeight == pixelH && $0.pixelWidth <= pixelW
            }
            .max { $0.width < $1.width }
        if mode == nil { log("배율 \(scale)x 모드를 찾지 못해 기본 모드를 사용") }

        let main = CGDisplayBounds(CGMainDisplayID())
        let target = CGDisplayBounds(targetID)
        let virtual = mode.map { CGSize(width: $0.width, height: $0.height) } ?? CGDisplayBounds(virtualID).size
        let placement = settings.placement == .auto ? originalSide : settings.placement
        var vOrigin = CGPoint.zero
        var tOrigin = CGPoint.zero
        switch placement {
        case .right:
            vOrigin = CGPoint(x: main.maxX, y: main.minY)
            tOrigin = CGPoint(x: main.maxX + virtual.width, y: main.minY)
        case .left, .auto:
            vOrigin = CGPoint(x: main.minX - virtual.width, y: main.minY)
            tOrigin = CGPoint(x: main.minX - virtual.width - target.width, y: main.minY)
        case .below:
            vOrigin = CGPoint(x: main.minX, y: main.maxY)
            tOrigin = CGPoint(x: main.minX, y: main.maxY + virtual.height)
        case .above:
            vOrigin = CGPoint(x: main.minX, y: main.minY - virtual.height)
            tOrigin = CGPoint(x: main.minX, y: main.minY - virtual.height - target.height)
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        if let mode { CGConfigureDisplayWithDisplayMode(config, virtualID, mode, nil) }
        CGConfigureDisplayOrigin(config, virtualID, Int32(vOrigin.x), Int32(vOrigin.y))
        CGConfigureDisplayOrigin(config, targetID, Int32(tOrigin.x), Int32(tOrigin.y))
        let result = CGCompleteDisplayConfiguration(config, .forAppOnly)
        let modeText = mode.map { "\($0.width)x\($0.height)pt/\($0.pixelWidth)x\($0.pixelHeight)px" } ?? "default"
        log("configure mode=\(modeText) placement=\(placement.rawValue) main=\(main) target=\(target)->\(tOrigin) virtual=\(virtual)->\(vOrigin) result=\(result.rawValue)")
    }

    private func teardown() {
        guard virtualDisplay != nil || window != nil || stream != nil else { return }
        log("teardown (frames=\(frameCount))")
        stream?.stopCapture(completionHandler: nil)
        stream = nil
        window?.orderOut(nil)
        window = nil
        mirrorLayer.removeFromSuperlayer()
        mirrorLayer.contents = nil
        virtualDisplay = nil   // 해제되면 가상 디스플레이가 사라진다
        virtualID = 0
        targetID = 0
        frameCount = 0
    }

    // MARK: 출력 창

    private func showWindow(on screen: NSScreen) {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.addSublayer(mirrorLayer)
        window.contentView = view
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        self.window = window
        layoutMirror()
        log("window on #\(screen.displayID) frame=\(window.frame)")
    }

    private func layoutMirror() {
        guard let bounds = window?.contentView?.bounds else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 세로 화면 크기의 레이어를 90도 돌리면 가로 화면을 꽉 채운다.
        // 캡처 결과가 패널 픽셀 크기와 같아서 1:1로 그려진다.
        mirrorLayer.bounds = CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width)
        mirrorLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        mirrorLayer.setAffineTransform(CGAffineTransform(rotationAngle: settings.flipped ? -.pi / 2 : .pi / 2))
        CATransaction.commit()
    }

    // MARK: 화면 캡처

    private func startCapture() {
        guard virtualID != 0, stream == nil, !startingCapture else { return }
        guard CGPreflightScreenCaptureAccess() else {
            setStatus("화면 기록 권한이 필요합니다 (허용 후 앱 재실행)", .problem)
            return
        }
        startingCapture = true
        let wantedID = virtualID
        let size = pixelSize
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.startingCapture = false
                guard self.virtualID == wantedID, self.stream == nil else { return }
                guard let display = content?.displays.first(where: { $0.displayID == wantedID }) else {
                    log("캡처 대상 디스플레이 없음: \(error?.localizedDescription ?? "목록에 없음")")
                    self.setStatus("화면을 캡처하지 못했습니다", .problem)
                    return
                }
                let config = SCStreamConfiguration()
                config.width = size.width
                config.height = size.height
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.showsCursor = true
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                config.queueDepth = 5

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                do {
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.captureQueue)
                } catch {
                    log("addStreamOutput 실패: \(error.localizedDescription)")
                    return
                }
                self.stream = stream
                self.barState = BarState()   // 새 스트림은 아무것도 빼지 않은 상태로 시작한다
                stream.startCapture { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if let error {
                            log("startCapture 실패: \(error.localizedDescription)")
                            if self.stream === stream { self.stream = nil }
                            self.setStatus("화면을 캡처하지 못했습니다", .problem)
                        } else {
                            log("capture started \(size.width)x\(size.height)")
                            self.setStatus("세로 모드 동작 중", .active)
                        }
                    }
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }
        let surface = unsafeBitCast(surfaceRef, to: IOSurface.self)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            if let current = self.mirrorLayer.contents as? IOSurface, current === surface {
                self.sameSurfaceCount += 1
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.mirrorLayer.contents = surface
            CATransaction.commit()
            self.frameCount += 1
            if self.frameCount == 1 || self.frameCount == 120 {
                log("frames received: \(self.frameCount)")
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            log("stream stopped: \(error.localizedDescription)")
            self.stream = nil   // 타이머가 다시 캡처를 시도한다
        }
    }

    // MARK: 전체 화면에서 남는 막대 가리기
    //
    // 세로 화면의 앱이 전체 화면일 때, macOS가 메뉴 막대와 창 제목 막대(닫기·최소화 버튼 줄)를
    // 띄운 채로 치우지 않는 경우가 있다(다른 화면에서 Space를 바꾼 뒤, 창을 클릭한 뒤 등).
    // 그리는 것 자체는 막을 수 없으므로, 두 막대를 캡처에서 빼서 아이패드에 보내지 않는다.
    // 커서가 화면 맨 위 근처에 있을 때와 메뉴가 열려 있을 때는 그대로 보여 준다.
    // 그래서 커서를 맨 위로 가져가면 평소처럼 막대가 나타난다.

    /// 커서가 이 높이 안(화면 맨 위 기준)에 있으면 막대를 보여 준다. 실제 막대 높이에 맞춰 갱신된다.
    private var topZoneHeight: CGFloat = 100
    private var cursorWasInTopZone = false

    private func cursorIsInTopZone() -> Bool {
        guard virtualID != 0, let cursor = CGEvent(source: nil)?.location else { return false }
        let display = CGDisplayBounds(virtualID)
        return display.contains(cursor) && cursor.y - display.minY < topZoneHeight
    }

    private func currentBarState() -> BarState {
        guard settings.hideFullScreenBars, virtualID != 0 else { return BarState() }
        let display = CGDisplayBounds(virtualID)
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return BarState() }
        let menuBarLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let popUpMenuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        var fullScreen = false
        var menuOpen = false
        var barsBottom: CGFloat = 0
        var titleBars: [CGWindowID] = []
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  let number = window[kCGWindowNumber as String] as? NSNumber,
                  let boundsValue = window[kCGWindowBounds as String],
                  let bounds = CGRect(dictionaryRepresentation: boundsValue as! CFDictionary),
                  bounds.intersects(display)
            else { continue }
            if layer == popUpMenuLevel { menuOpen = true }
            guard abs(bounds.minX - display.minX) < 1, abs(bounds.width - display.width) < 1 else { continue }
            if layer == menuBarLevel, bounds.height < 100 {
                barsBottom = max(barsBottom, bounds.maxY - display.minY)
            } else if layer == 0 {
                if abs(bounds.minY - display.minY) < 1, abs(bounds.height - display.height) < 1 {
                    // 메뉴 막대 자리까지 화면 전체를 덮는 창이 있으면 전체 화면 Space다.
                    fullScreen = true
                } else if bounds.height < 100, bounds.minY - display.minY < 60 {
                    // 화면 폭 그대로인 얇은 창이 맨 위에 있으면 전체 화면용 제목 막대다.
                    titleBars.append(number.uint32Value)
                    barsBottom = max(barsBottom, bounds.maxY - display.minY)
                }
            }
        }
        topZoneHeight = max(100, barsBottom + 12)
        guard fullScreen, !menuOpen, !cursorIsInTopZone() else { return BarState() }
        return BarState(hide: true, titleBars: titleBars.sorted())
    }

    private func updateBarHiding() {
        guard stream != nil, !busy else { return }
        let state = currentBarState()
        guard state != barState else { return }
        barState = state
        log("bar hiding: hide=\(state.hide) titleBars=\(state.titleBars)")
        let wantedID = virtualID
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, _ in
            DispatchQueue.main.async {
                guard let self, let stream = self.stream, self.virtualID == wantedID else { return }
                guard self.barState == state else { return }   // 그사이 상태가 또 바뀌었으면 다음 번에 맡긴다
                guard let display = content?.displays.first(where: { $0.displayID == wantedID }) else {
                    self.barState = nil   // 다음 번에 다시 시도
                    return
                }
                let excluded = (content?.windows ?? []).filter { state.titleBars.contains($0.windowID) }
                let filter = SCContentFilter(display: display, excludingWindows: excluded)
                if #available(macOS 14.2, *) { filter.includeMenuBar = !state.hide }
                stream.updateContentFilter(filter) { [weak self] error in
                    guard let error else { return }
                    log("bar hiding 적용 실패: \(error.localizedDescription)")
                    DispatchQueue.main.async { self?.barState = nil }
                }
            }
        }
    }

    // MARK: 진단

    /// 동작 확인용 신호. 결과는 ~/Library/Logs/SidecarPortrait-*.png 로 저장한다.
    ///   kill -USR1 <pid>: 사이드카 화면과 가상 디스플레이를 찍는다(번호가 붙는다).
    ///   kill -USR2 <pid>: 설정 패널에서 다음 해상도를 고른 것과 똑같이 동작한다.
    ///   kill -HUP  <pid>: 설정 패널을 띄워 그 창과 아이콘을 찍는다.
    private func installDiagnosticsSignals() {
        func install(_ number: Int32, _ handler: @escaping () -> Void) {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler(handler: handler)
            source.resume()
            signalSources.append(source)
        }
        install(SIGUSR1) { [weak self] in self?.dumpDisplays() }
        install(SIGHUP) { [weak self] in self?.dumpSettingsPanel() }
        install(SIGUSR2) { [weak self] in
            guard let self else { return }
            let options = AppSettings.resolutionOptions
            let index = options.firstIndex(of: self.settings.resolutionScale) ?? 0
            self.settings.resolutionScale = options[(index + 1) % options.count]
        }
    }

    private func diagnosticsURL(_ name: String) -> URL {
        logURL.deletingLastPathComponent().appendingPathComponent("SidecarPortrait-\(name).png")
    }

    /// 사이드카 화면(아이패드에 나가는 모습)과 가상 디스플레이(실제 화면)를 찍는다.
    /// 여러 번 찍어 비교할 수 있게 파일 이름에 번호를 붙인다.
    private func dumpDisplays() {
        dumpCount += 1
        let number = dumpCount
        let ids = [("target", targetID), ("virtual", virtualID)].filter { $0.1 != 0 }
        let cursor = CGEvent(source: nil)?.location ?? .zero
        log("diagnostics #\(number): frames=\(frameCount) sameSurface=\(sameSurfaceCount) bars=\(barState.map { "hide=\($0.hide) \($0.titleBars)" } ?? "pending") cursor=\(cursor) virtual=\(CGDisplayBounds(virtualID)) state=\(settings.state)")
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            for (name, id) in ids {
                guard let display = content?.displays.first(where: { $0.displayID == id }) else { continue }
                let config = SCStreamConfiguration()
                config.width = display.width
                config.height = display.height
                config.showsCursor = true
                self.capture(SCContentFilter(display: display, excludingWindows: []), config, name: "\(name)-\(number)")
            }
        }
    }

    /// 설정 패널을 띄운 뒤 그 창만 찍고, 아이콘도 그림 파일로 남긴다.
    private func dumpSettingsPanel() {
        for (name, active) in [("icon-active", true), ("icon-idle", false)] {
            try? StatusIcon.pngData(active: active, pixels: 180)?.write(to: diagnosticsURL(name))
        }
        if !popover.isShown { togglePopover() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            let popoverWindowID = CGWindowID(self.popover.contentViewController?.view.window?.windowNumber ?? 0)
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
                if let window = content?.windows.first(where: { $0.windowID == popoverWindowID }) {
                    let config = SCStreamConfiguration()
                    config.width = Int(window.frame.width * 2)
                    config.height = Int(window.frame.height * 2)
                    config.showsCursor = false
                    self.capture(SCContentFilter(desktopIndependentWindow: window), config, name: "settings")
                } else {
                    log("diagnostics settings 실패: 창을 찾지 못함 (#\(popoverWindowID))")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.popover.performClose(nil) }
            }
        }
    }

    private func capture(_ filter: SCContentFilter, _ config: SCStreamConfiguration, name: String) {
        let url = diagnosticsURL(name)
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
            guard let image,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else {
                log("diagnostics \(name) 실패: \(error?.localizedDescription ?? "?")")
                return
            }
            try? png.write(to: url)
            log("diagnostics \(name) -> \(url.path) \(image.width)x\(image.height)")
        }
    }

    // MARK: 커서

    private func mouseMoved() {
        let inTopZone = cursorIsInTopZone()
        if inTopZone != cursorWasInTopZone {
            cursorWasInTopZone = inTopZone
            updateBarHiding()
        }
        keepCursorOffTarget()
    }

    private func keepCursorOffTarget() {
        guard settings.confineCursor, virtualID != 0, targetID != 0, window != nil,
              let location = CGEvent(source: nil)?.location else { return }
        guard CGDisplayBounds(targetID).contains(location) else { return }
        let virtual = CGDisplayBounds(virtualID)
        let point = CGPoint(x: min(max(location.x, virtual.minX + 1), virtual.maxX - 2),
                            y: min(max(location.y, virtual.minY + 1), virtual.maxY - 2))
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

// MARK: - 진입점

if let bundleID = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
    log("이미 실행 중이라 종료")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
