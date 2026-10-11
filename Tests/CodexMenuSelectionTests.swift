import Foundation
func demand(_ value:@autoclosure()->Bool,_ message:String) { if !value() {fatalError(message)} }
@main struct CodexMenuSelectionAcceptance {
 static func main() {
  func window(_ p:Double)->CodexWindow {CodexWindow(usedPercent:p,windowDurationMins:nil,resetsAt:nil)}
  func bucket(_ id:String,_ p:Double?,_ s:Double?)->CodexBucket {CodexBucket(id:id,name:id,primary:p.map(window),secondary:s.map(window))}
  func check(_ buckets:[CodexBucket],_ expected:Double?) {
   demand(CodexSnapshot(accountLabel:"offline",buckets:buckets).menuBarPercent == expected,"Codex availability fallback/precedence")
  }
  check([],nil)
  check([bucket("codex",nil,nil),bucket("other",42,nil)],42)
  check([bucket("first",nil,nil),bucket("later",nil,0)],0)
  check([bucket("codex",101,42)],42)
  check([bucket("other",0,nil),bucket("codex",42,100)],42)
  check([bucket("codex",0,100)],0)
  check([bucket("first",nil,49),bucket("second",50,nil)],49)
  for invalid in [Double.nan, .infinity, -.infinity, -1, 101] {
   check([bucket("codex",invalid,nil)],nil)
   check([bucket("codex",invalid,0)],0)
   check([bucket("codex",invalid,invalid),bucket("other",100,nil)],100)
  }
  // New explicit user decision: hour-based session windows have global
  // priority over weekly/unknown duration, then preserve existing precedence.
  func timed(_ id:String,_ p:Double?,_ pm:Int?,_ s:Double?,_ sm:Int?)->CodexBucket {
   CodexBucket(id:id,name:id,primary:p.map{CodexWindow(usedPercent:$0,windowDurationMins:pm,resetsAt:nil)},secondary:s.map{CodexWindow(usedPercent:$0,windowDurationMins:sm,resetsAt:nil)})
  }
  check([timed("codex",14,10080,92,300)],92)
  check([timed("codex",14,10080,nil,nil),timed("other",80,300,nil,nil)],80)
  check([timed("other",90,300,nil,nil),timed("codex",0,300,nil,nil)],0)
  check([timed("codex",14,10080,40,60)],40)
  check([timed("codex",14,10080,101,300)],14)
  check([timed("codex",14,10080,nil,nil)],14)
  check([timed("codex",14,nil,40,300)],40)
  check([timed("codex",14,0,40,-60)],14)
  check([timed("codex",14,1440,40,10080)],14)
  check([timed("codex",12,60,40,300)],12)
  print("Codex menu selection acceptance passed")
 }
}
