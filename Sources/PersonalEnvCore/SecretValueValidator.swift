import Foundation

public enum SecretValueValidator {
    private static let redactionBullet = UnicodeScalar(0x2022)!
    private static let minimumPlaceholderRunLength = 3

    public static func validate(_ variable: EnvVariable) throws {
        try validate(value: variable.value, key: variable.key)
    }

    public static func validate(value: String, key: String) throws {
        guard !value.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            throw PersonalEnvError.invalidRequest("\(key) cannot contain line breaks because dotenv exports must preserve one assignment per approved key.")
        }
        guard !containsRedactedPlaceholder(value) else {
            throw PersonalEnvError.invalidRequest("\(key) looks like a redacted placeholder. Paste the unmasked secret value instead.")
        }
    }

    public static func containsRedactedPlaceholder(_ value: String) -> Bool {
        var runLength = 0
        for scalar in value.unicodeScalars {
            if scalar == redactionBullet {
                runLength += 1
                if runLength >= minimumPlaceholderRunLength {
                    return true
                }
            } else {
                runLength = 0
            }
        }
        return false
    }
}
