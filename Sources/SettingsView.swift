// 설정 값과, 메뉴 막대 아이콘을 눌렀을 때 뜨는 설정 패널.

import Cocoa
import ServiceManagement
import SwiftUI

/// 세로 화면을 맥북 화면의 어느 쪽에 둘지
enum Placement: String, CaseIterable, Identifiable {
    case auto, left, right, above, below

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "자동"
        case .left: return "왼쪽"
        case .right: return "오른쪽"
        case .above: return "위"
        case .below: return "아래"
        }
    }
}

enum RunState {
    case active, waiting, off, problem
}

final class AppSettings: ObservableObject {
    enum Change { case enabled, resolution, rotation, placement }

    static let resolutionOptions: [Double] = [1.0, 1.25, 1.5]
    static let resolutionNames = ["기본", "넓게", "더 넓게"]
    static let resolutionHints = ["글자가 가장 크고 선명합니다", "맥북 화면과 비슷한 글자 크기입니다", "가장 넓지만 글자가 작습니다"]

    /// 값이 바뀌면 앱 본체에 알린다.
    var onChange: ((Change) -> Void)?
    private let defaults = UserDefaults.standard

    // 저장되는 설정
    @Published var enabled: Bool {
        didSet { if enabled != oldValue { defaults.set(enabled, forKey: "enabled"); onChange?(.enabled) } }
    }
    /// 해상도 배율. 클수록 화면이 넓어지고 글자는 작아진다.
    @Published var resolutionScale: Double {
        didSet { if resolutionScale != oldValue { defaults.set(resolutionScale, forKey: "resolutionScale"); onChange?(.resolution) } }
    }
    /// false: 아이패드를 시계 방향으로 돌려 세움, true: 반시계 방향
    @Published var flipped: Bool {
        didSet { if flipped != oldValue { defaults.set(flipped, forKey: "flipped"); onChange?(.rotation) } }
    }
    @Published var placement: Placement {
        didSet { if placement != oldValue { defaults.set(placement.rawValue, forKey: "placement"); onChange?(.placement) } }
    }
    @Published var confineCursor: Bool {
        didSet { defaults.set(confineCursor, forKey: "confineCursor") }
    }
    /// 전체 화면 앱에 남는 메뉴 막대·신호등 줄을 아이패드 화면에서 뺀다(커서가 맨 위 근처일 때는 제외).
    @Published var hideFullScreenBars: Bool {
        didSet { defaults.set(hideFullScreenBars, forKey: "hideFullScreenBars") }
    }
    @Published var launchAtLogin: Bool {
        didSet { if launchAtLogin != oldValue { applyLaunchAtLogin(previous: oldValue) } }
    }

    // 실행 중 상태(저장하지 않음)
    @Published var statusText = "시작하는 중…"
    @Published var state: RunState = .waiting
    /// 각 해상도 선택지의 실제 크기. 사이드카가 연결돼야 알 수 있다.
    @Published var resolutionSizes: [String] = []
    @Published var loginError: String?

    private var revertingLogin = false

    init() {
        enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        let scale = defaults.double(forKey: "resolutionScale")
        resolutionScale = Self.resolutionOptions.contains(scale) ? scale : 1.25
        flipped = defaults.bool(forKey: "flipped")
        placement = Placement(rawValue: defaults.string(forKey: "placement") ?? "") ?? .auto
        confineCursor = defaults.object(forKey: "confineCursor") as? Bool ?? true
        hideFullScreenBars = defaults.object(forKey: "hideFullScreenBars") as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchAtLogin(previous: Bool) {
        guard !revertingLogin else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
            log("launchAtLogin=\(launchAtLogin)")
        } catch {
            log("launchAtLogin 변경 실패: \(error.localizedDescription)")
            loginError = error.localizedDescription
            revertingLogin = true
            launchAtLogin = previous
            revertingLogin = false
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            section("해상도") {
                Picker("해상도", selection: $settings.resolutionScale) {
                    ForEach(AppSettings.resolutionOptions.indices, id: \.self) { index in
                        Text(AppSettings.resolutionNames[index]).tag(AppSettings.resolutionOptions[index])
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                caption(resolutionCaption)
            }
            section("아이패드를 돌려 세운 방향") {
                Picker("방향", selection: $settings.flipped) {
                    Text("↻ 시계 방향").tag(false)
                    Text("↺ 반시계 방향").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                caption("화면이 거꾸로 보이면 반대쪽을 고르세요")
            }
            section("세로 화면 위치") {
                Picker("위치", selection: $settings.placement) {
                    ForEach(Placement.allCases) { placement in
                        Text(placement.title).tag(placement)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                caption("맥북 화면을 기준으로 세로 화면이 놓이는 쪽입니다")
            }
            Divider()
            switchRow("커서 가두기", detail: "가려진 원래 사이드카 화면으로 커서가 넘어가지 않게 합니다",
                      isOn: $settings.confineCursor)
            switchRow("전체 화면에서 남는 막대 가리기",
                      detail: "전체 화면 앱 위에 남는 메뉴 막대와 창 버튼 줄을 아이패드에 보내지 않습니다. 커서를 화면 맨 위로 가져가면 다시 보입니다",
                      isOn: $settings.hideFullScreenBars)
            switchRow("로그인할 때 자동으로 실행", detail: settings.loginError, isOn: $settings.launchAtLogin)
            Divider()
            HStack {
                caption("Sidecar Portrait \(appVersion)")
                Spacer()
                Button("종료") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: StatusIcon.image(active: settings.state == .active, size: 30))
                .renderingMode(.template)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text("세로 모드").font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(stateColor).frame(width: 7, height: 7)
                    Text(settings.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Toggle("세로 모드", isOn: $settings.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private var stateColor: Color {
        switch settings.state {
        case .active: return .green
        case .waiting: return .orange
        case .off: return .gray
        case .problem: return .red
        }
    }

    private var resolutionCaption: String {
        let index = AppSettings.resolutionOptions.firstIndex(of: settings.resolutionScale) ?? 0
        let hint = AppSettings.resolutionHints[index]
        guard settings.resolutionSizes.indices.contains(index) else { return hint }
        return "\(settings.resolutionSizes[index]) · \(hint)"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).fontWeight(.medium)
            content()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func switchRow(_ title: String, detail: String?, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { caption(detail) }
            }
            Spacer()
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}
