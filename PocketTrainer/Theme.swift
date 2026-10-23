// Theme.swift —— 颜色、卡片、按钮等小零件（设计图风格：teal 主色 + 白色圆角卡片）
import SwiftUI

extension Color {
    static let teal = Color(red: 0.055, green: 0.541, blue: 0.498)            // #0E8A7F 主色
    static let pageBackground = Color(.systemGroupedBackground)
    static let cardBackground = Color(.secondarySystemGroupedBackground)       // 浅色=白，深色=深灰
}

/// 白色圆角卡片
struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.cardBackground))
    }
}

/// teal 大按钮
struct TealButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).foregroundColor(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.teal.opacity(configuration.isPressed ? 0.7 : 1)))
    }
}

/// 页面标题行：大标题 + 右边可放按钮
struct ScreenHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack { Text(title).font(.largeTitle.bold()); Spacer(); trailing() }
    }
}

/// 小节标题
struct SectionTitle: View {
    let text: LocalizedStringKey
    var body: some View { Text(text).font(.title3.bold()).padding(.top, 6) }
}

/// App 标志：手机 + 神经网络（和 App 图标同一个图案，用 SwiftUI 画的简化版）
struct LogoMark: View {
    var size: CGFloat = 36
    var body: some View {
        Canvas { ctx, sz in
            let u = sz.width / 1024
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * u, y: y * u) }
            // 手机外框
            let phone = Path(roundedRect: CGRect(x: 308 * u, y: 150 * u, width: 408 * u, height: 724 * u), cornerRadius: 96 * u)
            ctx.stroke(phone, with: .color(.white), lineWidth: 42 * u)
            // 网络：3 - 4 - 2 个节点，层与层之间连线
            let cols: [(CGFloat, [CGFloat])] = [(392, [400, 520, 640]), (512, [370, 470, 570, 670]), (632, [445, 595])]
            for i in 0..<2 { for a in cols[i].1 { for b in cols[i + 1].1 {
                var l = Path(); l.move(to: pt(cols[i].0, a)); l.addLine(to: pt(cols[i + 1].0, b))
                ctx.stroke(l, with: .color(.white.opacity(0.55)), lineWidth: 7 * u) } } }
            for (x, ys) in cols { for y in ys { ctx.fill(Path(ellipseIn: CGRect(x: (x - 22) * u, y: (y - 22) * u, width: 44 * u, height: 44 * u)), with: .color(.white)) } }
        }
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: size * 0.22).fill(LinearGradient(colors: [Color(red: 0.08, green: 0.72, blue: 0.65), Color(red: 0.04, green: 0.43, blue: 0.40)], startPoint: .topLeading, endPoint: .bottomTrailing)))
    }
}

/// 页面左上角：标志 + 名字
struct LogoView: View {
    var body: some View {
        HStack(spacing: 8) {
            LogoMark(size: 38)
            VStack(alignment: .leading, spacing: 0) {
                Text("PocketTrainer").font(.headline)
                Text("Works offline · Internet only for importing").font(.caption2).foregroundColor(.secondary).lineLimit(2)
            }
        }
    }
}

extension Date {
    /// "Today, 10:30 AM" / "Yesterday, 8:15 PM" / "Oct 12, 3:00 PM"
    var friendly: String {
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short; f.doesRelativeDateFormatting = true     // 今天/昨天、日期格式都跟系统语言走
        return f.string(from: self)
    }
}
