import SwiftUI
import UIKit

/// A real input accessory works inside UIHostingConfiguration without a
/// NavigationStack keyboard toolbar or SwiftUI focus propagation.
@MainActor
struct NativeRequestInput: UIViewRepresentable {
    @Binding var value: String
    let placeholder: String
    let identifier: String
    let completionIdentifier: String
    let secret: Bool
    @Environment(\.isEnabled) private var enabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> RequestTextView {
        let view = RequestTextView(frame: .zero, textContainer: nil)
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.backgroundColor = .secondarySystemBackground
        view.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.layer.cornerRadius = 8
        view.layer.borderWidth = 0.5
        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        let done = UIBarButtonItem(title: "完成", style: .done, target: context.coordinator, action: #selector(Coordinator.finish))
        done.accessibilityIdentifier = completionIdentifier
        toolbar.items = [UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil), done]
        view.inputAccessoryView = toolbar
        return view
    }
    func updateUIView(_ view: RequestTextView, context: Context) {
        context.coordinator.parent = self
        view.isEditable = enabled
        view.isUserInteractionEnabled = enabled
        view.isSecureTextEntry = secret
        view.autocorrectionType = secret ? .no : .default
        view.spellCheckingType = secret ? .no : .default
        view.autocapitalizationType = secret ? .none : .sentences
        view.textContentType = secret ? .password : nil
        view.accessibilityIdentifier = identifier
        view.accessibilityLabel = placeholder
        view.placeholder.text = placeholder
        (view.inputAccessoryView as? UIToolbar)?.items?.last?.accessibilityIdentifier = completionIdentifier
        if view.text != value && view.markedTextRange == nil { view.text = value }
        view.setNeedsLayout()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RequestTextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let font = uiView.font ?? .preferredFont(forTextStyle: .body)
        let insets = uiView.textContainerInset
        let available = max(1, width - insets.left - insets.right - 2 * uiView.textContainer.lineFragmentPadding)
        let textHeight = (value as NSString).boundingRect(with: CGSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil).height
        let padding = insets.top + insets.bottom
        let height = ceil(max(2 * font.lineHeight, textHeight) + padding)
        let maximum = ceil(6 * font.lineHeight + padding)
        uiView.isScrollEnabled = height > maximum
        return CGSize(width: width, height: min(height, maximum))
    }
    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeRequestInput
        init(_ parent: NativeRequestInput) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) {
            parent.value = textView.text ?? ""
            textView.setNeedsLayout()
            textView.invalidateIntrinsicContentSize()
        }
        @objc func finish() { NativeRequestKeyboard.dismiss() }
    }
}

@MainActor
final class RequestTextView: UITextView {
    let placeholder = UILabel()
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholder.textColor = .placeholderText
        placeholder.isUserInteractionEnabled = false
        placeholder.isAccessibilityElement = false
        addSubview(placeholder)
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:textContainer:)") }
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        placeholder.font = font
        placeholder.isHidden = !text.isEmpty
        let x = textContainerInset.left + textContainer.lineFragmentPadding
        placeholder.frame = CGRect(x: x, y: textContainerInset.top, width: max(0, bounds.width - x - textContainerInset.right),
                                   height: font?.lineHeight ?? 22)
    }
}
