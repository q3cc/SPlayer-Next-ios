import Foundation
import JavaScriptCore

@main
struct RecognitionRuntimeTests {
  static func main() throws {
    let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
    let context = JSContext()!
    context.evaluateScript("var console={log:function(){},warn:function(){}};")
    context.evaluateScript(source)
    precondition(context.exception == nil, context.exception?.toString() ?? "")
    let samples = (0..<96000).map { Float(0.2 * sin(Double($0) * 2 * .pi * 440 / 8000)) }
    for _ in 0..<3 {
      let start = Date()
      let result = context.objectForKeyedSubscript("recognitionFingerprint")!.call(withArguments: [samples])
      precondition(context.exception == nil, context.exception?.toString() ?? "")
      precondition(!(result?.toArray() ?? []).isEmpty)
      print("PASS: JavaScriptCore 无 WebView 后台指纹，耗时 \(Date().timeIntervalSince(start)) 秒")
    }
  }
}
