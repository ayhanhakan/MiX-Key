import SwiftUI
import Accelerate
import AppKit
import Carbon
import IOKit.hid
import ScreenCaptureKit
import CoreMedia
import ServiceManagement

let destekDizini = NSHomeDirectory() + "/Library/Application Support/MiX-Key"
let yedekYolu = destekDizini + "/backlight-yedek.txt"
let izinYolu = destekDizini + "/izin-durumu.txt"

enum Mod: String, CaseIterable, Identifiable {
    case soft = "Soft", medium = "Medium", hard = "Hard", nefes = "Nefes"

    var id: String { rawValue }

    var sonus: Float {
        switch self {
        case .soft, .nefes: return 0.88
        case .medium: return 0.7
        case .hard: return 0.5
        }
    }

    var alt: Float {
        switch self {
        case .soft, .nefes: return 0
        case .medium: return 0.15
        case .hard: return 0.35
        }
    }

    var ust: Float {
        switch self {
        case .soft, .nefes: return 1
        case .medium: return 0.85
        case .hard: return 0.7
        }
    }

    func seviye(_ oran: Float, _ hassasiyet: Float) -> UInt8 {
        let p = pencere(hassasiyet)
        let x = max(0, min((oran - p.alt) / (p.ust - p.alt), 1))
        return UInt8(taban + (x * (7 - taban)).rounded())
    }

    func pencere(_ hassasiyet: Float) -> (alt: Float, ust: Float) {
        let kayma = (0.5 - hassasiyet) * 0.8
        let a = max(0, min(alt + kayma, 0.85))
        return (a, max(a + 0.15, min(ust + kayma, 1)))
    }

    var taban: Float { self == .soft ? 1 : 0 }

    var ikon: String {
        switch self {
        case .soft: return "water.waves"
        case .medium: return "waveform"
        case .hard: return "bolt.fill"
        case .nefes: return "wind"
        }
    }
}

enum Bant: String, CaseIterable, Identifiable {
    case bas = "Bas", orta = "Orta", tiz = "Tiz", hepsi = "Hepsi"

    var id: String { rawValue }

    // 48 kHz'de tek kutuplu katsayı: 1 - exp(-2π fc / fs); 0 = alt kesim yok, 1 = üst kesim yok
    var altKatsayi: Float {
        switch self {
        case .bas, .hepsi: return 0
        case .orta: return 0.0385  // 300 Hz
        case .tiz: return 0.4076  // 4 kHz
        }
    }

    func icinde(_ hz: Float, kesim: Float) -> Bool {
        switch self {
        case .bas: return hz <= basHz(kesim)
        case .orta: return (300...3000).contains(hz)
        case .tiz: return hz >= 4000
        case .hepsi: return true
        }
    }

    var ustKatsayi: Float {
        switch self {
        case .orta: return 0.3247  // 3 kHz
        case .bas, .tiz, .hepsi: return 1
        }
    }
}

struct Ayarlar {
    var mod: Mod
    var hassasiyet: Float = 0.5
    var bant = Bant.bas
    var askida = false
    var yazarkenSabit = true
    var yazarkenIsik: Float = 1
    var sonus: Float = 0.5
    var darbe: Float = 1
    var basKesim = Float(60) / 190
    var spektrumAcik = false
}

func basHz(_ kesim: Float) -> Float { 60 + 190 * kesim }
func darbeSn(_ darbe: Float) -> Float { 0.15 + 0.12 * darbe }

struct AltGecis {
    private let b0, b1, a1, a2: Float
    private var z1: Float = 0
    private var z2: Float = 0

    init(hz: Float, q: Float) {
        let w = 2 * Float.pi * hz / 48000
        let al = sin(w) / (2 * q)
        let n = 1 + al
        b0 = (1 - cos(w)) / 2 / n
        b1 = (1 - cos(w)) / n
        a1 = -2 * cos(w) / n
        a2 = (1 - al) / n
    }

    mutating func isle(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b0 * x - a2 * y
        return y
    }
}

struct BantFiltre {
    let bant: Bant
    let kesim: Float
    private var alt: Float = 0
    private var ust: Float = 0
    // 4. derece Butterworth: tek kutuplu filtrede vokal ve gitar basa karışır
    private var dusuk1: AltGecis
    private var dusuk2: AltGecis

    init(bant: Bant, kesim: Float = Float(60) / 190) {
        self.bant = bant
        self.kesim = kesim
        dusuk1 = AltGecis(hz: basHz(kesim), q: 0.5412)
        dusuk2 = AltGecis(hz: basHz(kesim), q: 1.3066)
    }

    mutating func isle(_ x: Float) -> Float {
        if bant == .bas { return dusuk2.isle(dusuk1.isle(x)) }
        alt += bant.altKatsayi * (x - alt)
        ust += bant.ustKatsayi * (x - ust)
        return ust - alt
    }
}

// 120 BPM'de ışık kısa açık kalmada karanlıkta, uzunda tepede takılıyor, 0,27 ikisinin sınırında
struct Darbe {
    var cikis: UInt8 = 0
    var acik: Float = 0
    var onceki: UInt8 = 0
    var dusuk = 0

    mutating func ekle(_ l: UInt8, _ m: Mod, _ dt: Float, sonus: Float = 0, darbe: Float = 1) -> UInt8 {
        defer { onceki = l }
        guard m != .soft else {
            cikis = l
            return l
        }
        acik += dt
        let sure = darbeSn(darbe) + 0.5 * sonus * sonus
        dusuk = l * 2 <= cikis ? dusuk + 1 : 0
        if l > cikis && l > onceki {
            cikis = l
            acik = 0
        } else if l < cikis && acik >= sure {
            // Uzun notada tek tiklik düşüş ışığı anlık karartıyordu
            if dusuk >= 2 {
                cikis = 0
            } else if l * 2 > cikis && acik >= sure * 2 {
                cikis = l
                acik = 0
            }
        }
        return cikis
    }
}

// Telefon videolarından ölçüldü: seviye başına görünen parlaklık
let ledEgri: [Double] = [0, 0.62, 0.72, 0.78, 0.83, 0.86, 0.92, 1]

struct LedModel {
    var v: Double = 0

    // İki videoya oturtuldu: yükselme 0,8 sn doğrusal, düşüş tepede yavaş, 0,7 altında saniyede 2,1
    mutating func ilerle(_ hedef: UInt8, _ dt: Double) -> Double {
        let h = ledEgri[Int(hedef)]
        if h > v {
            v = min(h, v + dt / 0.8)
        } else if h < v {
            v = max(h, v - dt * (v <= 0.7 ? 2.1 : 0.15 + 1.95 * (1 - v) / 0.3))
        }
        return v
    }
}

struct Izleyici {
    var darbe = Darbe()
    var tepe: Float = 0.005
    var dip: Float = 0
    var zarf: Float = 0
    var tutma: Float = 0
    var oran: Float = 0

    mutating func ekle(_ rms: Float, _ m: Mod, _ hassasiyet: Float = 0.5, _ dt: Float = 0.09, sonus: Float = 0.5) -> UInt8 {
        let adim = dt / 0.09
        if rms > zarf {
            zarf = rms
            tutma = 0.09  // 21 ms'lik tampon bas dalgasını tek başına dalgalı ölçüyor
        } else if tutma > 0 {
            tutma -= dt
        } else {
            zarf *= pow(m.sonus, adim * pow(4, 1 - 2 * sonus))
        }
        tepe = max(rms, tepe * pow(0.98, adim), 0.005)
        dip = zarf < dip ? zarf : dip + (zarf - dip) * (1 - exp(-dt / 2))
        guard zarf >= 0.005 else {
            oran = 0
            return 0
        }
        // Sıkıştırılmış müzikte zarf tepeye yakın gezer, ölçek zarfın kendi dibinden başlamazsa ışık tek seviyede takılır
        let taban = min(dip, tepe * 0.85)
        oran = max(0, min((zarf - taban) / (tepe - taban), 1))
        return m.seviye(oran, hassasiyet)
    }

    mutating func darbeli(_ rms: Float, _ m: Mod, _ hassasiyet: Float, _ dt: Float, sonus: Float, darbe d: Float = 1) -> UInt8 {
        darbe.ekle(ekle(rms, m, hassasiyet, dt, sonus: sonus), m, dt, sonus: sonus, darbe: d)
    }
}

