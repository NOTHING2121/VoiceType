import AppKit
import ApplicationServices
import Carbon.HIToolbox
import VoiceTypeCore

/// Thin, bounded Accessibility helpers. Every call uses a short messaging timeout.
public enum AXSupport {
    public static var isTrusted: Bool { AXIsProcessTrusted() }
    static let messagingTimeout: Float = 0.25

    static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    /// Focused element of the frontmost app (falls back to the system-wide element).
    public static func focusedElement(pid: pid_t?) -> AXUIElement? {
        guard isTrusted else { return nil }
        var roots: [AXUIElement] = []
        if let pid = pid, pid > 0 { roots.append(AXUIElementCreateApplication(pid)) }
        roots.append(AXUIElementCreateSystemWide())
        for root in roots {
            AXUIElementSetMessagingTimeout(root, messagingTimeout)
            if let value = copy(root, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
                let element = value as! AXUIElement
                AXUIElementSetMessagingTimeout(element, messagingTimeout)
                return element
            }
        }
        return nil
    }

    public static func subrole(_ element: AXUIElement) -> String? { copy(element, kAXSubroleAttribute) as? String }

    public static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    public static func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let value = copy(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    public static func characterCount(_ element: AXUIElement) -> Int? {
        if let count = copy(element, kAXNumberOfCharactersAttribute) as? NSNumber { return count.intValue }
        if let value = copy(element, kAXValueAttribute) as? String { return (value as NSString).length }
        return nil
    }

    /// Limited read at the insertion point; never feeds a model, log, or history.
    public static func string(_ element: AXUIElement, location: Int, length: Int) -> String? {
        guard location >= 0, length >= 0 else { return nil }
        var range = CFRange(location: location, length: length)
        if let axRange = AXValueCreate(.cfRange, &range) {
            var value: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, axRange, &value) == .success,
               let text = value as? String { return text }
        }
        guard let whole = copy(element, kAXValueAttribute) as? String else { return nil }
        let ns = whole as NSString
        guard ns.length <= 200_000, location + length <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: location, length: length))
    }

    public static func snapshot(_ element: AXUIElement) -> TextFieldSnapshot? {
        guard let range = selectedRange(element) else { return nil }
        return TextFieldSnapshot(selectionLocation: range.location, selectionLength: range.length, characterCount: characterCount(element))
    }

    public static func observe(_ element: AXUIElement, before: TextFieldSnapshot, text: String) -> InsertionObservation {
        InsertionVerifier.evaluate(before: before, after: snapshot(element),
                                   slice: string(element, location: before.selectionLocation, length: text.utf16.count), text: text)
    }
}

/// Only two explicit danger signals block delivery; missing AX data is NOT a block.
public enum SafetyProbe {
    public static var secureEventInputEnabled: Bool { IsSecureEventInputEnabled() == true }

    public static func current(pid: pid_t?) -> SafetySignals {
        let secureField: Bool? = AXSupport.focusedElement(pid: pid).map {
            AXSupport.subrole($0) == (kAXSecureTextFieldSubrole as String)
        }
        return SafetySignals(secureTextField: secureField, secureEventInput: secureEventInputEnabled)
    }
}
