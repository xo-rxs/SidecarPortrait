// 메뉴 막대 아이콘.
// 세로로 선 아이패드, 그 옆에 점선으로 남은 가로 방향 자리, 회전 화살표로 이루어진다.
// 동작 중에는 아이패드가 꽉 찬 모양, 꺼져 있거나 대기 중일 때는 윤곽선만 그린다.

import Cocoa

enum StatusIcon {
    /// 메뉴 막대용 템플릿 이미지(밝은·어두운 메뉴 막대에 맞춰 시스템이 색을 입힌다).
    static func image(active: Bool, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(active: active, in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 18×18 좌표계 기준으로 그린 뒤 rect 크기에 맞춰 확대한다.
    static func draw(active: Bool, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / 18, y: rect.height / 18)
        NSColor.black.set()

        // 가로 방향이던 자리: 세로 아이패드 오른쪽으로 삐져나온 부분만 점선으로.
        let ghost = NSBezierPath()
        ghost.move(to: NSPoint(x: 12.4, y: 1.6))
        ghost.line(to: NSPoint(x: 14.6, y: 1.6))
        ghost.appendArc(withCenter: NSPoint(x: 14.6, y: 3.4), radius: 1.8, startAngle: 270, endAngle: 0)
        ghost.line(to: NSPoint(x: 16.4, y: 7.6))
        ghost.appendArc(withCenter: NSPoint(x: 14.6, y: 7.6), radius: 1.8, startAngle: 0, endAngle: 90)
        ghost.line(to: NSPoint(x: 12.4, y: 9.4))
        ghost.lineWidth = 1.0
        ghost.lineCapStyle = .round
        ghost.setLineDash([1.5, 1.6], count: 2, phase: 0)
        ghost.stroke()

        // 세로로 선 아이패드
        let body = NSRect(x: 1.6, y: 1.6, width: 9.2, height: 14.8)
        let homeBar = NSBezierPath(roundedRect: NSRect(x: 4.5, y: 3.2, width: 3.4, height: 1.0),
                                   xRadius: 0.5, yRadius: 0.5)
        if active {
            NSBezierPath(roundedRect: body, xRadius: 2.1, yRadius: 2.1).fill()
            context.setBlendMode(.clear)   // 홈 막대 자리를 뚫는다
            homeBar.fill()
            context.setBlendMode(.normal)
        } else {
            let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.65, dy: 0.65), xRadius: 1.6, yRadius: 1.6)
            outline.lineWidth = 1.3
            outline.stroke()
            homeBar.fill()
        }

        // 회전 화살표: 오른쪽 위에서 시계 방향으로 내려오는 호
        let center = NSPoint(x: 11.3, y: 10.9)
        let radius: CGFloat = 4.9
        let startAngle: CGFloat = 72
        let endAngle: CGFloat = 20
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
        arc.lineWidth = 1.3
        arc.lineCapStyle = .round
        arc.stroke()

        let theta = (endAngle - 6) * .pi / 180
        let end = NSPoint(x: center.x + radius * cos(theta), y: center.y + radius * sin(theta))
        let tangent = NSPoint(x: sin(theta), y: -cos(theta))   // 시계 방향 진행 방향
        let normal = NSPoint(x: cos(theta), y: sin(theta))
        let head = NSBezierPath()
        head.move(to: NSPoint(x: end.x + tangent.x * 2.0, y: end.y + tangent.y * 2.0))
        head.line(to: NSPoint(x: end.x + normal.x * 1.9, y: end.y + normal.y * 1.9))
        head.line(to: NSPoint(x: end.x - normal.x * 1.9, y: end.y - normal.y * 1.9))
        head.close()
        head.fill()
    }

    /// 확인용: 아이콘을 원하는 배율의 PNG 데이터로 만든다.
    static func pngData(active: Bool, pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(active: active, in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
