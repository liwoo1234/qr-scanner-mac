import Foundation

/// Wi-Fi 정보 (WIFI:T:WPA;S:이름;P:비밀번호;H:false;;)
struct WiFiInfo: Equatable {
    var ssid: String
    var password: String?
    var security: String?
    var hidden: Bool
}

/// QR 코드 안에 들어있는 내용의 종류
enum QRContent: Equatable {
    case web(URL)
    case email(address: String, subject: String?, body: String?)
    case phone(String)
    case sms(number: String, body: String?)
    case wifi(WiFiInfo)
    case geo(lat: Double, lon: Double, label: String?)
    case contact(name: String?, vcard: String)
    case event(summary: String?, ics: String)
    case appLink(URL)
    case text(String)

    // MARK: - 파싱

    static func parse(_ raw: String) -> QRContent {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = s.uppercased()

        if upper.hasPrefix("WIFI:") {
            let f = meFields(String(s.dropFirst(5)))
            let ssid = f["S"] ?? ""
            let pass = f["P"].flatMap { $0.isEmpty ? nil : $0 }
            let sec = f["T"].flatMap { $0.isEmpty ? nil : $0 }
            let hidden = (f["H"] ?? "").lowercased() == "true"
            return .wifi(WiFiInfo(ssid: ssid, password: pass, security: sec, hidden: hidden))
        }
        if upper.hasPrefix("BEGIN:VCARD") {
            var name = vField(s, "FN")
            if name == nil, let n = vField(s, "N") {
                name = n.split(separator: ";").reversed().joined(separator: " ").trimmingCharacters(in: .whitespaces)
            }
            return .contact(name: name, vcard: s)
        }
        if upper.hasPrefix("MECARD:") {
            return mecardToContact(String(s.dropFirst(7)))
        }
        if upper.hasPrefix("BEGIN:VEVENT") || upper.hasPrefix("BEGIN:VCALENDAR") {
            return .event(summary: vField(s, "SUMMARY"), ics: s)
        }
        if upper.hasPrefix("MATMSG:") {
            let f = meFields(String(s.dropFirst(7)))
            return .email(address: f["TO"] ?? "", subject: f["SUB"], body: f["BODY"])
        }
        if upper.hasPrefix("MAILTO:") {
            let comps = URLComponents(string: s)
            let addr = comps?.path ?? String(s.dropFirst(7))
            let items = comps?.queryItems ?? []
            let subject = items.first { $0.name.lowercased() == "subject" }?.value
            let body = items.first { $0.name.lowercased() == "body" }?.value
            return .email(address: addr.removingPercentEncoding ?? addr, subject: subject, body: body)
        }
        if upper.hasPrefix("TEL:") {
            return .phone(String(s.dropFirst(4)))
        }
        if upper.hasPrefix("SMSTO:") {
            let parts = s.dropFirst(6).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let number = parts.first.map(String.init) ?? ""
            let body = parts.count > 1 ? String(parts[1]) : nil
            return .sms(number: number, body: body?.isEmpty == true ? nil : body)
        }
        if upper.hasPrefix("SMS:") {
            var rest = String(s.dropFirst(4))
            var body: String?
            if let r = rest.range(of: "body=", options: .caseInsensitive) {
                body = String(rest[r.upperBound...]).removingPercentEncoding
                rest = String(rest[..<r.lowerBound])
            }
            let number = rest.trimmingCharacters(in: CharacterSet(charactersIn: "?&;"))
            return .sms(number: number, body: body)
        }
        if upper.hasPrefix("GEO:") {
            if let g = parseGeo(String(s.dropFirst(4))) { return g }
        }

        if let url = URL(string: s), let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" { return .web(url) }
            if s.contains("://"), !s.contains(" "),
               scheme.range(of: "^[a-z][a-z0-9+.-]*$", options: .regularExpression) != nil {
                return .appLink(url)
            }
        }
        // "www.example.com" 처럼 스킴이 없는 주소
        if !s.contains(" "), !s.contains("\n"),
           s.range(of: #"^(www\.)?[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}(:\d+)?(/\S*)?$"#, options: .regularExpression) != nil,
           let url = URL(string: "https://" + s) {
            return .web(url)
        }
        return .text(s)
    }

    /// "K:V;K:V;;" 형식(MECARD / WIFI / MATMSG)을 백슬래시 이스케이프를 고려해 분해
    static func meFields(_ body: String) -> [String: String] {
        var parts: [String] = []
        var cur = ""
        var escaping = false
        for ch in body {
            if escaping { cur.append(ch); escaping = false; continue }
            if ch == "\\" { escaping = true; continue }
            if ch == ";" { parts.append(cur); cur = ""; continue }
            cur.append(ch)
        }
        if !cur.isEmpty { parts.append(cur) }
        var result: [String: String] = [:]
        for p in parts {
            guard let idx = p.firstIndex(of: ":") else { continue }
            let key = String(p[..<idx]).uppercased()
            if result[key] == nil { result[key] = String(p[p.index(after: idx)...]) }
        }
        return result
    }