func etkiSeviyeleri(_ m: Mod, _ h: Float, _ s: Float, _ d: Float = 1) -> [UInt8] {
    if m == .nefes { return (0..<150).map { nefesSeviye(Double($0) * 0.02) } }
    var i = Izleyici()
    let l = (0..<400).map { t -> UInt8 in i.darbeli(t % 25 < 3 ? 0.3 : 0.06, m, h, 0.02, sonus: s, darbe: d) }
    return Array(l.suffix(150))
}

func spektrumHz(_ i: Int) -> Float { 30 * pow(Float(16000) / 30, (Float(i) + 0.5) / 32) }

final class Spektrum {
    private let kurulum = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!
    private let pencere = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: 2048, isHalfWindow: false)
    private let bas: [Int]
    private let son: [Int]
    private var halka = [Float](repeating: 0, count: 2048)
    private var gercek = [Float](repeating: 0, count: 1024)
    private var sanal = [Float](repeating: 0, count: 1024)
    private var guc = [Float](repeating: 0, count: 1024)
    private var cubuk = [Float](repeating: 0, count: 32)

    init() {
        let s = (0...32).map { i in Int(30 * pow(Float(16000) / 30, Float(i) / 32) / (48000 / 2048)) }
        bas = (0..<32).map { max(s[$0], 1) }
        son = (0..<32).map { max(s[$0 + 1], max(s[$0], 1) + 1) }
    }

    deinit { vDSP_destroy_fftsetup(kurulum) }

    func ekle(_ o: UnsafeBufferPointer<Float>) -> [Float] {
        if o.count >= 2048 {
            halka = Array(o.suffix(2048))
        } else {
            halka.removeFirst(o.count)
            halka.append(contentsOf: o)
        }
        let x = vDSP.multiply(halka, pencere)
        gercek.withUnsafeMutableBufferPointer { g in
            sanal.withUnsafeMutableBufferPointer { s in
                var z = DSPSplitComplex(realp: g.baseAddress!, imagp: s.baseAddress!)
                x.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &z, 1, 1024) }
                vDSP_fft_zrip(kurulum, &z, 1, 11, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&z, 1, &guc, 1, 1024)
            }
        }
        for i in 0..<32 {
            // 1048576: tam ölçek sinüsün Hann penceresinde zrip gücü
            let db = 10 * log10(max(guc[bas[i]..<son[i]].max() ?? 0, 1e-12) / 1048576)
            cubuk[i] = max(max(0, min((db + 70) / 60, 1)), cubuk[i] * 0.8)
        }
        return cubuk
    }
}

func nefesSeviye(_ t: TimeInterval) -> UInt8 {
    UInt8(((sin(2 * .pi * t / 4 - .pi / 2) + 1) / 2 * 7).rounded())
}

func yaziyor(_ simdi: Double, _ sonTus: Double) -> Bool { sonTus > 0 && simdi - sonTus < 2 }

func geceMi(_ saat: Int, _ bas: Int, _ bit: Int) -> Bool {
    if bas == bit { return false }
    return bas < bit ? (bas..<bit).contains(saat) : saat >= bas || saat < bit
}

let klavyeHatalari: Set<String> = ["Klavye yok", "Klavye cevap vermiyor", "Ayar okunamadı", "Klavye bağlantısı koptu"]

struct Sessizlik {
    enum Olay { case sensoreDon, geriGel }

    var baslangic: TimeInterval?
    var sensorde = false

    mutating func ekle(_ rms: Float, _ t: TimeInterval) -> Olay? {
        if rms >= 0.002 {
            baslangic = nil
            if sensorde {
                sensorde = false
                return .geriGel
            }
            return nil
        }
        let b = baslangic ?? t
        baslangic = b
        if !sensorde && t - b >= 5 {
            sensorde = true
            return .sensoreDon
        }
        return nil
    }
}

struct Pil {
    let yuzde: Int
    let seviyeBit: UInt8
    let sarjda: Bool

    var dusuk: Bool { !sarjda && (yuzde > 0 ? yuzde <= 10 : seviyeBit & 1 != 0) }
    var metin: String { (yuzde > 0 ? "Pil %\(yuzde)" : "Pil") + (sarjda ? ", şarjda" : "") }
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

// Backlight2 setConfig: açık, seçenek, efekt (FF değiştirmez), seviye, eller yokken, eller varken, güç süresi; seviye nil ise yedek
func ayarBaytlari(_ yedek: [UInt8], _ seviye: UInt8?) -> [UInt8] {
    guard let seviye else { return [yedek[0], yedek[1], 0xFF, yedek[5]] + Array(yedek[6...11]) }
    // shortcut: ışık en fazla 10 dk elsiz yanar (120 x 5 sn), üst sınır klavyede denenmedi
    return [1, (yedek[1] & 0x07) | (3 << 3), 0xFF, seviye, 120, 0, 120, 0] + Array(yedek[10...11])
}

// Otomatik kipte klavye seviyeyi ortam ışığına göre kendi seçip 0 bildiriyor, seviye yalnız elle kipte karşılaştırılır
func ayarAyni(_ okunan: [UInt8], _ yedek: [UInt8]) -> Bool {
    okunan[0] == yedek[0] && okunan[1] == yedek[1] && okunan[6...11] == yedek[6...11] && (yedek[1] >> 3 & 3 != 3 || okunan[5] == yedek[5])
}

final class Klavye {
    private let swid: UInt8
    private var manager: IOHIDManager?
    private var dev: IOHIDDevice?
    private var reply: [UInt8]?
    private var hataKodu: UInt8?
    private var pending: (feat: UInt8, fn: UInt8)?
    private let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    var tusGeldi: (() -> Void)?

    init(swid: UInt8) { self.swid = swid }

    deinit { buf.deallocate() }

    fileprivate func rapor(_ r: [UInt8]) {
        if r.first != 0x11 && r.first != 0x10 {
            tusGeldi?()
            return
        }
        guard let p = pending, r.count >= 6, r[0] == 0x11 || r[0] == 0x10 else { return }
        let fnSw = (p.fn << 4) | swid
        if r[2] == p.feat && r[3] == fnSw { reply = Array(r[4...]) }
        else if r[2] == 0xFF && r[3] == p.feat && r[4] == fnSw { hataKodu = r[5]; reply = [] }
    }

    func ac() -> String? {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 0x046D, kIOHIDProductIDKey: 0xB369] as CFDictionary)
        guard let set = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>, let d = set.first else { return "Klavye yok" }
        guard IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return "Giriş İzleme izni gerekli" }
        dev = d
        let cb: IOHIDReportCallback = { ctx, _, _, _, _, report, length in
            Unmanaged<Klavye>.fromOpaque(ctx!).takeUnretainedValue().rapor(Array(UnsafeBufferPointer(start: report, count: length)))
        }
        IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceRegisterInputReportCallback(d, buf, 64, cb, Unmanaged.passUnretained(self).toOpaque())
        return nil
    }

    func kapat() {
        guard let dev else { return }
        IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        self.dev = nil
    }

    func request(_ feat: UInt8, _ fn: UInt8, _ params: [UInt8] = []) -> [UInt8]? {
        guard let dev else { return nil }
        var msg: [UInt8] = [0x11, 0xFF, feat, (fn << 4) | swid] + params
        msg += [UInt8](repeating: 0, count: 20 - msg.count)
        reply = nil; hataKodu = nil; pending = (feat, fn)
        guard IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x11, msg, msg.count) == kIOReturnSuccess else { return nil }
        let deadline = Date().addingTimeInterval(1)
        while reply == nil && Date() < deadline { CFRunLoopRunInMode(.defaultMode, 0.005, true) }
        pending = nil
        return hataKodu == nil ? reply : nil
    }

    func ozellik(_ id: UInt16) -> UInt8? {
        guard let r = request(0x00, 0x0, [UInt8(id >> 8), UInt8(id & 0xFF)]), !r.isEmpty, r[0] != 0 else { return nil }
        return r[0]
    }
}

func pilOku() -> Pil? {
    let k = Klavye(swid: 0x0B)
    guard k.ac() == nil else { return nil }
    defer { k.kapat() }
    guard let i = k.ozellik(0x1004), let r = k.request(i, 0x1), r.count >= 3 else { return nil }
    return Pil(yuzde: Int(r[0]), seviyeBit: r[1], sarjda: (1...3).contains(r[2]))
}

