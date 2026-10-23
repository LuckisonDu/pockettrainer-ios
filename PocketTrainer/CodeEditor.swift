// CodeEditor.swift —— 带行号和语法高亮的代码编辑框 + 「代码里的设置 ⇄ 参数输入框」同步
import SwiftUI
import UIKit

/// 读/改代码里的 `名字 = 值` 这种设置行（hidden_units、learning_rate、epochs、seed）
enum ConfigCode {
    /// 找 `key = 值`（只认行首，值取到行尾或 # 注释前），返回值的文字
    static func value(_ key: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "(?m)^\\s*\(key)\\s*=\\s*([^#\\n]*?)\\s*(#.*)?$"),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
    /// 把 key 的值改成 new；代码里没有这一行就加在最前面
    static func set(_ key: String, _ new: String, in text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "(?m)^(\\s*\(key)\\s*=\\s*)([^#\\n]*?)(\\s*(#.*)?)$"),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range(at: 2), in: text) else {
            return "\(key) = \(new)\n" + text }
        return text.replacingCharacters(in: r, with: new)
    }
}

/// 语法高亮：用几条简单的正则给文字上色
enum Highlighter {
    static let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    // (正则, 颜色)：后面的规则会盖住前面的
    private static let rules: [(NSRegularExpression, UIColor)] = [
        (r("\\b(import|from|as|for|in|if|else|elif|def|return|class|while)\\b"), UIColor { $0.userInterfaceStyle == .dark ? .systemPink : .systemPurple }),
        (r("\\b(hidden_units|learning_rate|epochs|seed|classes|photos_per_class)\\b"), UIColor { $0.userInterfaceStyle == .dark ? .systemCyan : .systemTeal }),
        (r("\\b[0-9]+(\\.[0-9]+)?\\b"), .systemBlue),
        (r("\"[^\"\\n]*\"|'[^'\\n]*'"), .systemOrange),
        (r("#.*"), .systemGreen),
    ]
    private static func r(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

    static func apply(to storage: NSMutableAttributedString) {
        let all = NSRange(location: 0, length: storage.length)
        storage.setAttributes([.font: font, .foregroundColor: UIColor.label], range: all)
        for (re, color) in rules { re.enumerateMatches(in: storage.string, range: all) { m, _, _ in
            if let m { storage.addAttribute(.foregroundColor, value: color, range: m.range) } } }
    }
}

/// UIKit 的 UITextView 包一层给 SwiftUI 用（SwiftUI 自带的 TextEditor 不能上色）
struct CodeTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var line: Int          // 光标在第几行（1 开始），给「Add note」用

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.delegate = context.coordinator
        v.isScrollEnabled = false
        v.backgroundColor = .clear
        v.autocorrectionType = .no; v.autocapitalizationType = .none; v.smartQuotesType = .no; v.smartDashesType = .no
        v.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        v.textContainer.lineBreakMode = .byClipping      // 不自动换行，这样左边行号才对得上
        v.font = Highlighter.font
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        if v.text != text {
            v.text = text
            highlight(v)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: uiView.sizeThatFits(CGSize(width: proposal.width ?? 300, height: .greatestFiniteMagnitude)).height)
    }

    fileprivate func highlight(_ v: UITextView) {
        let sel = v.selectedRange
        let s = NSMutableAttributedString(string: v.text)
        Highlighter.apply(to: s)
        v.attributedText = s
        v.selectedRange = sel
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeTextView
        init(_ p: CodeTextView) { parent = p }
        func textViewDidChange(_ tv: UITextView) { parent.text = tv.text; parent.highlight(tv) }
        func textViewDidChangeSelection(_ tv: UITextView) {
            let upto = (tv.text as NSString).substring(to: min(tv.selectedRange.location, tv.text.utf16.count))
            let n = upto.components(separatedBy: "\n").count
            if parent.line != n { DispatchQueue.main.async { self.parent.line = n } }
        }
    }
}

/// 行号 + 代码
struct CodeBox: View {
    @Binding var text: String
    @Binding var line: Int
    var body: some View {
        let count = max(1, text.components(separatedBy: "\n").count)
        HStack(alignment: .top, spacing: 6) {
            Text((1...count).map(String.init).joined(separator: "\n"))
                .font(.system(size: 13, design: .monospaced)).foregroundColor(.secondary)
                .multilineTextAlignment(.trailing).padding(.top, 8).frame(minWidth: 22, alignment: .trailing)
            CodeTextView(text: $text, line: $line)
        }
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBackground))
    }
}
