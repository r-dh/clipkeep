import AppKit
import Carbon.HIToolbox

/// Global ⇧⌘C via Carbon's RegisterEventHotKey, which needs no Accessibility permission.
/// The key code follows the active keyboard layout, so the shortcut is the "C" key on AZERTY/Dvorak too.
@MainActor
final class HotKey {
  static let character: Character = "c"
  static let modifiers: NSEvent.ModifierFlags = [.command, .shift]
  static let display = "⇧⌘C"

  var onPress: (() -> Void)?
  private(set) var keyCode = UInt32(kVK_ANSI_C)
  private(set) var isRegistered = false
  private var hotKeyRef: EventHotKeyRef?
  private var handlerRef: EventHandlerRef?

  init() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
      guard let userData else { return noErr }
      let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
      MainActor.assumeIsolated { hotKey.onPress?() }
      return noErr
    }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

    DistributedNotificationCenter.default().addObserver(
      forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.isRegistered else { return }
        self.unregister()
        self.register()
      }
    }
  }

  @discardableResult
  func register() -> Bool {
    guard !isRegistered else { return true }
    keyCode = Self.keyCode(for: Self.character) ?? UInt32(kVK_ANSI_C)
    let id = EventHotKeyID(signature: OSType(0x434C_504B), id: 1) // "CLPK"
    let status = RegisterEventHotKey(keyCode, UInt32(cmdKey | shiftKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    isRegistered = status == noErr
    if !isRegistered { NSLog("Clipkeep: could not register %@ (status %d)", Self.display, status) }
    return isRegistered
  }

  func unregister() {
    if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    hotKeyRef = nil
    isRegistered = false
  }

  func matches(_ event: NSEvent) -> Bool {
    UInt32(event.keyCode) == keyCode
      && event.modifierFlags.intersection([.command, .shift, .option, .control]) == Self.modifiers
  }

  /// Finds the physical key that types `character` in the current layout (what the Sauce package does for Maccy).
  private static func keyCode(for character: Character) -> UInt32? {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    return layoutData.withUnsafeBytes { buffer -> UInt32? in
      guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
      for code in 0..<UInt16(128) {
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        if status == noErr, length == 1, Character(UnicodeScalar(chars[0]) ?? " ") == character {
          return UInt32(code)
        }
      }
      return nil
    }
  }
}