final class Motor: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let grup = DispatchGroup()
    var bitince: ((String?) -> Void)?
    var baglandi: (() -> Void)?
    var sure: Double?
    private(set) var tik = 0, yazma = 0, hataSayisi = 0
    private(set) var dagilim = [Int](repeating: 0, count: 8)
    private(set) var enYuksek: Float = 0

    private let kilit = NSLock()
    private var _ayar: Ayarlar
    private var _dur = false
    private var _seviye: UInt8 = 0
    private var _iz = [Float](repeating: 0, count: 120)
    private var _isikIz = [UInt8](repeating: 0, count: 120)
    private var _spektrum = [Float](repeating: 0, count: 32)
    private lazy var spektrum = Spektrum()
    private var yeniSes = false
    private var sonTus: Double = 0
    private var anlikRMS: Float = 0
    private var anlikTam: Float = 0
    private var basladi = false
    private var akisHatasi: String?
    private var filtre = BantFiltre(bant: .bas)
    private let sesKuyrugu = DispatchQueue(label: "mixkey.ses")
    private let kaynak: String
    private var onceki: Motor?
    private let klavye = Klavye(swid: 0x0A)
    private var akis: SCStream?
    private var idx: UInt8 = 0
    private var yedek: [UInt8] = []

    init(ayar: Ayarlar, kaynak: String, onceki: Motor?) {
        _ayar = ayar
        self.kaynak = kaynak
        self.onceki = onceki
    }

    var ayar: Ayarlar {
        get { kilit.withLock { _ayar } }
        set { kilit.withLock { _ayar = newValue } }
    }

    private var dur: Bool { kilit.withLock { _dur } }

    var seviyeAnlik: UInt8 { kilit.withLock { _seviye } }

    var izAnlik: [Float] { kilit.withLock { _iz } }
    var isikIzAnlik: [UInt8] { kilit.withLock { _isikIz } }
    var spektrumAnlik: [Float] { kilit.withLock { _spektrum } }

    private func izleriSifirla() {
        kilit.withLock {
            _seviye = 0
            _iz = [Float](repeating: 0, count: 120)
            _isikIz = [UInt8](repeating: 0, count: 120)
        }
    }

    func durdur() { kilit.withLock { _dur = true } }

    func basla() {
        grup.enter()
        Thread { [self] in
            onceki?.grup.wait()
            onceki = nil
            let h = calistir()
            bitince?(h)
            grup.leave()
        }.start()
    }

    private func klavyeyiAc() -> String? {
        if let h = klavye.ac() { return h }
        klavye.tusGeldi = { [weak self] in self?.sonTus = CACurrentMediaTime() }
        guard let i = klavye.ozellik(0x1982) else { return "Klavye cevap vermiyor" }
        idx = i
        guard let simdi = klavye.request(idx, 0x0), simdi.count >= 12 else { return "Ayar okunamadı" }
        yedek = yedegiAl(Array(simdi[0..<12]))
        return nil
    }

    private func yedegiAl(_ simdi: [UInt8]) -> [UInt8] {
        if let s = try? String(contentsOfFile: yedekYolu, encoding: .utf8) {
            let b = s.split(whereSeparator: \.isWhitespace).compactMap { UInt8($0, radix: 16) }
            if b.count == 12 { return b }
        }
        try? FileManager.default.createDirectory(atPath: destekDizini, withIntermediateDirectories: true)
        try? (hex(simdi) + "\n").write(toFile: yedekYolu, atomically: true, encoding: .utf8)
        return simdi
    }

    private func seviye(_ l: UInt8) -> Bool {
        klavye.request(idx, 0x1, ayarBaytlari(yedek, l)) != nil
    }

    private func geriAl() -> Bool {
        // Bluetooth'ta ara sıra tek yazma hatası oluyor, ikinci deneme yetiyor
        for deneme in 0..<2 {
            if deneme > 0 { CFRunLoopRunInMode(.defaultMode, 0.3, false) }
            if klavye.request(idx, 0x1, ayarBaytlari(yedek, nil)) != nil,
               let son = klavye.request(idx, 0x0), son.count >= 12, ayarAyni(son, yedek) { return true }
        }
        return false
    }

    private func sesiAc() -> String? {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return "Ekran Kaydı izni gerekli"
        }
        let s = DispatchSemaphore(value: 0)
        var icerik: SCShareableContent?
        var hata: Error?
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { i, e in
            icerik = i
            hata = e
            s.signal()
        }
        guard s.wait(timeout: .now() + 10) == .success, let icerik, let ekran = icerik.displays.first else {
            return hata?.localizedDescription ?? "Ekran yok"
        }
        let filtre: SCContentFilter
        if kaynak.isEmpty {
            filtre = SCContentFilter(display: ekran, excludingWindows: [])
        } else {
            guard let app = icerik.applications.first(where: { $0.bundleIdentifier == kaynak }) else {
                return "Seçilen uygulama açık değil"
            }
            filtre = SCContentFilter(display: ekran, including: [app], exceptingWindows: [])
        }
        let c = SCStreamConfiguration()
        c.capturesAudio = true
        c.excludesCurrentProcessAudio = true
        c.sampleRate = 48000
        c.channelCount = 1
        c.width = 2
        c.height = 2
        c.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let a = SCStream(filter: filtre, configuration: c, delegate: self)
        do {
            try a.addStreamOutput(self, type: .audio, sampleHandlerQueue: sesKuyrugu)
        } catch {
            return error.localizedDescription
        }
        akis = a
        a.startCapture { [self] h in
            if let h { kilit.withLock { akisHatasi = h.localizedDescription } }
        }
        return nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, let blok = CMSampleBufferGetDataBuffer(sb) else { return }
        var uzunluk = 0
        var veri: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(blok, atOffset: 0, lengthAtOffsetOut: &uzunluk, totalLengthOut: nil, dataPointerOut: &veri) == noErr,
              let veri, uzunluk >= 4 else { return }
        let n = uzunluk / 4
        let a = ayar
        if filtre.bant != a.bant || filtre.kesim != a.basKesim { filtre = BantFiltre(bant: a.bant, kesim: a.basKesim) }
        var toplam: Float = 0
        var tamToplam: Float = 0
        let spektrumVar = a.spektrumAcik
        veri.withMemoryRebound(to: Float.self, capacity: n) { o in
            for i in 0..<n {
                let y = filtre.isle(o[i])
                toplam += y * y
                tamToplam += o[i] * o[i]
            }
            if spektrumVar {
                let c = spektrum.ekle(UnsafeBufferPointer(start: o, count: n))
                kilit.withLock { _spektrum = c }
            }
        }
        let rms = (toplam / Float(n)).squareRoot()
        let tam = (tamToplam / Float(n)).squareRoot()
        kilit.withLock {
            anlikRMS = max(anlikRMS, rms)
            anlikTam = max(anlikTam, tam)
            yeniSes = true
            basladi = true
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        kilit.withLock { akisHatasi = error.localizedDescription }
    }

    private func calistir() -> String? {
        if let h = klavyeyiAc() {
            klavye.kapat()
            return h
        }
        if let h = sesiAc() {
            klavye.kapat()
            return h
        }
        baglandi?()
        var izleyici = Izleyici()
        var sessizlik = Sessizlik()
        var sonBant = ayar.bant
        var sonTik = CACurrentMediaTime()
        var askidaydi = false
        var son: UInt8 = 255
        var ardisik = 0
        let bitis = sure.map { Date().addingTimeInterval($0) }
        var sonuc: String?

        while !dur {
            if let bitis, Date() >= bitis { break }
            if let h = kilit.withLock({ akisHatasi }) { sonuc = h; break }
            if ardisik >= 20 { sonuc = "Klavye bağlantısı koptu"; break }
            let a = ayar
            let t = CACurrentMediaTime()
            let enCok = a.mod == .nefes ? 0.066 : 0.1
            while !dur && !kilit.withLock({ yeniSes }) && CACurrentMediaTime() - t < enCok {
                CFRunLoopRunInMode(.defaultMode, 0.003, true)
            }
            let (rms, tam, hazir): (Float, Float, Bool) = kilit.withLock {
                let r = (anlikRMS, anlikTam, basladi)
                anlikRMS = 0
                anlikTam = 0
                yeniSes = false
                return r
            }
            if a.bant != sonBant {
                sonBant = a.bant
                izleyici = Izleyici()
            }
            let simdi = CACurrentMediaTime()
            let dt = Float(min(simdi - sonTik, 0.2))
            sonTik = simdi
            if a.askida {
                if !askidaydi {
                    askidaydi = true
                    _ = geriAl()
                    son = 255
                    izleriSifirla()
                    // Kilitliyken ve gece yakalama durur, ekran kaydı göstergesi de söner
                    akis?.stopCapture { _ in }
                    akis = nil
                }
                continue
            }
            if askidaydi {
                askidaydi = false
                if let h = sesiAc() { sonuc = h; break }
                izleyici = Izleyici()
                sessizlik = Sessizlik()
            }
            let m = a.mod
            let l: UInt8
            if m == .nefes {
                sessizlik = Sessizlik()
                l = nefesSeviye(Date().timeIntervalSinceReferenceDate)
            } else {
                guard hazir else { continue }
                switch sessizlik.ekle(tam, Date().timeIntervalSinceReferenceDate) {
                case .sensoreDon:
                    _ = geriAl()
                    son = 255
                    izleriSifirla()
                case .geriGel:
                    izleyici = Izleyici()
                case nil:
                    break
                }
                if sessizlik.sensorde { continue }
                enYuksek = max(enYuksek, rms)
                l = izleyici.darbeli(rms, m, a.hassasiyet, dt, sonus: a.sonus, darbe: a.darbe)
            }
            let yaz = a.yazarkenSabit && yaziyor(simdi, sonTus) ? UInt8((a.yazarkenIsik * 7).rounded()) : l
            kilit.withLock {
                _iz.removeFirst()
                _iz.append(izleyici.oran)
                _isikIz.removeFirst()
                _isikIz.append(_seviye)
            }
            dagilim[Int(yaz)] += 1
            tik += 1
            if yaz != son {
                if seviye(yaz) {
                    yazma += 1
                    son = yaz
                    ardisik = 0
                    kilit.withLock { _seviye = yaz }
                } else {
                    hataSayisi += 1
                    ardisik += 1
                }
            }
        }

        akis?.stopCapture { _ in }
        if !geriAl() && sonuc == nil { sonuc = "Geri alma doğrulanamadı" }
        klavye.kapat()
        return sonuc
    }
}

