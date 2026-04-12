#!/usr/bin/env swift
// Detector de teclas — aperte qualquer tecla e veja exatamente o nome dela
// Uso: swift keymonitor.swift

import Cocoa

func modName(_ raw: UInt64, _ flags: CGEventFlags) -> String {
    var parts: [String] = []
    if raw & 0x00000001 != 0 { parts.append("L-CONTROL ⌃") }
    if raw & 0x00002000 != 0 { parts.append("R-CONTROL ⌃") }
    if raw & 0x00000002 != 0 { parts.append("L-SHIFT ⇧") }
    if raw & 0x00000004 != 0 { parts.append("R-SHIFT ⇧") }
    if raw & 0x00000008 != 0 { parts.append("L-COMMAND ⌘") }
    if raw & 0x00000010 != 0 { parts.append("R-COMMAND ⌘") }
    if raw & 0x00000020 != 0 { parts.append("L-OPTION ⌥") }
    if raw & 0x00000040 != 0 { parts.append("R-OPTION ⌥") }
    if flags.contains(.maskSecondaryFn) { parts.append("FN 🌐") }
    if parts.isEmpty { return "(nenhuma)" }
    return parts.joined(separator: " + ")
}

guard AXIsProcessTrusted() else {
    print("❌ Acessibilidade não habilitada para Terminal/Claude.")
    print("   Vá em: Configurações → Privacidade → Acessibilidade → habilite Terminal ou Claude")
    exit(1)
}

print("╔══════════════════════════════════════════╗")
print("║     DETECTOR DE TECLAS - VoiceDict       ║")
print("╠══════════════════════════════════════════╣")
print("║ Aperte qualquer tecla modificadora.      ║")
print("║ O nome exato dela vai aparecer aqui.     ║")
print("║                                          ║")
print("║ Ctrl+C para sair.                        ║")
print("╚══════════════════════════════════════════╝")
print("")

let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

let callback: CGEventTapCallBack = { proxy, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        return Unmanaged.passUnretained(event)
    }
    let raw = event.flags.rawValue
    let desc = modName(raw, event.flags)
    if desc != "(nenhuma)" {
        print("  🔑 Pressionado: \(desc)")
        print("     (raw: 0x\(String(raw, radix: 16)))")
        print("")
    }
    return Unmanaged.passUnretained(event)
}

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap, place: .headInsertEventTap,
    options: .listenOnly, eventsOfInterest: mask,
    callback: callback, userInfo: nil
) else {
    print("❌ Falha ao criar event tap")
    exit(1)
}

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
CFRunLoopRun()