    /// vCard / iCalendar에서 "KEY:값" 또는 "KEY;PARAM=..:값" 줄의 값을 찾음
    static func vField(_ text: String, _ key: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r "))
            let up = l.uppercased()
            guard up.hasPrefix(key + ":") || up.hasPrefix(key + ";") else { continue }
            guard let idx = l.firstIndex(of: ":") else { continue }
            let v = String(l[l.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : v
        }
        return nil
    }

    private static func parseGeo(_ body: String) -> QRContent? {
        var coordPart = body
        var label: String?
        if let q = body.firstIndex(of: "?") {
            coordPart = String(body[..<q])
            let query = String(body[body.index(after: q)...])
            for pair in query.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2, kv[0].lowercased() == "q" {
                    label = String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
                }
            }
        }
        coordPart = String(coordPart.split(separator: ";").first ?? "")
        let nums = coordPart.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard nums.count >= 2, abs(nums[0]) <= 90, abs(nums[1]) <= 180 else { return nil }
        return .geo(lat: nums[0], lon: nums[1], label: label)
    }

    private static func mecardToContact(_ body: String) -> QRContent {
        let f = meFields(body)
        var name: String?
        var lines = ["BEGIN:VCARD", "VERSION:3.0"]
        if let n = f["N"] {
            let parts = n.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let last = parts.first ?? ""
            let first = parts.count > 1 ? parts[1] : ""
            name = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
            if name?.isEmpty == true { name = n }
            lines.append("N:\(last);\(first);;;")
            lines.append("FN:\(name ?? n)")
        }
        if let v = f["TEL"] { lines.append("TEL:\(v)") }
        if let v = f["EMAIL"] { lines.append("EMAIL:\(v)") }
        if let v = f["URL"] { lines.append("URL:\(v)") }
        if let v = f["ORG"] { lines.append("ORG:\(v)") }
        if let v = f["ADR"] { lines.append("ADR:;;\(v);;;;") }
        if let v = f["NOTE"] { lines.append("NOTE:\(v)") }
        if let v = f["BDAY"] { lines.append("BDAY:\(v)") }
        lines.append("END:VCARD")
        return .contact(name: name, vcard: lines.joined(separator: "\r\n"))
    }

    // MARK: - 표시용 정보

    var typeName: String {
        switch self {
        case .web: "웹사이트"
        case .email: "이메일"
        case .phone: "전화번호"
        case .sms: "문자 메시지"
        case .wifi: "Wi-Fi 네트워크"
        case .geo: "위치"
        case .contact: "연락처"
        case .event: "일정"
        case .appLink: "앱 링크"
        case .text: "텍스트"
        }
    }

    var icon: String {
        switch self {
        case .web: "safari"
        case .email: "envelope.fill"
        case .phone: "phone.fill"
        case .sms: "message.fill"
        case .wifi: "wifi"
        case .geo: "mappin.and.ellipse"
        case .contact: "person.crop.circle.fill"
        case .event: "calendar"
        case .appLink: "link"
        case .text: "text.alignleft"
        }
    }

    var title: String {
        switch self {
        case .web(let url):
            var host = url.host ?? url.absoluteString
            if host.hasPrefix("www.") { host.removeFirst(4) }
            return host
        case .email(let a, _, _): return a.isEmpty ? "이메일" : a
        case .phone(let n): return n
        case .sms(let n, _): return n.isEmpty ? "문자 메시지" : n
        case .wifi(let w): return w.ssid.isEmpty ? "(이름 없음)" : w.ssid
        case .geo(let lat, let lon, let label): return label ?? String(format: "%.5f, %.5f", lat, lon)
        case .contact(let name, _): return name ?? "연락처"
        case .event(let s, _): return s ?? "일정"
        case .appLink(let url): return (url.scheme ?? "") + "://" + (url.host ?? "")
        case .text(let t):
            let first = t.components(separatedBy: .newlines).first ?? t
            return first.count > 60 ? String(first.prefix(60)) + "…" : first
        }
    }

    /// 사용자가 주의해야 할 점 (피싱 의심 등)
    var warnings: [String] {
        var w: [String] = []
        switch self {
        case .web(let url):
            let host = (url.host ?? "").lowercased()
            if url.scheme?.lowercased() == "http" { w.append("암호화되지 않은 HTTP 링크입니다.") }
            if host.contains("xn--") { w.append("국제화(퓨니코드) 도메인입니다. 철자가 비슷한 가짜 사이트일 수 있어요.") }
            if host.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil {
                w.append("도메인 대신 IP 주소로 된 링크입니다.")
            }
            if url.user != nil { w.append("주소에 사용자 정보(@)가 포함돼 있어 실제 목적지가 다를 수 있습니다.") }
            let shorteners = ["bit.ly", "t.co", "tinyurl.com", "goo.gl", "is.gd", "ow.ly", "buff.ly",
                              "rebrand.ly", "cutt.ly", "me2.kr", "han.gl", "url.kr", "vo.la", "shorturl.at"]
            if shorteners.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                w.append("단축 URL입니다. 열기 전에는 실제 목적지를 알 수 없습니다.")
            }
        case .appLink:
            w.append("다른 앱을 실행하는 링크입니다. 신뢰할 수 있는 QR인지 확인하세요.")
        default:
            break
        }
        return w
    }
}
