import Foundation

public enum DeckFormat {
    public static var locale: Locale { Strings.wordsLocale }

    public static func memory(_ bytes: Int64, locale: Locale = DeckFormat.locale) -> String {
        let gib = Double(bytes) / 1_073_741_824
        if gib >= 1 || bytes == 0 {
            return Measurement(value: bytes == 0 ? 0 : gib, unit: UnitInformationStorage.gibibytes)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: decimals(1, locale)).locale(locale))
        }
        return Measurement(value: Double(bytes) / 1_048_576, unit: UnitInformationStorage.mebibytes)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: decimals(0, locale)).locale(locale))
    }

    public static func disk(_ bytes: Int64, locale: Locale = DeckFormat.locale) -> String {
        bytes.formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale))
    }

    public static func throughput(bytesPerSecond: Double, locale: Locale = .current) -> String {
        tr("unit.perSecond", disk(Int64(max(0, bytesPerSecond).rounded()), locale: locale))
    }

    public static func count(_ value: Int, locale: Locale = DeckFormat.locale) -> String {
        value.formatted(.number.locale(locale))
    }

    public static func number(_ value: Double, fractionDigits: Int = 1, locale: Locale = DeckFormat.locale) -> String {
        value.formatted(decimals(fractionDigits, locale))
    }

    public static func tokensPerSecond(_ value: Double, locale: Locale = DeckFormat.locale) -> String {
        tr("unit.tokensPerSecond", number(value, fractionDigits: 1, locale: locale))
    }

    public static func percent(_ fraction: Double, locale: Locale = DeckFormat.locale) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    public static func duration(seconds: Double, locale: Locale = DeckFormat.locale) -> String {
        Duration.seconds(max(0, seconds.rounded()))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2).locale(locale))
    }

    public static func latency(milliseconds: Double, locale: Locale = DeckFormat.locale) -> String {
        let narrow = Measurement<UnitDuration>.FormatStyle.UnitWidth.narrow
        if milliseconds < 1000 {
            return Measurement(value: milliseconds.rounded(), unit: UnitDuration.milliseconds)
                .formatted(.measurement(width: narrow, usage: .asProvided, numberFormatStyle: decimals(0, locale)).locale(locale))
        }
        return Measurement(value: milliseconds / 1000, unit: UnitDuration.seconds)
            .formatted(.measurement(width: narrow, usage: .asProvided, numberFormatStyle: decimals(1, locale)).locale(locale))
    }

    public static func moment(_ date: Date, now: Date = .now, locale: Locale = DeckFormat.locale, calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
        if !calendar.isDate(date, inSameDayAs: now) {
            style = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
        }
        return date.formatted(style)
    }

    public static func ago(_ date: Date, now: Date = .now, locale: Locale = DeckFormat.locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }

    public static func dateTime(_ date: Date, locale: Locale = DeckFormat.locale) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }

    public static func elapsed(since date: Date, now: Date = .now, locale: Locale = DeckFormat.locale) -> String {
        duration(seconds: now.timeIntervalSince(date), locale: locale)
    }

    public static func clause(_ sentence: String) -> String {
        sentence.hasSuffix(".") && !sentence.hasSuffix("..") ? String(sentence.dropLast()) : sentence
    }

    public static func port(_ port: Int) -> String {
        ":" + String(port)
    }

    private static func decimals(_ digits: Int, _ locale: Locale) -> FloatingPointFormatStyle<Double> {
        FloatingPointFormatStyle<Double>(locale: locale).precision(.fractionLength(digits))
    }
}
