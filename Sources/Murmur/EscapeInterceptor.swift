import AppKit
import CoreGraphics

/// Esc cancels a dictation — but only while one is recording, and it is swallowed then, so the app being dictated into
/// doesn't also get an Esc it would act on (closing a sheet, leaving full screen). An event tap rather than an
/// `NSEvent` monitor, since a monitor can only watch keys, never stop one. It exists from `start()` to `stop()` —
/// just the length of a recording — and passes every other key through untouched. Needs Accessibility, which dictation
/// needs anyway; without it `start()` quietly does nothing.
final class EscapeInterceptor {
    var onEscape: () -> Void = {}

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: escapeTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS switches a tap off if it's ever slow; switch it straight back on for the rest of the recording.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        guard type == .keyDown,
              event.getIntegerValueField(.keyboardEventKeycode) == 53,
              event.flags.intersection(modifiers).isEmpty
        else { return Unmanaged.passUnretained(event) }
        DispatchQueue.main.async { [weak self] in self?.onEscape() }
        return nil
    }
}

private func escapeTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let interceptor = Unmanaged<EscapeInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
    return interceptor.handle(type: type, event: event)
}
