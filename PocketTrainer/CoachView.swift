// CoachView.swift —— Assistant 页：离线「教练」，规则式建议（见 Advice.swift）
import SwiftUI

struct CoachView: View {
    @State private var runs = RunHistory.all()
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ScreenHeader(title: "Assistant") { AskChatGPTButton { ChatContext.assistant(runs) }; GearButton() }
                    Label("Offline coach · rule-based", systemImage: "wifi.slash").font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 4).background(Capsule().fill(Color.teal.opacity(0.15))).foregroundColor(.teal)
                    if let r = runs.first {
                        Card {
                            Text("Your last run").font(.headline)
                            Text("\(r.project) · \(r.date.friendly)").font(.caption).foregroundColor(.secondary)
                            Text(tr("Accuracy %.1f%% · learning rate %.3g · %ld hidden units · %ld epochs", r.accuracy * 100, r.lr, r.hidden, r.epochs)).font(.subheadline)
                        }
                    }
                    ForEach(Array(Advice.coach(runs: runs).enumerated()), id: \.offset) { _, tip in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "sparkles").foregroundColor(.teal)
                            Text(tip).font(.subheadline)
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.cardBackground))
                    }
                    AskChatGPTButton(context: { ChatContext.assistant(runs) }, labeled: true).buttonStyle(.borderedProminent).tint(.teal)
                    Text("This coach only looks at the numbers of your recent runs. It does not use the internet or a large AI model.").font(.caption).foregroundColor(.secondary)
                }.padding(16)
            }
            .background(Color.pageBackground)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { runs = RunHistory.all() }
            .onReceive(NotificationCenter.default.publisher(for: .runHistoryChanged)) { _ in runs = RunHistory.all() }
        }
    }
}
