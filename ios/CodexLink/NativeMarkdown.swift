import SwiftUI
import UIKit
import Runestone
import TreeSitterMarkdownRunestone

struct NativeMarkdown: View {
    let text: String
    @State private var rendered = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if rendered { NativeRenderedMarkdown(text: text) }
            else { NativeCodeView(text: .constant(text), language: "markdown", identifier: "native.markdown.source") }
            Toggle("渲染 Markdown", isOn: $rendered).font(.caption)
        }
    }
}
private struct NativeRenderedMarkdown: UIViewRepresentable {
    let text: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> Runestone.TextView {
        let view = Runestone.TextView(); view.backgroundColor = .clear
        view.isEditable = false; view.isSelectable = true; view.isAccessibilityElement = true
        view.accessibilityLabel = "Markdown 渲染预览"; view.showLineNumbers = false
        view.isLineWrappingEnabled = true; view.isScrollEnabled = false
        view.accessibilityIdentifier = "native.markdown.rendered"
        context.coordinator.configure(view, text: text); return view
    }
    func updateUIView(_ view: Runestone.TextView, context: Context) {
        if view.text != text && !context.coordinator.preparing { context.coordinator.configure(view, text: text) }
    }
    static func dismantleUIView(_ view: Runestone.TextView, coordinator: Coordinator) { coordinator.generation += 1 }
    final class Coordinator {
        var generation = 0; var preparing = false
        func configure(_ view: Runestone.TextView, text: String) {
            generation += 1; let token = generation; preparing = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak view] in
                let state = TextViewState(text: text, theme: NativeCodeTheme(), language: .markdown)
                DispatchQueue.main.async {
                    guard let self, let view, token == self.generation else { return }
                    view.setState(state); self.preparing = false; view.accessibilityValue = text
                }
            }
        }
    }
}