var kisayolDurum: Durum?

final class Durum: ObservableObject {
    static let kaynaklar: [(ad: String, id: String)] = [
        ("Tümü", ""), ("Spotify", "com.spotify.client"), ("Müzik", "com.apple.Music"),
        ("Safari", "com.apple.Safari"), ("Chrome", "com.google.Chrome"),
    ].filter { $0.1.isEmpty || NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.1) != nil }

    @Published var mod: Mod?
    @Published var hata: String?
    @Published var eksikIzinler: [String] = []
    @Published var pil: Pil?
    @Published var acilista = SMAppService.mainApp.status == .enabled
    @Published var kaynak = UserDefaults.standard.string(forKey: "kaynak") ?? ""
    @Published var hassasiyet = UserDefaults.standard.object(forKey: "hassasiyet") as? Float ?? 0.5 {
        didSet {
            UserDefaults.standard.set(hassasiyet, forKey: "hassasiyet")
            ayarGonder()
        }
    }
    @Published var bant = Bant(rawValue: UserDefaults.standard.string(forKey: "bant") ?? "") ?? .bas {
        didSet {
            UserDefaults.standard.set(bant.rawValue, forKey: "bant")
            ayarGonder()
        }
    }
    @Published var gecede = false
    @Published var yazarkenSabit = UserDefaults.standard.object(forKey: "yazarkenSabit") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(yazarkenSabit, forKey: "yazarkenSabit")
            ayarGonder()
        }
    }
    @Published var yazarkenIsik = UserDefaults.standard.object(forKey: "yazarkenIsik") as? Float ?? 1 {
        didSet {
            UserDefaults.standard.set(yazarkenIsik, forKey: "yazarkenIsik")
            ayarGonder()
        }
    }
    @Published var sonus = UserDefaults.standard.object(forKey: "sonus") as? Float ?? 0.5 {
        didSet {
            UserDefaults.standard.set(sonus, forKey: "sonus")
            ayarGonder()
        }
    }
    @Published var darbe = UserDefaults.standard.object(forKey: "darbe") as? Float ?? 1 {
        didSet {
            UserDefaults.standard.set(darbe, forKey: "darbe")
            ayarGonder()
        }
    }
    @Published var basKesim = UserDefaults.standard.object(forKey: "basKesim") as? Float ?? Float(60) / 190 {
        didSet {
            UserDefaults.standard.set(basKesim, forKey: "basKesim")
            ayarGonder()
        }
    }
    @Published var geceAcik = UserDefaults.standard.bool(forKey: "geceAcik") {
        didSet {
            UserDefaults.standard.set(geceAcik, forKey: "geceAcik")
            askiGuncelle()
        }
    }
    @Published var geceBas = UserDefaults.standard.object(forKey: "geceBas") as? Int ?? 23 {
        didSet {
            UserDefaults.standard.set(geceBas, forKey: "geceBas")
            askiGuncelle()
        }
    }
    @Published var geceBit = UserDefaults.standard.object(forKey: "geceBit") as? Int ?? 7 {
        didSet {
            UserDefaults.standard.set(geceBit, forKey: "geceBit")
            askiGuncelle()
        }
    }
    private var spektrumAcik = false
    private var spektrumPaneli: NSPanel?
    private var kilitli = false
    private var ekranUyuyor = false
    private var sistemGozlemleri: [NSObjectProtocol] = []
    private var sonIzin = ""
    private var motor: Motor?
    private var sonMotor: Motor?
    private var sinyal: DispatchSourceSignal?
    private var gozlem: NSObjectProtocol?
    private var kalanDeneme = 0
    private var kisayol: EventHotKeyRef?
    private var sonSecilen = Mod.hard

    var anlikSeviye: Int { Int(motor?.seviyeAnlik ?? 0) }
    var anlikIz: [Float] { motor?.izAnlik ?? [] }
    var anlikIsik: [UInt8] { motor?.isikIzAnlik ?? [] }
    var anlikSpektrum: [Float] { motor?.spektrumAnlik ?? [] }

    func spektrumGoster(_ acik: Bool) {
        guard acik != spektrumAcik else { return }
        spektrumAcik = acik
        ayarGonder()
        guard acik else {
            spektrumPaneli?.orderOut(nil)
            spektrumPaneli = nil
            return
        }
        let icerik = NSHostingView(rootView: SpektrumGorunum(d: self))
        let s = icerik.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: s), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = icerik
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hedef = NSApp.windows.first { $0.isVisible && $0.frame.contains(NSEvent.mouseLocation) }
        let ekran = (hedef?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let yan = hedef?.frame ?? NSRect(x: ekran.maxX - 8, y: ekran.maxY, width: 0, height: 0)
        p.setFrameOrigin(NSPoint(x: max(ekran.minX, yan.minX - s.width - 8), y: max(ekran.minY, yan.maxY - s.height)))
        p.orderFrontRegardless()
        spektrumPaneli = p
    }

    static func ikon(_ id: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    func gucDegistir() { sec(mod == nil ? sonSecilen : nil) }

    private var ayarlar: Ayarlar {
        Ayarlar(mod: mod ?? sonSecilen, hassasiyet: hassasiyet, bant: bant, askida: kilitli || ekranUyuyor || gecede, yazarkenSabit: yazarkenSabit,
                yazarkenIsik: yazarkenIsik, sonus: sonus, darbe: darbe, basKesim: basKesim, spektrumAcik: spektrumAcik)
    }

    private func ayarGonder() { motor?.ayar = ayarlar }

    private func askiGuncelle() {
        gecede = geceAcik && geceMi(Calendar.current.component(.hour, from: Date()), geceBas, geceBit)
        ayarGonder()
    }

    private func sistemiDinle() {
        let dagitik = DistributedNotificationCenter.default()
        let is_ = NSWorkspace.shared.notificationCenter
        func gozle(_ m: NotificationCenter, _ ad: String, _ eylem: @escaping () -> Void) {
            sistemGozlemleri.append(m.addObserver(forName: Notification.Name(ad), object: nil, queue: .main) { [weak self] _ in
                eylem()
                self?.askiGuncelle()
            })
        }
        gozle(dagitik, "com.apple.screenIsLocked") { [weak self] in self?.kilitli = true }
        gozle(dagitik, "com.apple.screenIsUnlocked") { [weak self] in self?.kilitli = false }
        gozle(is_, NSWorkspace.screensDidSleepNotification.rawValue) { [weak self] in self?.ekranUyuyor = true }
        gozle(is_, NSWorkspace.screensDidWakeNotification.rawValue) { [weak self] in self?.ekranUyuyor = false }
    }

    init() {
        signal(SIGTERM, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        s.setEventHandler { NSApp.terminate(nil) }
        s.resume()
        sinyal = s
        gozlem = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.motor?.durdur()
            _ = self?.sonMotor?.grup.wait(timeout: .now() + 2)
        }
        DispatchQueue.main.async { [weak self] in
            if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
            self?.izinBak()
            self?.pilBak()
            self?.kisayolKur()
            self?.sistemiDinle()
            self?.askiGuncelle()
            if let m = Mod(rawValue: UserDefaults.standard.string(forKey: "sonMod") ?? "") {
                self?.kalanDeneme = 6
                self?.sec(m, otomatik: true)
            }
        }
        DispatchQueue.global().async {
            if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
                IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            }
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.izinBak() }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.pilBak()
            self?.askiGuncelle()
        }
    }

    private func kisayolKur() {
        kisayolDurum = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { kisayolDurum?.sonrakiMod() }
            return noErr
        }, 1, &spec, nil, nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x4D49584B, id: 1), GetApplicationEventTarget(), 0, &kisayol)
    }

    func sonrakiMod() {
        let sira: [Mod?] = [nil] + Mod.allCases
        sec(sira[((sira.firstIndex(of: mod) ?? 0) + 1) % sira.count])
    }

    private func izinBak() {
        let ekran = CGPreflightScreenCaptureAccess()
        let giris = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        let metin = "ekran=\(ekran ? 1 : 0)\ngiris=\(giris ? 1 : 0)\n"
        guard metin != sonIzin else { return }
        sonIzin = metin
        try? FileManager.default.createDirectory(atPath: destekDizini, withIntermediateDirectories: true)
        try? metin.write(toFile: izinYolu, atomically: true, encoding: .utf8)
        eksikIzinler = (ekran ? [] : ["Ekran Kaydı izni yok"]) + (giris ? [] : ["Giriş İzleme izni yok"])
    }

    private func pilBak() {
        Thread { [weak self] in
            let p = pilOku()
            DispatchQueue.main.async {
                guard let self else { return }
                self.pil = p
                if let p, p.dusuk, self.mod != nil {
                    self.sec(nil)
                    self.hata = "Pil düşük, durduruldu"
                }
            }
        }.start()
    }

    func sec(_ m: Mod?, otomatik: Bool = false) {
        if !otomatik { kalanDeneme = 0 }
        hata = nil
        mod = m
        UserDefaults.standard.set(m?.rawValue ?? "", forKey: "sonMod")
        guard let m else {
            motor?.durdur()
            motor = nil
            return
        }
        sonSecilen = m
        if motor != nil {
            ayarGonder()
            return
        }
        baslat(m)
    }

    func kaynakSec(_ k: String) {
        kaynak = k
        UserDefaults.standard.set(k, forKey: "kaynak")
        guard let m = mod else { return }
        hata = nil
        motor?.durdur()
        motor = nil
        baslat(m)
    }

    func acilistaDegistir() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            hata = error.localizedDescription
        }
        acilista = SMAppService.mainApp.status == .enabled
    }

    private func baslat(_ m: Mod) {
        var a = ayarlar
        a.mod = m
        let yeni = Motor(ayar: a, kaynak: kaynak, onceki: sonMotor)
        yeni.baglandi = { [weak self] in
            DispatchQueue.main.async {
                if self?.hata == "Klavye bekleniyor" { self?.hata = nil }
            }
        }
        yeni.bitince = { [weak self, weak yeni] h in
            DispatchQueue.main.async {
                guard let self, let yeni, self.motor === yeni else { return }
                let istenen = self.mod
                self.motor = nil
                if let h, klavyeHatalari.contains(h), let istenen {
                    self.hata = "Klavye bekleniyor"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                        guard let self, self.mod == istenen, self.motor == nil else { return }
                        self.baslat(istenen)
                    }
                    return
                }
                self.mod = nil
                self.hata = h
                if h != nil, self.kalanDeneme > 0, let istenen {
                    self.kalanDeneme -= 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                        guard let self, self.mod == nil, self.kalanDeneme > 0 else { return }
                        self.sec(istenen, otomatik: true)
                    }
                }
            }
        }
        motor = yeni
        sonMotor = yeni
        yeni.basla()
    }
}

