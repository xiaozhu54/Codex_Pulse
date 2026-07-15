import Foundation

public struct PulseRGBColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    public var hex: String {
        String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}

public enum WeeklyColor {
    private struct Stop {
        let percent: Double
        let color: PulseRGBColor
    }

    private struct OKLab {
        let lightness: Double
        let a: Double
        let b: Double
    }

    private static let stops: [Stop] = [
        Stop(percent: 0, color: color(hex: 0xFF7417)),
        Stop(percent: 9.1, color: color(hex: 0xFF812E)),
        Stop(percent: 18.2, color: color(hex: 0xFF8D45)),
        Stop(percent: 27.3, color: color(hex: 0xFF9D5F)),
        Stop(percent: 36.4, color: color(hex: 0xFFAD78)),
        Stop(percent: 45.5, color: color(hex: 0xFFBD91)),
        Stop(percent: 54.5, color: color(hex: 0xFFCCA8)),
        Stop(percent: 63.6, color: color(hex: 0xFFDABD)),
        Stop(percent: 72.7, color: color(hex: 0xFFE7D0)),
        Stop(percent: 81.8, color: color(hex: 0xFFF1E3)),
        Stop(percent: 90.9, color: color(hex: 0xFFF9F2)),
        Stop(percent: 100, color: color(hex: 0xFFFFFF))
    ]

    public static func color(remainingPercent: Double) -> PulseRGBColor {
        let value = min(max(remainingPercent, 0), 100)
        if let exact = stops.first(where: { abs($0.percent - value) < 0.000_1 }) {
            return exact.color
        }
        guard let upperIndex = stops.firstIndex(where: { $0.percent > value }), upperIndex > 0 else {
            return value <= 0 ? stops[0].color : stops[stops.count - 1].color
        }

        let lower = stops[upperIndex - 1]
        let upper = stops[upperIndex]
        let progress = (value - lower.percent) / (upper.percent - lower.percent)
        let left = toOKLab(lower.color)
        let right = toOKLab(upper.color)
        return fromOKLab(
            OKLab(
                lightness: left.lightness + (right.lightness - left.lightness) * progress,
                a: left.a + (right.a - left.a) * progress,
                b: left.b + (right.b - left.b) * progress
            )
        )
    }

    private static func color(hex: Int) -> PulseRGBColor {
        PulseRGBColor(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    private static func toOKLab(_ color: PulseRGBColor) -> OKLab {
        let red = linear(color.red)
        let green = linear(color.green)
        let blue = linear(color.blue)
        let l = 0.412_221_470_8 * red + 0.536_332_536_3 * green + 0.051_445_992_9 * blue
        let m = 0.211_903_498_2 * red + 0.680_699_545_1 * green + 0.107_396_956_6 * blue
        let s = 0.088_302_461_9 * red + 0.281_718_837_6 * green + 0.629_978_700_5 * blue
        let lRoot = cbrt(l)
        let mRoot = cbrt(m)
        let sRoot = cbrt(s)
        return OKLab(
            lightness: 0.210_454_255_3 * lRoot + 0.793_617_785 * mRoot - 0.004_072_046_8 * sRoot,
            a: 1.977_998_495_1 * lRoot - 2.428_592_205 * mRoot + 0.450_593_709_9 * sRoot,
            b: 0.025_904_037_1 * lRoot + 0.782_771_766_2 * mRoot - 0.808_675_766 * sRoot
        )
    }

    private static func fromOKLab(_ color: OKLab) -> PulseRGBColor {
        let lRoot = color.lightness + 0.396_337_777_4 * color.a + 0.215_803_757_3 * color.b
        let mRoot = color.lightness - 0.105_561_345_8 * color.a - 0.063_854_172_8 * color.b
        let sRoot = color.lightness - 0.089_484_177_5 * color.a - 1.291_485_548 * color.b
        let l = lRoot * lRoot * lRoot
        let m = mRoot * mRoot * mRoot
        let s = sRoot * sRoot * sRoot
        return PulseRGBColor(
            red: encoded(4.076_741_662_1 * l - 3.307_711_591_3 * m + 0.230_969_929_2 * s),
            green: encoded(-1.268_438_004_6 * l + 2.609_757_401_1 * m - 0.341_319_396_5 * s),
            blue: encoded(-0.004_196_086_3 * l - 0.703_418_614_7 * m + 1.707_614_701 * s)
        )
    }

    private static func linear(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }

    private static func encoded(_ component: Double) -> Double {
        component <= 0.003_130_8
            ? 12.92 * component
            : 1.055 * pow(component, 1 / 2.4) - 0.055
    }
}
