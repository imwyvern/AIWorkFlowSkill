import ApplicationServices
import AppKit
import Foundation
import CoreGraphics

func getCodexPID() -> pid_t? {
    for app in NSWorkspace.shared.runningApplications {
        if app.localizedName == "Codex" || app.localizedName == "Codex Desktop" {
            return app.processIdentifier
        }
    }
    return nil
}

func listWindows() {
    guard let pid = getCodexPID() else { print("NO_CODEX"); return }
    let app = AXUIElementCreateApplication(pid)
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &ref) == .success,
          let windows = ref as? [AXUIElement] else {
        print("AX_ERROR")
        return
    }
    for win in windows {
        var tRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, "AXTitle" as CFString, &tRef)
        let title = tRef as? String ?? ""
        print("WINDOW|\(title)")
    }
}

func activateWindow(_ match: String) {
    guard let pid = getCodexPID() else { print("NO_CODEX"); return }
    
    // Activate the app
    for app in NSWorkspace.shared.runningApplications {
        if app.processIdentifier == pid {
            app.activate()
            break
        }
    }
    Thread.sleep(forTimeInterval: 0.5)
    
    let axApp = AXUIElementCreateApplication(pid)
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, "AXWindows" as CFString, &ref) == .success,
          let windows = ref as? [AXUIElement] else {
        print("AX_ERROR")
        return
    }
    
    for win in windows {
        var tRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, "AXTitle" as CFString, &tRef)
        let title = tRef as? String ?? ""
        if title.lowercased().contains(match.lowercased()) {
            AXUIElementPerformAction(win, "AXRaise" as CFString)
            print("ACTIVATED|\(title)")
            return
        }
    }
    print("NOT_FOUND|\(match)")
}

func getForeground() {
    guard let pid = getCodexPID() else { print("NO_CODEX"); return }
    for app in NSWorkspace.shared.runningApplications {
        if app.processIdentifier == pid && app.isActive {
            let axApp = AXUIElementCreateApplication(pid)
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, "AXFocusedWindow" as CFString, &ref) == .success {
                var tRef: CFTypeRef?
                AXUIElementCopyAttributeValue(ref as! AXUIElement, "AXTitle" as CFString, &tRef)
                print("FOREGROUND|\(tRef as? String ?? "")")
            } else {
                print("NO_FOCUSED_WINDOW")
            }
            return
        }
    }
    print("NOT_FRONTMOST")
}

func sendText(_ text: String, to match: String) {
    // 1. Activate window
    guard let pid = getCodexPID() else { print("NO_CODEX"); return }
    
    for app in NSWorkspace.shared.runningApplications {
        if app.processIdentifier == pid {
            app.activate()
            break
        }
    }
    Thread.sleep(forTimeInterval: 0.5)
    
    // 2. Raise matching window (with single-window fallback)
    let axApp = AXUIElementCreateApplication(pid)
    var ref: CFTypeRef?
    var matched = false
    if AXUIElementCopyAttributeValue(axApp, "AXWindows" as CFString, &ref) == .success,
       let windows = ref as? [AXUIElement] {
        // Try exact match first
        for win in windows {
            var tRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, "AXTitle" as CFString, &tRef)
            let title = tRef as? String ?? ""
            if title.lowercased().contains(match.lowercased()) {
                AXUIElementPerformAction(win, "AXRaise" as CFString)
                matched = true
                break
            }
        }
        // Fallback: if only one window, use it regardless of title
        if !matched && windows.count == 1 {
            AXUIElementPerformAction(windows[0], "AXRaise" as CFString)
            matched = true
        }
        if !matched {
            print("NOT_FOUND|\(match)")
            return
        }
    }
    Thread.sleep(forTimeInterval: 0.5)
    
    // 3. Set clipboard
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    
    // 4. Send Cmd+V via CGEvent
    guard let source = CGEventSource(stateID: .hidSystemState) else {
        print("EVENT_SOURCE_ERROR")
        return
    }
    
    // Cmd+V (keycode 9)
    if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
       let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) {
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        keyUp.post(tap: .cghidEventTap)
    }
    
    Thread.sleep(forTimeInterval: 0.5)
    
    // 5. Send Return (keycode 36)
    if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
       let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) {
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        keyUp.post(tap: .cghidEventTap)
    }
    
    print("SENT|\(text)")
}

// Main
let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Usage: ax_helper [list|activate TITLE|foreground|send TEXT PROJECT]")
    exit(1)
}

switch args[1] {
case "list": listWindows()
case "activate":
    guard args.count >= 3 else { print("Need TITLE"); exit(1) }
    activateWindow(args[2])
case "foreground": getForeground()
case "send":
    guard args.count >= 4 else { print("Need TEXT and PROJECT"); exit(1) }
    sendText(args[2], to: args[3])
default:
    print("Unknown: \(args[1])")
    exit(1)
}