enum Tema {
    static let vurgu = LinearGradient(
        colors: [Color(red: 0.42, green: 0.36, blue: 1), Color(red: 0.96, green: 0.33, blue: 0.62)],
        startPoint: .leading, endPoint: .trailing)
    static let yuzey = Color.primary.opacity(0.07)
    static let koyuYuzey = Color.primary.opacity(0.14)
}

struct Karo<Gorsel: View>: View {
    let ad: String
    let secili: Bool
    let eylem: () -> Void
    @ViewBuilder let gorsel: Gorsel
    @State private var uzerinde = false

    var body: some View {
        Button(action: eylem) {
            VStack(spacing: 4) {
                gorsel.frame(height: 20)
                Text(ad)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundColor(secili ? .white : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(secili ? AnyShapeStyle(Tema.vurgu) : AnyShapeStyle(uzerinde ? Tema.koyuYuzey : Tema.yuzey))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { uzerinde = $0 }
    }
}

struct Surgu: View {
    @Binding var deger: Float
    let ad: String
    let metin: String

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Tema.koyuYuzey).frame(height: 6)
                Capsule().fill(Tema.vurgu).frame(width: 7 + (g.size.width - 14) * CGFloat(deger), height: 6)
                Circle().fill(Color.white).frame(width: 14, height: 14).shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                    .offset(x: (g.size.width - 14) * CGFloat(deger))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                deger = Float(max(0, min(1, v.location.x / g.size.width)))
            })
        }
        .frame(height: 20)
        .accessibilityLabel(ad)
        .accessibilityValue(metin)
    }
}

struct Anahtar: View {
    let etiket: String
    let acik: Bool
    let eylem: () -> Void

    var body: some View {
        Button(action: eylem) {
            ZStack(alignment: acik ? .trailing : .leading) {
                Capsule()
                    .fill(acik ? AnyShapeStyle(Tema.vurgu) : AnyShapeStyle(Tema.koyuYuzey))
                    .frame(width: 32, height: 18)
                Circle().fill(Color.white).frame(width: 14, height: 14).padding(2)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            }
            .animation(.easeOut(duration: 0.15), value: acik)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(etiket)
        .accessibilityValue(acik ? "Açık" : "Kapalı")
    }
}

struct Olcer: View {
    let d: Durum

    private func cubuklar(_ n: Int, _ dolgu: some ShapeStyle) -> some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(1...7, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3)
                    .fill(dolgu)
                    .frame(height: CGFloat(4 + i * 4))
                    .frame(maxWidth: .infinity)
                    .opacity(i <= n ? 1 : 0)
            }
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.03)) { _ in
            let l = d.anlikSeviye
            ZStack(alignment: .bottom) {
                cubuklar(7, Tema.yuzey)
                Tema.vurgu.mask(cubuklar(l, Color.white))
            }
        }
        .frame(height: 32)
        .accessibilityHidden(true)
    }
}

struct GirisIzi: View {
    let d: Durum

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { _ in
            let p = (d.mod ?? .hard).pencere(d.hassasiyet)
            let iz = d.anlikIz
            Canvas { c, s in
                func y(_ o: Float) -> CGFloat { 3 + (s.height - 6) * CGFloat(1 - o) }
                for o in [p.alt, p.ust] {
                    var cizgi = Path()
                    cizgi.move(to: CGPoint(x: 0, y: y(o)))
                    cizgi.addLine(to: CGPoint(x: s.width, y: y(o)))
                    c.stroke(cizgi, with: .color(.secondary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                var yol = Path()
                for (i, o) in iz.enumerated() {
                    let n = CGPoint(x: s.width * CGFloat(i) / CGFloat(max(iz.count - 1, 1)), y: y(o))
                    if i == 0 { yol.move(to: n) } else { yol.addLine(to: n) }
                }
                c.stroke(yol, with: .foreground, lineWidth: 1.5)
            }
            .foregroundStyle(Tema.vurgu)
        }
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 8).fill(Tema.koyuYuzey))
        .accessibilityHidden(true)
    }
}

struct SutunGrafik: View {
    let degerler: [Float]
    var vurgulu: (Int) -> Bool = { _ in true }

