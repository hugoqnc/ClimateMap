import SwiftUI

extension View {
    func smartHomeGlass(cornerRadius: CGFloat = 28, tint: Color? = nil) -> some View {
        glassEffect(
            .regular.tint(tint),
            in: .rect(cornerRadius: cornerRadius)
        )
    }
}
