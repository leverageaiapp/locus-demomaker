import Foundation
import Combine

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "中文"
        }
    }
}

/// In-app localization with instant switching — no relaunch needed. English
/// strings double as lookup keys, so views read naturally and any key missing
/// from the table falls back to English.
final class Localization: ObservableObject {
    private static let storageKey = "appLanguage"

    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.storageKey) }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.storageKey),
           let stored = AppLanguage(rawValue: raw) {
            language = stored
        } else {
            // First launch: follow the system language.
            let preferred = Locale.preferredLanguages.first ?? "en"
            language = preferred.hasPrefix("zh") ? .chinese : .english
        }
    }

    /// Translate `key` (the English string) into the active language.
    func t(_ key: String) -> String {
        guard language == .chinese else { return key }
        return Self.chinese[key] ?? key
    }

    private static let chinese: [String: String] = [
        // ── ContentView ──
        "Recording": "录制中",
        "Recent Recordings": "最近的录制",
        "Refresh": "刷新",
        "Language": "语言",

        // ── RecordingHeroView ──
        "Start Recording": "开始录制",
        "Click the button to stop": "点击按钮停止",
        "Full frame keeps the screen still; clicks and camera are added on export.":
            "全画幅保持画面静止；点击效果和摄像头在导出时叠加。",
        "Auto Zoom follows your cursor while clicks and camera stay layered on top.":
            "自动缩放跟随光标运镜，点击效果和摄像头保持悬浮在画面上。",
        "Face Camera": "面部摄像头",
        "Quality": "画质",
        "Adjust": "调整",
        "Change": "更换",
        "Pick a window": "选择窗口",
        "No window picked": "未选择窗口",
        "Window": "窗口",
        "Screen": "全屏",
        "Region": "区域",
        "Display": "显示器",
        "Processing": "处理方式",

        // ── Modes / quality ──
        "Auto Zoom": "自动缩放",
        "Full Frame": "全画幅",
        "Standard": "标准",
        "High": "高",
        "Ultra": "超高",

        // ── Backdrop picker ──
        "Backdrop": "人像背景",
        "Real background": "真实背景",
        "Custom color": "自定义颜色",
        "Studio Gray": "影棚灰",
        "White": "白色",
        "Indigo": "靛蓝",
        "Forest": "墨绿",
        "Sand": "沙色",

        // ── Recordings list ──
        "No recordings yet": "还没有录制",
        "Press the record button above to capture your first one.": "点击上方的录制按钮，录下你的第一段视频。",
        "Show fewer": "收起",
        "Show all": "显示全部",
        "Delete this recording?": "删除这段录制？",
        "Move to Trash": "移到废纸篓",
        "Cancel": "取消",
        "%@ and its source video will be moved to the Trash.": "%@ 及其源视频将被移到废纸篓。",
        "Export": "导出",
        "Exported": "已导出",
        "Loading…": "加载中…",
        "Export final video": "导出最终视频",
        "Show in Finder": "在访达中显示",
        "Show exported file in Finder": "在访达中显示导出文件",
        "Show original recording in Finder": "在访达中显示原始录制",
        "Open exported file": "打开导出文件",
        "Open original source.mp4": "打开原始 source.mp4",
        "Re-export…": "重新导出…",
        "Move recording to Trash": "将录制移到废纸篓",
        "Video Mode": "视频模式",
        "Play original recording": "播放原始录制",

        // ── Permissions ──
        "Welcome to Locus DemoMaker": "欢迎使用 Locus DemoMaker",
        "Capture your screen with smooth auto-zoom. We need a couple of macOS permissions first.":
            "录制屏幕并享受顺滑的自动缩放运镜。开始前需要几项 macOS 权限。",
        "Screen Recording": "屏幕录制",
        "Capture pixels from your display.": "捕获屏幕画面。",
        "Accessibility": "辅助功能",
        "Track the cursor anywhere on screen.": "在整个屏幕上跟踪光标。",
        "Microphone": "麦克风",
        "Record narration with the screen.": "录屏的同时录制旁白。",
        "Camera (Optional)": "摄像头（可选）",
        "Record your presenter bubble when enabled.": "开启后录制主讲人圆形气泡。",
        "Allow": "允许",
    ]
}