    var body: some View {
        Canvas { c, s in
            guard !degerler.isEmpty else { return }
            let w = s.width / CGFloat(degerler.count)
            var acik = Path()
            var sonuk = Path()
            for (i, v) in degerler.enumerated() where v > 0 {
                let h = s.height * CGFloat(min(v, 1))
                let r = CGRect(x: CGFloat(i) * w, y: s.height - h, width: max(w - 1, 1), height: h)
                if vurgulu(i) { acik.addRect(r) } else { sonuk.addRect(r) }
            }
            c.fill(sonuk, with: .color(.secondary.opacity(0.35)))
            c.fill(acik, with: .foreground)
        }
        .foregroundStyle(Tema.vurgu)
        .padding(4)
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 8).fill(Tema.koyuYuzey))
        .accessibilityHidden(true)
    }
}

final class KlavyeSimDurum {
    private var darbe = Darbe()
    private var led = LedModel()
    private var son: Date?

    func parlaklik(_ d: Durum, _ m: Mod, _ hassasiyet: Float, _ simdi: Date) -> Double {
        let dt = son.map { min(simdi.timeIntervalSince($0), 0.2) } ?? 0
        son = simdi
        let hedef = m == .nefes ? UInt8(d.anlikSeviye) : darbe.ekle(m.seviye(d.anlikIz.last ?? 0, hassasiyet), m, Float(dt), sonus: d.sonus, darbe: d.darbe)
        return led.ilerle(hedef, dt)
    }
}

struct KlavyeSim: View {
    let d: Durum
    @State private var sim = KlavyeSimDurum()
    private static let tuslar: [[CGFloat]] = [
        [CGFloat](repeating: 14.5 / 14, count: 14),
        [CGFloat](repeating: 1, count: 13) + [1.5],
        [1.5] + [CGFloat](repeating: 1, count: 13),
        [1.75] + [CGFloat](repeating: 1, count: 11) + [1.75],
        [2.25] + [CGFloat](repeating: 1, count: 10) + [2.25],
        [1, 1, 1.25, 5.75, 1.25, 1, 1, 1, 1.25],
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.03)) { z in
            let v = sim.parlaklik(d, d.mod ?? .hard, d.hassasiyet, z.date)
            Canvas { c, s in
                let genis = s.width + 2
                let satir = (s.height + 2) / CGFloat(Self.tuslar.count)
                for (r, sira) in Self.tuslar.enumerated() {
                    let birim = genis / sira.reduce(0, +)
                    var x: CGFloat = 0
                    for g in sira {
                        let w = birim * g
                        let tus = CGRect(x: x, y: CGFloat(r) * satir, width: w - 2, height: satir - 2)
                        c.fill(Path(roundedRect: tus, cornerRadius: 2), with: .color(.white.opacity(0.06 + 0.94 * v)))
                        x += w
                    }
                }
            }
        }
        .padding(6)
        .frame(height: 78)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.55)))
        .accessibilityHidden(true)
    }
}

struct SpektrumGorunum: View {
    @ObservedObject var d: Durum

    private func etiket(_ ad: String) -> some View {
        Text(ad).font(.system(size: 12, weight: .medium))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            etiket("Hassasiyet %\(Int((d.hassasiyet * 100).rounded()))")
            KlavyeSim(d: d)
            etiket("Işık")
            TimelineView(.animation(minimumInterval: 0.03)) { _ in
                SutunGrafik(degerler: d.anlikIsik.map { Float($0) / 7 })
            }
            etiket("Giriş")
            GirisIzi(d: d)
            etiket("Spektrum")
            TimelineView(.animation(minimumInterval: 0.03)) { _ in
                SutunGrafik(degerler: d.anlikSpektrum) { d.bant.icinde(spektrumHz($0), kesim: d.basKesim) }
            }
            etiket("Etki")
            SutunGrafik(degerler: etkiSeviyeleri(d.mod ?? .hard, d.hassasiyet, d.sonus, d.darbe).map { Float($0) / 7 })
        }
        .padding(12)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
    }
}

struct PilRozeti: View {
    let pil: Pil

    private var ikon: String {
        if pil.sarjda { return "battery.100.bolt" }
        switch pil.yuzde {
        case 76...: return "battery.100"
        case 51...: return "battery.75"
        case 26...: return "battery.50"
        default: return "battery.25"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: ikon)
            if pil.yuzde > 0 { Text("%\(pil.yuzde)") }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(pil.dusuk ? .red : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Tema.yuzey))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pil.metin)
    }
}

struct BantSecici: View {
    @ObservedObject var d: Durum

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Bant.allCases) { b in
                Button { d.bant = b } label: {
                    Text(b.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(d.bant == b ? .white : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(d.bant == b ? AnyShapeStyle(Tema.vurgu) : AnyShapeStyle(Color.clear)))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Tema.yuzey))
    }
}

struct SaatAdim: View {
    let ad: String
    @Binding var saat: Int

    private func dugme(_ ikon: String, _ etiket: String, _ fark: Int) -> some View {
        Button { saat = (saat + fark + 24) % 24 } label: {
            Image(systemName: ikon)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Tema.yuzey))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(ad) \(etiket)")
    }

    var body: some View {
        HStack(spacing: 4) {
            dugme("minus", "azalt", -1)
            Text(String(format: "%02d:00", saat))
                .font(.system(size: 12).monospacedDigit())
                .frame(width: 42)
            dugme("plus", "artır", 1)
        }
    }
}

struct Uyari: View {
    let metin: String

    var body: some View {
        Text(metin)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.12)))
    }
}

struct Panel: View {
    @ObservedObject var d: Durum

    private func ayar(_ ad: String, _ deger: Binding<Float>, _ metin: String) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(ad).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(metin).font(.system(size: 12)).foregroundColor(.secondary)
            }
            Surgu(deger: deger, ad: ad, metin: metin)
        }
    }

    private var guc: some View {
        Button { d.gucDegistir() } label: {
            Image(systemName: "power")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(d.mod == nil ? .secondary : .white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(d.mod == nil ? AnyShapeStyle(Tema.yuzey) : AnyShapeStyle(Tema.vurgu)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(d.mod == nil ? "Aç" : "Kapat")
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                guc
                Text(d.mod?.rawValue ?? "Kapalı").font(.system(size: 15, weight: .semibold))
                if d.gecede { Text("Gece").font(.system(size: 11)).foregroundColor(.secondary) }
                Spacer()
                if let p = d.pil { PilRozeti(pil: p) }
            }
            Olcer(d: d)
            HStack(spacing: 6) {
                ForEach(Mod.allCases) { m in
                    Karo(ad: m.rawValue, secili: d.mod == m, eylem: { d.sec(m) }) {
                        Image(systemName: m.ikon).font(.system(size: 15, weight: .medium))
                    }
                }
            }
            BantSecici(d: d)
            VStack(spacing: 8) {
                GirisIzi(d: d)
                ayar("Hassasiyet", $d.hassasiyet, "%\(Int(d.hassasiyet * 100))")
                ayar("Sönüş", $d.sonus, "%\(Int(d.sonus * 100))")
                ayar("Darbe", $d.darbe, "\(Int((darbeSn(d.darbe) * 1000).rounded())) ms")
                if d.bant == .bas {
                    ayar("Bas sınırı", $d.basKesim, "\(Int(basHz(d.basKesim))) Hz")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Tema.yuzey))
            HStack(spacing: 6) {
                ForEach(Durum.kaynaklar, id: \.id) { k in
                    Karo(ad: k.ad, secili: d.kaynak == k.id, eylem: { d.kaynakSec(k.id) }) {
                        if let i = Durum.ikon(k.id) {
                            Image(nsImage: i).resizable().frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "speaker.wave.2.fill").font(.system(size: 14))
                        }
                    }
                }
            }
            HStack {
                Text("Açılışta başla").font(.system(size: 12))
                Spacer()
                Anahtar(etiket: "Açılışta başla", acik: d.acilista) { d.acilistaDegistir() }
            }
            .padding(.horizontal, 2)
            HStack {
                Text("Yazarken sabit").font(.system(size: 12))
                Spacer()
                Anahtar(etiket: "Yazarken sabit", acik: d.yazarkenSabit) { d.yazarkenSabit.toggle() }
            }
            .padding(.horizontal, 2)
            if d.yazarkenSabit {
                ayar("Yazarken ışık", $d.yazarkenIsik, "%\(Int(d.yazarkenIsik * 100))")
                    .padding(.horizontal, 2)
            }
            HStack {
                Text("Gece kapalı").font(.system(size: 12))
                Spacer()
                Anahtar(etiket: "Gece kapalı", acik: d.geceAcik) { d.geceAcik.toggle() }
            }
            .padding(.horizontal, 2)
            if d.geceAcik {
                HStack {
                    SaatAdim(ad: "Başlangıç", saat: $d.geceBas)
                    Spacer()
                    SaatAdim(ad: "Bitiş", saat: $d.geceBit)
                }
                .padding(.horizontal, 2)
            }
            ForEach(d.eksikIzinler, id: \.self) { Uyari(metin: $0) }
            if let h = d.hata { Uyari(metin: h) }
            HStack {
                Text("⌃⌥M")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Tema.yuzey))
                Spacer()
                Button("Çık") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .padding(12)
        .frame(width: 290)
        .contentShape(Rectangle())
        .onHover { d.spektrumGoster($0) }
        .onDisappear { d.spektrumGoster(false) }
    }
}

