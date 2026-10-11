import Foundation

private func demand(_ value: @autoclosure () -> Bool, _ message:String) { if !value() {fatalError(message)} }
private final class IntegrationDenyNetwork: URLProtocol {
 override class func canInit(with request:URLRequest)->Bool {true}
 override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
 override func startLoading() {fatalError("Menu integration attempted network")}
 override func stopLoading() {}
}
@main struct MenuPreferencesIntegrationAcceptance {
 static func main() throws {
  let suite="LimitFuel.MenuIntegration.\(UUID().uuidString)"
  let defaults=UserDefaults(suiteName:suite)!
  defer {defaults.removePersistentDomain(forName:suite)}
  defaults.set(false,forKey:"chrome_detection_enabled")
  defaults.set(false,forKey:"usage_notifications_enabled")
  let config=URLSessionConfiguration.ephemeral
  config.protocolClasses=[IntegrationDenyNetwork.self]
  let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["CLAUDE_TEST_TMPDIR"] ?? "/private/tmp").appendingPathComponent("menu-integration-empty-browser")
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  let reader=ChromeCookieReader(root:root,passwordProvider:{_ in fatalError("Menu integration attempted Keychain")})
  let usage=UsageManager(statusItem:nil,defaults:defaults,chromeReader:reader,apiSession:URLSession(configuration:config))
  let prefs=MenuBarPreferences(defaults:defaults)
  func parse(_ json:String) {usage.parseUsageData(Data(json.utf8))}
  func selected()->Double? {MenuBarSelection.selectedOption(provider:.claude,options:usage.menuBarOptions,selectionID:prefs.selectionID(for:.claude))?.percent}
  parse(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":34},"seven_day_sonnet":{"utilization":56},"limits":[{"percent":78,"scope":{"model":{"display_name":"Fable"}}}]}"#)
  demand(usage.menuBarOptions.count==4,"Known Claude windows must be available")
  demand(Set(usage.menuBarOptions.map(\.id)).count==4,"Claude role IDs must be unique")
  demand(selected()==12,"Claude Automatic must prefer session")
  let weekly=usage.menuBarOptions.first{$0.percent==34}!.id
  let originalIDs=usage.menuBarOptions.map(\.id)
  var callbacks=0
  var observed:Double?
  prefs.onChange={callbacks+=1;observed=selected()}
  prefs.select(weekly,for:.claude)
  demand(callbacks==1 && observed==34,"Preference callback must read new selected value immediately")
  prefs.select("codex-opaque-saved-id",for:.codex)
  demand(prefs.selectionID(for:.claude)==weekly && observed==34,"Independent Codex selection changed Claude")
  parse(#"{"five_hour":{"utilization":9}}"#)
  demand(usage.menuBarOptions.count==1 && selected()==9,"Missing saved Claude window must fall back freshly")
  demand(prefs.selectionID(for:.claude)==weekly,"Missing window destroyed saved selection")
  parse(#"{"five_hour":{"utilization":7},"seven_day":{"utilization":0}}"#)
  demand(selected()==0,"Returning saved weekly zero must recover")
  for bad in ["invalid","[]","{}",#"{"five_hour":{"utilization":true}}"#,#"{"five_hour":{"utilization":101}}"#,#"{"five_hour":{"utilization":-1}}"#] {
   parse(bad)
   demand(usage.menuBarOptions.isEmpty && selected()==nil,"Invalid Claude response retained a percentage")
  }
  parse(#"{"five_hour":{"utilization":0},"seven_day":{"utilization":"34"},"seven_day_sonnet":{"utilization":true},"limits":[{"percent":101,"scope":{"model":{"display_name":"Fable"}}}]}"#)
  demand(usage.menuBarOptions.count==1 && selected()==0,"Invalid optional windows must not create fake zero")
  demand(usage.menuBarOptions[0].id==originalIDs[0],"Claude role identity changed with percentage")
  usage.clearSessionCookie()
  demand(usage.menuBarOptions.isEmpty && selected()==nil,"Disconnect retained Claude account options")
  parse(#"{"five_hour":{"utilization":7}}"#)
  demand(selected()==7,"New account reused previous percentage")
  demand(prefs.selectionID(for:.claude)==weekly,"Account response destroyed opaque saved role preference")
  // Finder claim verification: duplicate display names must remain distinguishable
  // without relying on unstable percentage values as labels.
  func duplicates(_ a:Double,_ b:Double)->[MenuBarWindowOption] {
   CodexSnapshot(accountLabel:"OFFLINE",buckets:["demo-a","demo-b"].enumerated().map { index,id in
    CodexBucket(id:id,name:"Shared",primary:CodexWindow(usedPercent:index==0 ? a:b,windowDurationMins:300,resetsAt:nil),secondary:nil)
   }).menuBarOptions
  }
  let labels=duplicates(12,34).map(\.label)
  demand(Set(labels).count==2,"Duplicate bucket names produce indistinguishable Settings options")
  demand(labels==duplicates(90,0).map(\.label),"Bucket disambiguation must not depend on percentages")
  demand(labels[0].contains("demo-a") && labels[1].contains("demo-b"),"Duplicate bucket labels require stable bucket IDs")
  print("Menu preferences integration acceptance passed")
 }
}
