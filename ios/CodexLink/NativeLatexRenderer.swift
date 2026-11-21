import UIKit

enum NativeLatexRenderer {
    struct RenderedFormula {
        let image: UIImage
        let descent: CGFloat
    }

    static func render(_ latex: String, widthLimit: CGFloat, fontSize: CGFloat,
                       textColor: UIColor, display: Bool, displayScale: CGFloat) -> RenderedFormula? {
        guard !latex.isEmpty, latex.utf16.count <= 1_000,
              widthLimit.isFinite, widthLimit > 2, fontSize.isFinite, fontSize > 0,
              let layout = try? iOSLaTeXEngine.shared.parse(latex, displayMode: display, color: textColor)
        else { return nil }

        let renderer = iOSLaTeXRenderer(displayList: layout, fontSize: fontSize)
        let width = renderer.width
        let height = renderer.totalHeight
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              renderer.depth.isFinite, renderer.depth >= 0, renderer.depth <= height
        else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = displayScale.isFinite && displayScale > 0 ? displayScale : UIScreen.main.scale
        format.preferredRange = .standard
        format.opaque = false
        let padding: CGFloat = 1
        let pixelLimit = 4_096 / format.scale
        let fit = min(1, (min(widthLimit, pixelLimit) - 2 * padding) / width,
                      (pixelLimit - 2 * padding) / height)
        guard fit > 0 else { return nil }
        let size = CGSize(width: width * fit + 2 * padding, height: height * fit + 2 * padding)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.translateBy(x: padding, y: padding)
            context.cgContext.scaleBy(x: fit, y: fit)
            renderer.draw(in: context.cgContext)
        }
        return RenderedFormula(image: image, descent: renderer.depth * fit + padding)
    }
}
