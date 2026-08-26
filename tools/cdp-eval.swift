import Foundation
let wsURL = URL(string: CommandLine.arguments[1])!
let js = try! String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
let sem = DispatchSemaphore(value: 0)
let task = URLSession.shared.webSocketTask(with: wsURL)
task.maximumMessageSize = 64 * 1024 * 1024
task.resume()
let payload: [String: Any] = ["id":1,"method":"Runtime.evaluate",
  "params":["expression":js,"returnByValue":true]]
task.send(.string(String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!)) { e in
  if let e { print("SEND_ERR \(e)"); sem.signal(); return }
  task.receive { r in
    if case .success(.string(let s)) = r {
      if let d = s.data(using:.utf8), let j = try? JSONSerialization.jsonObject(with:d) as? [String:Any],
         let res = j["result"] as? [String:Any], let inner = res["result"] as? [String:Any] {
        print(inner["value"] ?? inner)
      } else { print(s.prefix(400)) }
    } else { print("RECV \(r)") }
    sem.signal()
  }
}
_ = sem.wait(timeout: .now()+40)
task.cancel(with: .normalClosure, reason: nil)
