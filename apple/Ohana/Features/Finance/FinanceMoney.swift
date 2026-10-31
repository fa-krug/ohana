import Foundation
import SwiftUI

/// Money as integer cents (server/lib/finance/money.ts): formatting, and parsing what people type
/// or what a bank exports ("12,50", "-1.234,56", "(45.00)").
enum FinanceMoney {
    /// `sign`: a "+" on income too; `whole`: no cents (averages per month).
    static func format(_ cents: Int, currency: String, sign: Bool = false, whole: Bool = false,
                       locale: Locale = .autoupdatingCurrent) -> String {
        let amount = Decimal(cents) / 100
        var style = Decimal.FormatStyle.Currency(code: currency.isEmpty ? "EUR" : currency, locale: locale)
        if sign { style = style.sign(strategy: .always(showZero: false)) }
        if whole { style = style.precision(.fractionLength(0)) }
        return amount.formatted(style)
    }

    /// Parses an amount: the decimal separator is the last "," or "." followed by one or two
    /// digits at the end, unless `decimal` says which one it is. Returns cents, or nil.
    static func parse(_ input: String, decimal: Character? = nil) -> Int? {
        let allowed = Set("0123456789,.-+()")
        var s = Array(input.trimmingCharacters(in: .whitespacesAndNewlines).filter { allowed.contains($0) })
        if s.isEmpty { return nil }
        var negative = false
        if s.count >= 2, s.first == "(", s.last == ")" {
            negative = true
            s = Array(s.dropFirst().dropLast())
        }
        if let first = s.first, first == "-" || first == "+" {
            negative = negative || first == "-"
            s.removeFirst()
        } else if s.last == "-" {
            negative = true // "12,50-" (some banks)
            s.removeLast()
        }
        let separator = decimal ?? detectSeparator(s)
        var int = s[...], frac: ArraySlice<Character> = []
        if let separator, let i = s.lastIndex(of: separator) {
            int = s[..<i]
            frac = s[(i + 1)...]
        }
        let digits = int.filter { $0 != "," && $0 != "." }
        guard digits.allSatisfy(\.isASCIIDigit), frac.count <= 2, frac.allSatisfy(\.isASCIIDigit),
              !(digits.isEmpty && frac.isEmpty) else { return nil }
        guard let whole = digits.isEmpty ? 0 : Int(String(digits)) else { return nil }
        let fraction = Int(String(frac).padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0
        let (product, overflow) = whole.multipliedReportingOverflow(by: 100)
        guard !overflow else { return nil }
        let cents = product + fraction
        return negative ? -cents : cents
    }

    private static func detectSeparator(_ s: [Character]) -> Character? {
        for n in [2, 1] where s.count > n {
            let sep = s[s.count - n - 1]
            if (sep == "," || sep == "."), s.suffix(n).allSatisfy(\.isASCIIDigit) { return sep }
        }
        return nil
    }

    /// Cents as an editable string without currency in the locale's style: "1234,56".
    static func input(_ cents: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let text = String(format: "%d.%02d", abs(cents) / 100, abs(cents) % 100)
        let separator = locale.decimalSeparator ?? "."
        return separator == "." ? text : text.replacingOccurrences(of: ".", with: separator)
    }

    /// Like `input`, with a minus for a negative amount (balances).
    static func signedInput(_ cents: Int) -> String {
        (cents < 0 ? "-" : "") + input(cents)
    }

    /// "0,00" or "0.00".
    static var placeholder: String { input(0) }

    static func color(_ cents: Int, muted: Bool = false) -> Color {
        if muted { return .secondary }
        return cents > 0 ? .green : cents < 0 ? .red : .primary
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

/// Category and account colors: "#22c55e".
enum FinanceColor {
    /// The web's palette (lib/calendar/core.ts PALETTE), for new categories and accounts.
    static let palette = ["#3b82f6", "#ec4899", "#8b5cf6", "#14b8a6", "#f97316", "#84cc16",
                          "#06b6d4", "#a855f7", "#eab308", "#64748b"]

    /// The first palette color nobody uses yet.
    static func next(used: [String]) -> String {
        let taken = Set(used.map { $0.lowercased() })
        return palette.first { !taken.contains($0) } ?? palette[used.count % palette.count]
    }

    static func color(_ hex: String) -> Color {
        guard let (r, g, b) = components(hex) else { return .gray }
        return Color(.sRGB, red: r, green: g, blue: b)
    }

    static func components(_ hex: String) -> (Double, Double, Double)? {
        let text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    /// A color as "#rrggbb" in sRGB.
    static func hex(_ color: Color) -> String {
        let resolved = color.resolve(in: EnvironmentValues())
        func byte(_ linear: Float) -> Int {
            // Resolved components are linear: back to sRGB's gamma.
            let v = Double(max(0, min(1, linear)))
            let srgb = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
            return Int((srgb * 255).rounded())
        }
        return String(format: "#%02x%02x%02x", byte(resolved.linearRed), byte(resolved.linearGreen), byte(resolved.linearBlue))
    }
}
