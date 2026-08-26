import Foundation
let wsURL = URL(string: CommandLine.arguments[1])!
let out = CommandLine.arguments[2]
let sem = DispatchSemaphore(value: 0)
let t = URLSession.shared.webSocketTask(with: wsURL)
t.maximumMessageSize = 64*1024*1024
t.resume()
let p: [String: Any] = ["id":1,"method":"Page.captureScreenshot","params":["format":"png"]]
t.send(.string(String(data: try! JSONSerialization.data(withJSONObject: p), encoding: .utf8)!)) { e in
  if let e { print("ERR \(e)"); sem.signal(); return }
  t.receive { r in
    if case .success(.string(let s)) = r,
       let d = s.data(using:.utf8),
       let j = try? JSONSerialization.jsonObject(with:d) as? [String:Any],
       let res = j["result"] as? [String:Any],
       let b64 = res["data"] as? String,
       let img = Data(base64Encoded: b64) {
      try? img.write(to: URL(fileURLWithPath: out)); print("OK \(img.count)")
    } else { print("FAIL") }
    sem.signal()
  }
}
_ = sem.wait(timeout: .now()+30)
t.cancel(with: .normalClosure, reason: nil)