struct IsikUygulama: App {
    @StateObject private var d = Durum()

    var body: some Scene {
        MenuBarExtra("MiX-Key", systemImage: d.mod == nil ? "keyboard" : "keyboard.fill") {
            Panel(d: d)
        }
        .menuBarExtraStyle(.window)
    }
}

func testler() {
    let muzik: [Mod] = [.soft, .medium, .hard]
    for m in muzik {
        var i = Izleyici()
        precondition(i.ekle(0, m) == 0, "sessizlik 0 olmalı")
        precondition(i.ekle(0.001, m) == 0, "gürültü tabanı 0 olmalı")
        precondition(i.ekle(0.5, m) == 7, "tepe 7 olmalı")
        var onceki: UInt8 = 7
        for _ in 0..<40 {
            let l = i.ekle(0, m)
            precondition(l <= onceki, "sönüş tekdüze olmalı")
            onceki = l
        }
        precondition(onceki == 0, "sessizlikte 0'a inmeli")
    }

    func orta(_ m: Mod, _ h: Float) -> UInt8 {
        var j = Izleyici()
        _ = j.ekle(0.5, m, h)
        for _ in 0..<10 { _ = j.ekle(0, m, h) }
        return j.ekle(0.15, m, h)
    }
    let o = muzik.map { orta($0, 0.5) }
    precondition(o[0] > o[2] && o[2] == 0, "hard orta seste sönük, soft yanık olmalı: \(o)")
    for m in muzik {
        precondition(orta(m, 0) <= orta(m, 0.5) && orta(m, 0.5) <= orta(m, 1), "hassasiyet artınca seviye düşmemeli")
    }
    precondition(orta(.hard, 1) > 0, "yüksek hassasiyette hard orta seste yanmalı")

    func sinusRMS(_ hz: Float, _ b: Bant) -> Float {
        var f = BantFiltre(bant: b)
        var t: Float = 0
        for i in 0..<48000 {
            let y = f.isle(sin(2 * .pi * hz * Float(i) / 48000))
            if i >= 24000 { t += y * y }
        }
        return (t / 24000).squareRoot()
    }
    precondition(sinusRMS(60, .bas) > 0.6 && sinusRMS(500, .bas) < 0.01, "bas 500 Hz'i kesmeli")
    var dar = BantFiltre(bant: .bas, kesim: 0)
    var genis = BantFiltre(bant: .bas, kesim: 1)
    var darT: Float = 0, genisT: Float = 0
    for i in 0..<48000 {
        let x = sin(2 * .pi * 180 * Float(i) / 48000)
        let a = dar.isle(x), b = genis.isle(x)
        if i >= 24000 { darT += a * a; genisT += b * b }
    }
    precondition(genisT > 20 * darT, "bas sınırı 180 Hz'i ayırmalı")
    precondition(sinusRMS(10000, .tiz) > 5 * sinusRMS(60, .tiz), "tiz basi kesmeli")
    precondition(sinusRMS(1000, .orta) > 3 * sinusRMS(60, .orta), "orta basi kesmeli")
    precondition(sinusRMS(1000, .orta) > 2 * sinusRMS(15000, .orta), "orta tizi kesmeli")
    precondition(abs(sinusRMS(60, .hepsi) - sinusRMS(10000, .hepsi)) < 0.01, "hepsi filtrelememeli")

    func sonenZarf(_ adimSayisi: Int, _ dt: Float) -> Float {
        var i = Izleyici()
        _ = i.ekle(0.5, .hard)
        for _ in 0..<adimSayisi { _ = i.ekle(0, .hard, 0.5, dt) }
        return i.zarf
    }
    precondition(abs(sonenZarf(10, 0.09) - sonenZarf(45, 0.02)) < 0.001, "sönüş tik hızına bağlı olmamalı")

    func aralik(_ m: Mod, _ h: Float) -> (en: UInt8, ek: UInt8, ort: Float) {
        var i = Izleyici()
        var en: UInt8 = 7, ek: UInt8 = 0, top: Float = 0
        for t in 0..<600 {
            // sıkıştırılmış müzik benzeri: seviye yalnız 0.30 ile 0.36 arasında geziyor
            let l = i.ekle(t % 24 < 4 ? 0.36 : 0.30, m, h, 0.02)
            if t >= 300 {
                en = min(en, l)
                ek = max(ek, l)
                top += Float(l)
            }
        }
        return (en, ek, top / 300)
    }
    for m in muzik {
        let a = aralik(m, 0.5)
        precondition(a.ek == 7 && a.ek - a.en >= 5, "dar dinamikte ışık takılmamalı: \(m) \(a)")
        precondition(aralik(m, 0).ort + 1 < aralik(m, 1).ort, "hassasiyet belirgin oynatmalı: \(m)")
        for h in stride(from: Float(0), through: 1, by: 0.1) {
            let p = m.pencere(h)
            precondition(p.alt >= 0 && p.ust <= 1 && p.ust - p.alt >= 0.15 - 0.0001, "pencere sınırı: \(p)")
        }
    }
    precondition(aralik(.soft, 0.5).ort > aralik(.medium, 0.5).ort && aralik(.soft, 0.5).ort > aralik(.hard, 0.5).ort, "soft en dolgun mod olmalı: \(muzik.map { aralik($0, 0.5) })")
    func sonusSuresi(_ s: Float) -> Int {
        var i = Izleyici()
        _ = i.ekle(0.5, .hard, 0.5, 0.02, sonus: s)
        var n = 0
        while i.ekle(0, .hard, 0.5, 0.02, sonus: s) > 0 && n < 2000 { n += 1 }
        return n
    }
    precondition(sonusSuresi(1) > sonusSuresi(0.5) && sonusSuresi(0.5) > sonusSuresi(0), "sönüş sürgüsü süreyi değiştirmeli")

    func tepeHz(_ hz: Float) -> (Float, Float) {
        let x = (0..<4096).map { sin(2 * Float.pi * hz * Float($0) / 48000) }
        let c = x.withUnsafeBufferPointer { Spektrum().ekle($0) }
        let e = c.indices.max { c[$0] < c[$1] } ?? 0
        return (spektrumHz(e), c[e])
    }
    for hz: Float in [60, 1000, 8000] {
        let (t, g) = tepeHz(hz)
        precondition(t > hz / 1.5 && t < hz * 1.5 && g > 0.8, "spektrum tepesi yanlış: \(hz) \(t) \(g)")
    }
    let sessiz = [Float](repeating: 0, count: 4096).withUnsafeBufferPointer { Spektrum().ekle($0) }
    precondition(sessiz.allSatisfy { $0 == 0 }, "sessizlikte spektrum boş olmalı")
    precondition(Bant.bas.icinde(100, kesim: Float(60) / 190) && !Bant.bas.icinde(500, kesim: Float(60) / 190) && Bant.tiz.icinde(8000, kesim: 0) && !Bant.orta.icinde(100, kesim: 0), "bant vurgusu")
    func etkiTop(_ h: Float, _ s: Float) -> Int { etkiSeviyeleri(.hard, h, s).reduce(0) { $0 + Int($1) } }
    precondition(etkiTop(1, 0.5) > etkiTop(0, 0.5), "etki hassasiyeti göstermeli")
    precondition(etkiSeviyeleri(.hard, 0.5, 0) != etkiSeviyeleri(.hard, 0.5, 1), "etki sönüşü göstermeli")

    precondition(Mod.medium.seviye(0.6, 0.93) == 7 && Mod.medium.seviye(0.6, 0.3) < 7, "düşük hassasiyet tepeyi kesmemeli")

    var kisa = Darbe()
    let kisaCikis = (0..<40).map { kisa.ekle($0 < 3 ? 7 : 0, .hard, 0.02) }
    precondition(kisaCikis.prefix(13).allSatisfy { $0 == 7 } && kisaCikis.suffix(20).allSatisfy { $0 == 0 } && Set(kisaCikis) == [0, 7], "kısa vuruş 270 ms tam açık kalıp doğrudan sönmeli")
    var kisa15 = Darbe()
    let kisa15Cikis = (0..<40).map { kisa15.ekle($0 < 3 ? 7 : 0, .hard, 0.02, darbe: 0) }
    precondition(kisa15Cikis.prefix(7).allSatisfy { $0 == 7 } && kisa15Cikis.dropFirst(9).allSatisfy { $0 == 0 }, "en kısa darbe 150 ms açık kalmalı")
    var uzun = Darbe()
    _ = uzun.ekle(7, .medium, 0.02)
    precondition((0..<60).map { _ in uzun.ekle(4, .medium, 0.02) }.last == 4, "orta seviyede 7'de takılmamalı")
    var nota = Darbe()
    _ = nota.ekle(7, .medium, 0.02)
    precondition((0..<40).allSatisfy { nota.ekle($0 == 20 ? 0 : 7, .medium, 0.02) == 7 }, "tek tiklik düşüş ışığı kapatmamalı")
    var yumusak = Darbe()
    _ = yumusak.ekle(7, .soft, 0.02)
    precondition(yumusak.ekle(3, .soft, 0.02) == 3, "soft ara seviyeleri korumalı")
    var led = LedModel()
    _ = led.ilerle(7, 1)
    var ledEn = 1.0, ledEk = 0.0
    for t in 0..<200 {
        let v = led.ilerle(t % 2 == 0 ? 7 : 0, 0.155)
        if t > 100 {
            ledEn = min(ledEn, v)
            ledEk = max(ledEk, v)
        }
    }
    precondition(ledEn > 0.6 && ledEk - ledEn < 0.3, "155 ms yanıp sönme videodaki gibi dar kalmalı: \(ledEn) \(ledEk)")
    for (kapali, olcum) in [(0.137, 0.0), (0.238, 0.06), (0.335, 0.19), (0.435, 0.33), (0.635, 0.75), (0.835, 1.0)] {
        var m = LedModel()
        _ = m.ilerle(7, 1)
        var v = 1.0
        for _ in 0..<Int(kapali * 1000) { v = m.ilerle(0, 0.001) }
        precondition(abs(1 - v - olcum) < 0.06, "\(kapali) sn kapanma eşik videosundaki düşüşü vermeli: \(1 - v)")
    }
    var ledDolu = LedModel()
    var ledTepe = 0.0
    for _ in 0..<600 { ledTepe = ledDolu.ilerle(7, 0.001) }
    precondition(abs(ledTepe - 0.73) < 0.05, "karanlıktan 600 ms açık kalınca tepe videodaki gibi eksik kalmalı: \(ledTepe)")
    var ledVurus = LedModel()
    var vurusEn = 1.0, vurusTepe = 0.0
    for t in 0..<5000 {
        let v = ledVurus.ilerle(t % 500 < 240 ? 7 : 0, 0.001)
        if t > 3000 {
            vurusEn = min(vurusEn, v)
            vurusTepe = max(vurusTepe, v)
        }
    }
    precondition(vurusEn < 0.02 && vurusTepe > 0.22 && vurusTepe < 0.48, "120 BPM'de ışık her vuruşta sönüp düşük tepede kalmalı: \(vurusEn) \(vurusTepe)")

    precondition(yaziyor(10, 9) && !yaziyor(10, 8) && !yaziyor(10, 0), "yazma penceresi 2 sn")
    precondition(geceMi(23, 23, 7) && geceMi(3, 23, 7) && !geceMi(7, 23, 7) && !geceMi(12, 23, 7), "gece gece yarısını aşmalı")
    precondition(geceMi(12, 9, 17) && !geceMi(17, 9, 17) && !geceMi(5, 5, 5), "gündüz aralığı")
    precondition(klavyeHatalari.contains("Klavye bağlantısı koptu") && !klavyeHatalari.contains("Ekran Kaydı izni gerekli"), "yalnız klavye hatası yeniden dener")

    precondition(nefesSeviye(0) == 0 && nefesSeviye(2) == 7 && nefesSeviye(4) == 0, "nefes döngüsü")

    var s = Sessizlik()
    precondition(s.ekle(0, 0) == nil && s.ekle(0, 4.9) == nil, "5 sn dolmadan dönmemeli")
    precondition(s.ekle(0, 5) == .sensoreDon && s.sensorde, "5 sn sonra sensöre dönmeli")
    precondition(s.ekle(0, 6) == nil, "bir kez dönmeli")
    precondition(s.ekle(0.1, 7) == .geriGel && !s.sensorde, "ses gelince geri gelmeli")
    precondition(s.ekle(0, 8) == nil && s.ekle(0.1, 12) == nil && s.ekle(0, 13) == nil && s.ekle(0, 17.9) == nil, "ses sayacı sıfırlamalı")

    let ornekYedek: [UInt8] = [0x01, 0x0d, 0x3d, 0x01, 0x00, 0x04, 0x06, 0x00, 0x06, 0x00, 0x3c, 0x00]
    precondition(ayarBaytlari(ornekYedek, nil) == [0x01, 0x0d, 0xff, 0x04, 0x06, 0x00, 0x06, 0x00, 0x3c, 0x00], "geri alma yedeği aynen yazmalı")
    precondition(ayarBaytlari(ornekYedek, 7) == [0x01, 0x1d, 0xff, 0x07, 0x78, 0x00, 0x78, 0x00, 0x3c, 0x00], "seviye elle kipte yazılmalı")
    var otomatikOkunan = ornekYedek
    otomatikOkunan[5] = 0
    precondition(ayarAyni(otomatikOkunan, ornekYedek), "otomatik kipte seviye farkı sayılmamalı")
    var elleOkunan = otomatikOkunan, elleYedek = ornekYedek
    elleOkunan[1] = 0x1d
    elleYedek[1] = 0x1d
    precondition(!ayarAyni(elleOkunan, elleYedek), "elle kipte seviye farkı sayılmalı")
    otomatikOkunan[7] = 1
    precondition(!ayarAyni(otomatikOkunan, ornekYedek), "süre farkı sayılmalı")

    precondition(Pil(yuzde: 10, seviyeBit: 0, sarjda: false).dusuk, "%10 düşük")
    precondition(!Pil(yuzde: 11, seviyeBit: 0, sarjda: false).dusuk, "%11 düşük değil")
    precondition(!Pil(yuzde: 5, seviyeBit: 0, sarjda: true).dusuk, "şarjda düşük sayılmaz")
    precondition(Pil(yuzde: 0, seviyeBit: 1, sarjda: false).dusuk, "kritik bit düşük")
    print("test tamam")
}

