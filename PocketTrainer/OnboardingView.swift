// OnboardingView.swift —— 第一次打开时的 3 步引导（可跳过，设置里不再出现）。启动参数 --skip-onboarding 用于自动测试 / 截图时跳过。
// 说明：本文件由 AI（Claude）编写，须在国会 AI 披露里写明。
import SwiftUI

struct OnboardingView: View {
    @Binding var shown: Bool
    @State private var page = 0
    private let pages: [(icon: String, title: String, text: String)] = [
        ("iphone", "Learn AI on this phone", "PocketTrainer trains a small AI right here on your phone. No server, no laptop, no internet needed."),
        ("play.circle.fill", "Press Run and watch it learn", "Open a project, press Run, and watch the curve go down. After a few seconds it recognises photos it has never seen."),
        ("shield.lefthalf.filled", "See why protection matters", "In the Protection lab, break training on purpose with protection off, then on. Without it the result can be ruined with no error."),
    ]
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: pages[page].icon).font(.system(size: 64)).foregroundColor(.teal).accessibilityHidden(true)
            Text(LocalizedStringKey(pages[page].title)).font(.title.bold()).multilineTextAlignment(.center)
            Text(LocalizedStringKey(pages[page].text)).font(.body).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
            Text("A student project by Luckison Du").font(.footnote).foregroundColor(.secondary)
            Spacer()
            HStack(spacing: 8) { ForEach(0..<pages.count, id: \.self) { i in Circle().fill(i == page ? Color.teal : Color.gray.opacity(0.3)).frame(width: 8, height: 8) } }.accessibilityHidden(true)
            Button(page < pages.count - 1 ? "Next" : "Get started") {
                if page < pages.count - 1 { withAnimation { page += 1 } } else { UserDefaults.standard.set(true, forKey: "onboarded"); shown = false }
            }.buttonStyle(TealButtonStyle()).padding(.horizontal, 24)
            Button("Skip") { UserDefaults.standard.set(true, forKey: "onboarded"); shown = false }.foregroundColor(.secondary).padding(.bottom, 16)
        }.background(Color.pageBackground.ignoresSafeArea())
    }
}
