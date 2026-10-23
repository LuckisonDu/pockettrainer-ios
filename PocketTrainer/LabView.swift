// LabView.swift —— 「Protection lab」：专门用来测试保护的页面（打断、闪退、方法对比、GPU 限时）
import SwiftUI

struct ProtectionLabView: View {
    @EnvironmentObject var t: Trainer
    @AppStorage("verify") private var verify = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("These buttons break training on purpose, to show what the protection does. Then go back and press Run.")
                    .font(.footnote).foregroundColor(.secondary)
                Card {
                    Toggle(isOn: $verify) {
                        VStack(alignment: .leading) { Text("Verify training results").font(.subheadline.bold()); Text("Double-check every step on the CPU").font(.caption).foregroundColor(.secondary) }
                    }.tint(.teal)
                }
                Card {
                    Button { if t.running { t.interruptNow() } else { t.interruptArmed.toggle() } } label: {
                        Label(t.interruptArmed ? tr("Interruption armed (next Run)") : tr("Simulate a system interruption"), systemImage: "bolt.trianglebadge.exclamationmark").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).tint(t.interruptArmed ? .orange : .teal).disabled(t.interruptUsedUp)
                    if t.interruptUsedUp { Text("Interrupt demo can be used once per launch. Restart the app to use it again.").font(.caption).foregroundColor(.secondary) }
                    Button { t.crashArmed.toggle() } label: {
                        Label(t.crashArmed ? tr("Crash armed (next Run)") : tr("Simulate a crash and resume"), systemImage: "xmark.octagon").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).tint(t.crashArmed ? .orange : .teal).disabled(t.running)
                    Text("The app closes itself in the middle of training; open it again and it continues from the last checkpoint (needs \"Save checkpoints\" in Settings).").font(.caption).foregroundColor(.secondary)
                }
                Card {
                    Button { t.startCompare() } label: { Label("Compare methods", systemImage: "chart.bar.xaxis").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).tint(.teal).disabled(t.running || t.measuring || Interruption.usedThisLaunch)
                    Text("Runs None / Checkpoint-only / Our method side by side with the same interruption.").font(.caption).foregroundColor(.secondary)
                    Button { t.measureLimit() } label: { Label("Measure my phone's limit", systemImage: "stopwatch").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).tint(.teal).disabled(t.running || t.measuring || Interruption.usedThisLaunch)
                    Text("Finds how long one GPU task may run before iOS stops it. This makes the GPU reset once and takes about 1 minute. Afterwards restart the app before using the interruption demo.")
                        .font(.caption).foregroundColor(.secondary)
                    if !t.limitText.isEmpty { Text(t.limitText).font(.subheadline.bold()) }
                }
                if t.comparing {
                    Card {
                        ProgressView(value: Double(t.step), total: Double(max(t.totalSteps, 1)))
                        Text(t.computingReference ? tr("Computing the CPU reference…") : tr("Comparing: step %ld / %ld", t.step, t.totalSteps)).font(.footnote)
                    }
                }
                if !t.compareRows.isEmpty { compareCard }
                bannerView
            }.padding(14)
        }
        .background(Color.pageBackground)
        .navigationTitle("Protection lab").navigationBarTitleDisplayMode(.inline)
        .toolbar { AskChatGPTButton { ChatContext.lab(t) } }
    }

    private var compareCard: some View {
        Card {
            Text("Compare methods").font(.headline)
            ForEach(t.compareRows) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr(r.name)).font(.subheadline.bold())
                    Text(tr("Accuracy %.1f%% · %@ · %ld repairs · %.1f s", r.accuracy * 100, r.matchesReference ? tr("matches the reference") : tr("differs from the reference"), r.repairs, r.seconds))
                        .font(.footnote).foregroundColor(r.matchesReference ? .primary : .red)
                }
            }
            Text(tr("CPU reference accuracy: %.1f%%", (t.compareRows.first?.refAccuracy ?? 0) * 100)).font(.footnote)
            Text(t.compareNote).font(.caption).foregroundColor(.secondary)
        }
    }

    @ViewBuilder private var bannerView: some View {
        switch t.banner {
        case .none: EmptyView()
        case .passed: banner(tr("✓ Self-check passed"), .green)
        case .unprotected: banner(tr("Protection is off — nothing is checking the GPU"), .gray)
        case .fixed(let n): banner(tr("⚠ Error detected and fixed automatically (%ld times)", n), .orange)
        case .failed(let a): banner(tr("✗ Training silently failed — accuracy %ld%% (no error was shown)", Int((a * 100).rounded())), .red)
        case .finishedUnprotected: banner(tr("Finished (protection was off)"), .gray)
        }
    }

    private func banner(_ text: String, _ color: Color) -> some View {
        Text(text).font(.subheadline.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.18))).foregroundColor(color == .gray ? .primary : color)
    }
}
