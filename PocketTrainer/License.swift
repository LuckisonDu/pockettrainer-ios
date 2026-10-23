// License.swift —— 许可证徽标：绿色 = 宽松；橙色 = copyleft；黄色警告 = 非商用 / 未知 / 其他
import SwiftUI

enum LicenseLevel { case ok, copyleft, warn }

enum LicenseInfo {
    static func level(_ spdx: String?) -> LicenseLevel {
        guard let l = spdx?.lowercased(), !l.isEmpty, l != "unknown", l != "other", l != "noassertion" else { return .warn }
        if l.contains("-nc") || l.hasPrefix("openrail") || l.hasPrefix("llama") || l.contains("research") || l.hasPrefix("gemma") { return .warn }
        if l.hasPrefix("gpl") || l.hasPrefix("agpl") || l.hasPrefix("lgpl") || l.contains("-sa") || l.hasPrefix("mpl") || l.hasPrefix("eupl") { return .copyleft }
        return .ok
    }
}

struct LicenseBadge: View {
    let spdx: String?
    var body: some View {
        let lv = LicenseInfo.level(spdx)
        let color: Color = lv == .ok ? .green : (lv == .copyleft ? .orange : .yellow)
        VStack(alignment: .leading, spacing: 3) {
            Text(spdx?.isEmpty == false ? spdx! : tr("not stated")).font(.caption.bold())
                .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(color.opacity(0.25))).foregroundColor(lv == .warn ? .primary : color)
            if lv == .copyleft { Text("Copyleft license: shared changes must stay open.").font(.caption2).foregroundColor(.secondary) }
            if lv != .ok { Label("Check the license before using or sharing", systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundColor(.orange) }
        }
    }
}
