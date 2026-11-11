import Foundation
import IOKit.hid

let vendorID = 0x046D, productID = 0xB369
let devIdx: UInt8 = 0xFF, swid: UInt8 = 0x0A
let yedekYolu = NSHomeDirectory() + "/Library/Application Support/MiX-Key/backlight-yedek.txt"

var stop = false
signal(SIGINT) { _ in stop = true }
signal(SIGTERM) { _ in stop = true }

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: productID] as CFDictionary)
guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let dev = set.first else {
    print("Klavye bulunamadı"); exit(1)
}
guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
    print("Aygıt açılamadı"); exit(2)
}

var reply: [UInt8]?
var hataKodu: UInt8?
var pending: (feat: UInt8, fn: UInt8)?
let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

let callback: IOHIDReportCallback = { _, _, _, _, _, report, length in
    let r = Array(UnsafeBufferPointer(start: report, count: length))
    guard let p = pending, r.count >= 6, r[0] == 0x11 || r[0] == 0x10 else { return }
    let fnSw = (p.fn << 4) | swid
    if r[2] == p.feat && r[3] == fnSw { reply = Array(r[4...]) }
    else if r[2] == 0xFF && r[3] == p.feat && r[4] == fnSw { hataKodu = r[5]; reply = [] }
}
IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, callback, nil)

func request(_ feat: UInt8, _ fn: UInt8, _ params: [UInt8] = []) -> [UInt8]? {
    var msg: [UInt8] = [0x11, devIdx, feat, (fn << 4) | swid] + params
    msg += [UInt8](repeating: 0, count: 20 - msg.count)
    reply = nil; hataKodu = nil; pending = (feat, fn)
    let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x11, msg, msg.count)
    if r != kIOReturnSuccess { print(String(format: "SetReport hata 0x%08x", r)); return nil }
    let deadline = Date().addingTimeInterval(2)
    while reply == nil && Date() < deadline { CFRunLoopRunInMode(.defaultMode, 0.005, true) }
    pending = nil
    if let k = hataKodu { print(String(format: "HID++ hata 0x%02x (fn %d)", k, fn)); return nil }
    return reply
}

func bekle(_ s: Double) {
    let d = Date().addingTimeInterval(s)
    while !stop && Date() < d { CFRunLoopRunInMode(.defaultMode, 0.01, true) }
}

func medyan(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.sorted()[a.count / 2] }

guard let r = request(0x00, 0x0, [0x19, 0x82]), r[0] != 0 else { print("Backlight2 yok"); exit(3) }
let idx = r[0]

func ayarAyni(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    a[0] == b[0] && a[1] == b[1] && Array(a[6...11]) == Array(b[6...11])
}

func geriAl(_ b: [UInt8]) -> Bool {
    guard request(idx, 0x1, [b[0], b[1], 0xFF, b[5]] + Array(b[6...11])) != nil,
          let son = request(idx, 0x0) else { print("Geri alma başarısız"); return false }
    print("Son ayar:  \(hex(Array(son[0..<12])))")
    print("Yedek:     \(hex(b))")
    return ayarAyni(son, b)
}

func yedegiOku() -> [UInt8]? {
    guard let s = try? String(contentsOfFile: yedekYolu, encoding: .utf8) else { return nil }
    let b = s.split(whereSeparator: \.isWhitespace).compactMap { UInt8($0, radix: 16) }
    return b.count == 12 ? b : nil
}

if CommandLine.arguments.contains("geri") {
    guard let b = yedegiOku() else { print("Yedek yok"); exit(4) }
    print(geriAl(b) ? "Geri alındı" : "Geri alma doğrulanamadı")
    exit(0)
}

guard let simdi = request(idx, 0x0) else { print("Ayar okunamadı"); exit(5) }
let yedek: [UInt8]
if let eski = yedegiOku() {
    yedek = eski
    print("Var olan yedek kullanılıyor: \(hex(yedek))")
} else {
    yedek = Array(simdi[0..<12])
    try! (hex(yedek) + "\n").write(toFile: yedekYolu, atomically: true, encoding: .utf8)
    print("Yedek yazıldı: \(hex(yedek))")
}

var yazmaMs: [Double] = []
func seviye(_ l: UInt8) -> Bool {
    let t = Date()
    let opt = (yedek[1] & 0x07) | (3 << 3)
    let ok = request(idx, 0x1, [1, opt, 0xFF, l] + Array(yedek[6...11])) != nil
    if ok { yazmaMs.append(Date().timeIntervalSince(t) * 1000) }
    return ok
}

bekle(5)

print("\nAdım testi (seviye başına 1.2 sn)")
for l: UInt8 in 0...7 where !stop {
    let ok = seviye(l)
    bekle(0.3)
    let oku = request(idx, 0x0)
    print("  yaz \(l): \(ok ? "tamam" : "RED"), okunan seviye \(oku.map { String($0[5]) } ?? "?")")
    bekle(0.9)
}

print("\nHızlı açıp kapama (0 ve 7, 4 sn)")
var d: UInt8 = 0
let t1 = Date()
var n1 = 0
while !stop && Date().timeIntervalSince(t1) < 4 {
    if seviye(d) { n1 += 1 }
    d = d == 0 ? 7 : 0
    bekle(0.125)
}
print("  \(n1) yazma")

print("\nDolu hız tarama (0-7-0, 4 sn)")
let t2 = Date()
var n2 = 0, adim = 0
while !stop && Date().timeIntervalSince(t2) < 4 {
    let f = adim % 14
    if seviye(UInt8(f <= 7 ? f : 14 - f)) { n2 += 1 }
    adim += 1
}
print(String(format: "  %d yazma, saniyede %.1f", n2, Double(n2) / Date().timeIntervalSince(t2)))
print(String(format: "\nYazma gidiş-dönüş: medyan %.1f ms, max %.1f ms", medyan(yazmaMs), yazmaMs.max() ?? 0))

stop = false
print("\nGeri alınıyor")
print(geriAl(yedek) ? "Geri alındı" : "Geri alma doğrulanamadı, `swift isik-test.swift geri` çalıştır")
