import SwiftUI

struct WindowPalette {
    var scheme: ColorScheme = .dark
    var sidebar = Color(rgb: 0x090c11)
    var panel = Color(rgb: 0x0d1015)
    var chrome = Color(red: 0.64, green: 0.67, blue: 0.70)
    var selected = Color(rgb: 0x2c2f34)
    var settingsSidebar = Color(red: 0.06, green: 0.07, blue: 0.09)
    var settingsPanel = Color(red: 0.045, green: 0.055, blue: 0.07)
    var diffEditor = Color(white: 0.075)
    var diffSidebar = Color(white: 0.105)
    var diffHeader = Color(white: 0.125)
    var keepsOriginalMaterials = true

    var ink: Color { scheme == .light ? .black : .white }

    init(theme: TerminalTheme, imported: GhosttyTheme? = nil) {
        if let background = imported?.colors["background"] {
            let red = Double((background >> 16) & 255) / 255
            let green = Double((background >> 8) & 255) / 255
            let blue = Double(background & 255) / 255
            scheme = 0.299 * red + 0.587 * green + 0.114 * blue > 0.58 ? .light : .dark
            let target = scheme == .light ? 0.0 : 1.0
            func blend(_ amount: Double) -> Color {
                Color(red: red + (target - red) * amount, green: green + (target - green) * amount,
                      blue: blue + (target - blue) * amount)
            }
            setSurfaces(base: blend(0), sidebar: blend(scheme == .light ? 0.06 : 0.10),
                        selected: blend(0.20), chrome: blend(0.78))
            return
        }
        switch theme {
        case .contrast: break
        case .ocean:
            setSurfaces(base: Color(rgb: 0x152a39), sidebar: Color(rgb: 0x0b1923),
                        selected: Color(rgb: 0x26495d), chrome: Color(rgb: 0xb4cedc))
        case .paper:
            scheme = .light
            setSurfaces(base: Color(rgb: 0xf7efe2), sidebar: Color(rgb: 0xe9decb),
                        selected: Color(rgb: 0xded0bb), chrome: Color(rgb: 0x584b3d))
        case .original:
            setSurfaces(base: Color(rgb: 0x22252b), sidebar: Color(rgb: 0x17191e),
                        selected: Color(rgb: 0x3a3e47), chrome: Color(rgb: 0xb9bdc9))
        }
    }

    private mutating func setSurfaces(base: Color, sidebar: Color, selected: Color, chrome: Color) {
        keepsOriginalMaterials = false
        self.sidebar = sidebar
        panel = base
        self.selected = selected
        self.chrome = chrome
        settingsSidebar = sidebar
        settingsPanel = base
        diffEditor = base
        diffSidebar = sidebar
        diffHeader = selected
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                  blue: Double(rgb & 255) / 255)
    }

}
