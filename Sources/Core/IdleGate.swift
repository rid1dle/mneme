import Foundation

/// Reading the backlog of images waits until the user has been away a minute and the Mac is cool.
public func mayRunBackgroundWork(idleSeconds: Double, thermal: ProcessInfo.ThermalState) -> Bool {
    idleSeconds >= 60 && (thermal == .nominal || thermal == .fair)
}

/// One image just copied is read at once, unless the Mac is already warm (then it joins the backlog).
public func mayReadNewImage(thermal: ProcessInfo.ThermalState) -> Bool {
    thermal == .nominal || thermal == .fair
}
