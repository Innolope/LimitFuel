import Foundation
private func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
@main struct CodexAcceptance {
    static func main() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLAUDE_TEST_TMPDIR"] ?? FileManager.default.temporaryDirectory.path).appendingPathComponent("LimitFuel.Codex.Spec.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func executable(late: Bool) throws -> URL {
            let file = root.appendingPathComponent(late ? "late.py" : "initial.py")
            let script = """
            #!/usr/bin/env python3
            import json,sys
            expected=['initialize','initialized','account/read','account/rateLimits/read']
            for method in expected:
                line=sys.stdin.readline()
                if not line: sys.exit(2)
                request=json.loads(line)
                if request.get('method') != method: sys.exit(3)
                if method == 'initialized': continue
                if method == 'initialize': result={'userAgent':'synthetic'}
                elif method == 'account/read':
                    for _ in range(2):
                        print(json.dumps({'jsonrpc':'2.0','method':'account/updated','params':{'authMode':'chatgpt'}}),flush=True)
                    result={'account':{'type':'chatgpt','id':'synthetic','email':'synthetic@example.invalid','planType':'plus'},'requiresOpenaiAuth':False}
                else:
                    if \(late ? "True" : "False"):
                        print(json.dumps({'jsonrpc':'2.0','method':'account/updated','params':{'authMode':'chatgpt'}}),flush=True)
                    result={'rateLimits':{'limitId':'codex','primary':{'usedPercent':45,'windowDurationMins':300,'resetsAt':4102444800},'secondary':None}}
                print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':result}),flush=True)
            """
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            return file
        }
        let snapshot = try CodexClient(executable: executable(late: false), timeout: 2).fetch()
        check(!snapshot.buckets.isEmpty, "initial repeated account updates preserve ChatGPT snapshot")
        do {
            _ = try CodexClient(executable: executable(late: true), timeout: 2).fetch()
            fatalError("post-account-read update must invalidate snapshot")
        } catch { check(error is CodexUsageError, "expected typed Codex failure") }
        print("Codex acceptance passed")
    }
}
