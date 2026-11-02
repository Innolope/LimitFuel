import Foundation
private func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
@main struct CodexAcceptance {
    static func main() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLAUDE_TEST_TMPDIR"] ?? FileManager.default.temporaryDirectory.path).appendingPathComponent("LimitFuel.Codex.Spec.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // macOS checks every new executable on its first launch, which took 5-10 s here, past
        // the 2 s client deadline under test. One script is written and launched once outside
        // the deadline; each case is a symlink to it, named for its mode.
        let file = root.appendingPathComponent("fixture.py")
        let script = """
            #!/usr/bin/env python3
            import json,os,sys
            late=os.path.basename(__file__).startswith('late')
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
                    if late:
                        print(json.dumps({'jsonrpc':'2.0','method':'account/updated','params':{'authMode':'chatgpt'}}),flush=True)
                    result={'rateLimits':{'limitId':'codex','primary':{'usedPercent':45,'windowDurationMins':300,'resetsAt':4102444800},'secondary':None}}
                print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':result}),flush=True)
            """
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        let warm = Process()
        warm.executableURL = file
        warm.standardInput = FileHandle.nullDevice
        warm.standardOutput = FileHandle.nullDevice
        warm.standardError = FileHandle.nullDevice
        try warm.run()
        let warmDeadline = Date().addingTimeInterval(60)
        while warm.isRunning && Date() < warmDeadline { Thread.sleep(forTimeInterval: 0.05) }
        if warm.isRunning { warm.terminate() }
        check(!warm.isRunning, "fixture script first launch completes within 60 s")
        func executable(late: Bool) throws -> URL {
            let link = root.appendingPathComponent(late ? "late.py" : "initial.py")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            return link
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
