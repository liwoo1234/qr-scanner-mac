import AppKit
import CoreImage

// QRContent 파서 + Vision 디코딩 자체 테스트
var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "✅" : "❌", name)
    if !ok { failures += 1 }
}

check("https", QRContent.parse("https://www.apple.com/kr") == .web(URL(string: "https://www.apple.com/kr")!))
check("bare domain", QRContent.parse("naver.com") == .web(URL(string: "https://naver.com")!))
check("wifi", QRContent.parse(#"WIFI:T:WPA;S:My\;Net;P:pa\:ss;H:true;;"#)
      == .wifi(WiFiInfo(ssid: "My;Net", password: "pa:ss", security: "WPA", hidden: true)))
check("mailto", QRContent.parse("mailto:a@b.com?subject=Hi&body=Yo") == .email(address: "a@b.com", subject: "Hi", body: "Yo"))
check("matmsg", QRContent.parse("MATMSG:TO:a@b.com;SUB:S;BODY:B;;") == .email(address: "a@b.com", subject: "S", body: "B"))
check("tel", QRContent.parse("tel:+82-10-1234-5678") == .phone("+82-10-1234-5678"))
check("smsto", QRContent.parse("SMSTO:01012345678:안녕") == .sms(number: "01012345678", body: "안녕"))
check("geo", QRContent.parse("geo:37.5665,126.978?q=서울시청") == .geo(lat: 37.5665, lon: 126.978, label: "서울시청"))
if case .contact(let n, _) = QRContent.parse("BEGIN:VCARD\nVERSION:3.0\nFN:홍길동\nEND:VCARD") { check("vcard", n == "홍길동") } else { check("vcard", false) }
if case .contact(let n, let v) = QRContent.parse("MECARD:N:홍,길동;TEL:0101234;;") { check("mecard", n == "길동 홍" && v.contains("TEL:0101234")) } else { check("mecard", false) }
if case .event(let s, _) = QRContent.parse("BEGIN:VEVENT\nSUMMARY:회의\nEND:VEVENT") { check("vevent", s == "회의") } else { check("vevent", false) }
if case .appLink = QRContent.parse("spotify://track/123") { check("app link", true) } else { check("app link", false) }
check("text", QRContent.parse("Hello: world") == .text("Hello: world"))
check("warn http", !QRContent.parse("http://bit.ly/abc").warnings.isEmpty)
check("no warn https", QRContent.parse("https://apple.com").warnings.isEmpty)

// 생성한 QR 이미지를 Vision으로 읽기
func makeQR(_ text: String) -> CGImage {
    let f = CIFilter(name: "CIQRCodeGenerator")!
    f.setValue(text.data(using: .utf8), forKey: "inputMessage")
    let img = f.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
    let padded = img.composited(over: CIImage(color: .white).cropped(to: img.extent.insetBy(dx: -40, dy: -40)))
    return CIContext().createCGImage(padded, from: padded.extent)!
}
let payload = "https://example.com/테스트?x=1"
check("vision decode", CameraScanner.decode(makeQR(payload)) == [payload])

// 테스트용 PNG 저장 (앱에서 열어보기용)
if CommandLine.arguments.count > 1 {
    let rep = NSBitmapImageRep(cgImage: makeQR(CommandLine.arguments[1]))
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}

print(failures == 0 ? "\n모든 테스트 통과" : "\n실패 \(failures)개")
exit(failures == 0 ? 0 : 1)
