// L10n.swift —— 多语言小工具
// 做法：英文原文当「键」，翻译放在 Localizable.xcstrings（English / 简体中文 / 繁體中文 / Español / Français）。
// 界面里直接写 Text("Run") 会自动查表；拼出来的句子（带数字、名字）用 tr("Step %ld of %ld", a, b)。
// 找不到翻译就显示英文原文。系统语言变了，界面跟着变。
import Foundation

func tr(_ key: String, _ args: CVarArg...) -> String {
    let s = NSLocalizedString(key, comment: "")
    return args.isEmpty ? s : String(format: s, locale: Locale.current, arguments: args)
}