func cli(_ m: Mod, _ sure: Double, _ kaynak: String, _ hassasiyet: Float, _ bant: Bant, _ sonus: Float, _ basKesim: Float) {
    let motor = Motor(ayar: Ayarlar(mod: m, hassasiyet: hassasiyet, bant: bant, sonus: sonus, basKesim: basKesim), kaynak: kaynak, onceki: nil)
    motor.sure = sure
    motor.bitince = { h in if let h { print("Hata: \(h)") } }
    signal(SIGINT, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    s.setEventHandler { motor.durdur() }
    s.resume()
    motor.basla()
    motor.grup.wait()
    print("Mod: \(m.rawValue), tik: \(motor.tik), yazma: \(motor.yazma), hata: \(motor.hataSayisi)")
    print(String(format: "En yüksek RMS: %.4f", motor.enYuksek))
    print("Seviye dağılımı (0-7): \(motor.dagilim)")
}

@main
struct Giris {
    static func main() {
        let a = CommandLine.arguments
        func deger(_ ad: String) -> String? {
            a.firstIndex(of: ad).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
        }
        if a.contains("test") {
            testler()
        } else if a.contains("--pil") {
            print(pilOku().map { "\($0.metin), düşük: \($0.dusuk), ham: \($0.yuzde) \($0.seviyeBit)" } ?? "Pil okunamadı")
        } else if let ad = deger("--mod"), let m = Mod.allCases.first(where: { $0.rawValue.lowercased() == ad }) {
            cli(m, deger("--sure").flatMap(Double.init) ?? 45, deger("--kaynak") ?? "", deger("--hassasiyet").flatMap(Float.init) ?? 0.5, Bant.allCases.first { $0.rawValue.lowercased() == deger("--bant") } ?? .bas, deger("--sonus").flatMap(Float.init) ?? 0.5, deger("--kesim").flatMap(Float.init) ?? Float(60) / 190)
        } else {
            IsikUygulama.main()
        }
    }
}
