// The Mac's thermal state as macOS gives it to apps: nominal, fair, serious
// or critical. The final round measures only at "nominal" (common.sh).
import Foundation

switch ProcessInfo.processInfo.thermalState {
case .nominal: print("nominal")
case .fair: print("fair")
case .serious: print("serious")
case .critical: print("critical")
@unknown default: print("unknown")
}
