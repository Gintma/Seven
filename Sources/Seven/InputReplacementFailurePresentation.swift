import Foundation

/// 内部保留准确错误类型，界面按用户能采取的处理方式合并；不靠字符串内容猜测分类。
struct InputReplacementFailurePresentation {
    let reasonMessage: LocalizedMessage
    let detailMessage: LocalizedMessage
    var reason: String { reasonMessage.text }
    var detail: String { detailMessage.text }

    init(error: Error) {
        detailMessage = .forError(error)
        if let failure = error as? InputReplacementError {
            switch failure {
            case .empty: reasonMessage = "没有可翻译的文字"
            case .unreadable, .focusUnavailable, .selectionUnavailable: reasonMessage = .key("couldNotReadInput")
            case .readOnly: reasonMessage = .key("thisFieldDoesNotSupportReplacement")
            case .focusChanged, .controlChanged, .contentChanged, .selectionChanged:
                reasonMessage = .key("inputLocationOrTextChanged")
            case .tooLong: reasonMessage = .key("sourceTextExceeds20000Characters")
            case .noService: reasonMessage = .key("enableAServiceInTranslationMode")
            case .timedOut: reasonMessage = .key("translationTimedOut")
            case .failed: reasonMessage = .key("checkTheReplacement")
            }
        } else if let failure = error as? SelectionReadError {
            reasonMessage = failure == .accessibilityPermission ? "请授权辅助功能" : .key("couldNotReadInput")
        } else {
            reasonMessage = .key("translationFailed")
        }
    }
}
