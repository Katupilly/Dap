import SwiftUI

enum DapFontWeight {
    case regular
    case medium
    case semibold
    case bold

    fileprivate var postScriptName: String {
        switch self {
        case .regular:
            "ZTTalk-Regular"
        case .medium:
            "ZTTalk-Medium"
        case .semibold, .bold:
            "ZTTalk-Bold"
        }
    }
}

extension Font {
    static func dap(
        size: CGFloat,
        weight: DapFontWeight = .regular
    ) -> Font {
        .custom(weight.postScriptName, size: size)
    }

    static func dap(
        size: CGFloat,
        weight: DapFontWeight = .regular,
        relativeTo textStyle: TextStyle
    ) -> Font {
        .custom(weight.postScriptName, size: size, relativeTo: textStyle)
    }

    static func dap(
        _ textStyle: TextStyle,
        weight: DapFontWeight = .regular
    ) -> Font {
        .dap(size: textStyle.dapPointSize, weight: weight, relativeTo: textStyle)
    }
}

private extension Font.TextStyle {
    var dapPointSize: CGFloat {
        switch self {
        case .largeTitle:
            34
        case .title:
            28
        case .title2:
            22
        case .title3:
            20
        case .headline:
            17
        case .subheadline:
            15
        case .body:
            17
        case .callout:
            16
        case .footnote:
            13
        case .caption:
            12
        case .caption2:
            11
        @unknown default:
            17
        }
    }
}
