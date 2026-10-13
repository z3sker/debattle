import Foundation
import XCTest
@testable import Debattle

final class SpeechAvailabilityTests: XCTestCase {
    func testRuntimeCallbackDiagnosticUsesDomainAndCodeWithoutErrorDetails() {
        let error = NSError(domain: "kAFAssistantErrorDomain", code: 1101, userInfo: [
            NSLocalizedDescriptionKey: "Private recognized speech must not appear",
            NSLocalizedFailureReasonErrorKey: "Private file path must not appear",
            "transcript": "Private transcript must not appear"
        ])
        let message = SpeechFailureDiagnostic.message(domain: error.domain, code: error.code, isSimulator: false)
        XCTAssertTrue(message.hasPrefix("On-device speech recognition stopped."))
        XCTAssertTrue(message.hasSuffix("Diagnostic: kAFAssistantErrorDomain (1101)."))
        XCTAssertFalse(message.contains("Private"))
    }

    func testDiagnosticRejectsMissingOrUntrustedDomainsInsteadOfExposingTheirText() {
        let domains: [String?] = [nil, "", " ", "Private recognized speech", "kAF\nPrivateText",
                                  "file:///private/transcript", "<script>private</script>",
                                  "SpeechError\u{202E}private", "Ошибка", String(repeating: "a", count: 65)]
        for domain in domains {
            XCTAssertEqual(SpeechFailureDiagnostic.identifier(domain: domain, code: -7), "SpeechError (-7)")
        }
    }

    func testDiagnosticPreservesBoundedIdentifierDomainsAndSignedCodes() {
        for domain in ["kLSRErrorDomain", "SFSpeechErrorDomain", "NSOSStatusErrorDomain",
                       "com.apple.speech_error-v2", String(repeating: "a", count: 64)] {
            XCTAssertEqual(SpeechFailureDiagnostic.identifier(domain: domain, code: -10868), "\(domain) (-10868)")
        }
    }

    func testSimulatorAndDeviceFailuresShareDiagnosticWithoutConfusingTheirExplanations() {
        let simulatorMessage = SpeechFailureDiagnostic.message(domain: "kLSRErrorDomain", code: 102, isSimulator: true)
        let deviceMessage = SpeechFailureDiagnostic.message(domain: "kLSRErrorDomain", code: 102, isSimulator: false)
        XCTAssertTrue(simulatorMessage.contains("this simulator"))
        XCTAssertFalse(deviceMessage.contains("simulator"))
        XCTAssertTrue(simulatorMessage.hasSuffix("Diagnostic: kLSRErrorDomain (102)."))
        XCTAssertTrue(deviceMessage.hasSuffix("Diagnostic: kLSRErrorDomain (102)."))
    }

    func testTemporaryServiceFailureIsNotReportedAsMissingOnDeviceLanguageSupport() {
        let capability = SpeechCapability.classify(language: "Russian", recognizerExists: true,
            supportsOnDeviceRecognition: true, isAvailable: false)
        XCTAssertEqual(capability, .temporarilyUnavailable("Russian"))
        XCTAssertEqual(capability.error, .temporarilyUnavailable("Russian"))
        XCTAssertFalse(capability.isAvailable)
        XCTAssertTrue(capability.message.contains("Try again later"))
    }

    func testOnDeviceSupportAndServiceAvailabilityAreIndependent() {
        let cases: [(Bool, Bool, SpeechCapability)] = [
            (false, false, .onDeviceUnavailable("Spanish")),
            (false, true, .onDeviceUnavailable("Spanish")),
            (true, false, .temporarilyUnavailable("Spanish")),
            (true, true, .available)
        ]
        for (onDevice, available, expected) in cases {
            XCTAssertEqual(SpeechCapability.classify(language: "Spanish", recognizerExists: true,
                supportsOnDeviceRecognition: onDevice, isAvailable: available), expected)
        }
        XCTAssertNil(SpeechCapability.available.error)
        XCTAssertTrue(SpeechCapability.available.isAvailable)
    }

    func testUnsupportedRequestedLocaleCannotUseAnAvailableKeyboardFallback() {
        // Simulates Apple's initializer returning an English recognizer for an
        // unsupported Kazakh request. The requested locale must still be rejected.
        let supported: Set<String> = ["en-US", "ru-RU", "es-ES"]
        let capability = SpeechCapability.classify(language: "Kazakh",
            localeSupported: SpeechCapability.supportsLocale("kk-KZ", in: supported), recognizerExists: true,
            supportsOnDeviceRecognition: true, isAvailable: true)
        XCTAssertEqual(capability, .unsupportedLanguage("Kazakh"))
        XCTAssertEqual(capability.error, .unsupportedLanguage("Kazakh"))
    }

    func testMissingRecognizerNeverReportsAnAvailableService() {
        for onDevice in [false, true] {
            for available in [false, true] {
                XCTAssertEqual(SpeechCapability.classify(language: "Unknown", recognizerExists: false,
                    supportsOnDeviceRecognition: onDevice, isAvailable: available), .unsupportedLanguage("Unknown"))
            }
        }
    }

    func testLocaleMatchingNormalizesSeparatorsButDoesNotSubstituteRegionOrLanguage() {
        let supported: Set<String> = ["en_US", "ru_RU", "es_ES", "zh_Hans_CN"]
        XCTAssertTrue(SpeechCapability.supportsLocale("EN-us", in: supported))
        XCTAssertTrue(SpeechCapability.supportsLocale("ru-RU", in: supported))
        XCTAssertTrue(SpeechCapability.supportsLocale("zh-Hans-CN", in: supported))
        XCTAssertTrue(SpeechCapability.supportsLocale("ZH_hAnS_cn", in: ["zh-Hans-CN"]))
        XCTAssertFalse(SpeechCapability.supportsLocale("en-GB", in: supported))
        XCTAssertFalse(SpeechCapability.supportsLocale("kk-KZ", in: supported))
        XCTAssertFalse(SpeechCapability.supportsLocale("zh-Hant-TW", in: supported))
        XCTAssertFalse(SpeechCapability.supportsLocale("zh-Hant-CN", in: supported))
    }

    @MainActor
    func testPriorityLanguageNamesAliasesAndExplicitLocales() {
        let cases = [
            "English": "en-US", " en ": "en-US", "RUSSIAN": "ru-RU", "русский": "ru-RU",
            "Spanish": "es-ES", "español": "es-ES", "Kazakh": "kk-KZ", "қазақша": "kk-KZ",
            "French": "fr-FR", "German": "de-DE", "Arabic": "ar-SA", "Chinese": "zh-CN",
            "Japanese": "ja-JP", "Portuguese": "pt-BR", "Hindi": "hi-IN", "Turkish": "tr-TR",
            "en-GB": "en-GB", " pt-PT ": "pt-PT", "unknown-locale": "unknown-locale"
        ]
        for (language, identifier) in cases {
            XCTAssertEqual(SpeechTranscriber.localeIdentifier(for: language), identifier, language)
        }
    }

    func testCapabilityErrorsKeepSameActionableExplanationWithoutClaimingAIEnablesSpeech() {
        let capabilities: [SpeechCapability] = [.unsupportedLanguage("Kazakh"), .onDeviceUnavailable("Russian"), .temporarilyUnavailable("Spanish")]
        for capability in capabilities {
            XCTAssertEqual(capability.error?.localizedDescription, capability.message)
            XCTAssertTrue(capability.message.lowercased().contains("voice"))
            XCTAssertTrue(capability.message.contains("paste a speech"))
            XCTAssertFalse(capability.message.contains("Enable Apple Intelligence"))
        }
    }
}
