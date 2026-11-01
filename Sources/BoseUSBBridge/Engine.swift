import Foundation
import CoreAudio

final class BridgeEngine {
    var onChange: ((BridgeState) -> Void)?
    private(set) var state = BridgeState()
    private let defaults = UserDefaults(suiteName: ServiceRuntime.identifier)!
    private let worker = DispatchQueue(label: "local.codex.BoseUSBBridge.device", qos: .utility, autoreleaseFrequency: .workItem)
    private let folder = ServiceRuntime.supportDirectory
    private let diagnostics = Diagnostics(url: ServiceRuntime.diagnosticsURL)
    private var session: RoutingSession?
    private var watcher: USBWatcher?
    private let observer = AudioObserver()
    private let volumeObserver = AudioObserver()
    private var notificationFallback: Timer?
    private var wakeObserver: SystemWakeObserver?
    private var outputDebounce: DispatchWorkItem?
    private var debounce: DispatchWorkItem?
    private var disconnected: DispatchWorkItem?
    private var currentToken: OperationToken?
    private var activeUID: String?
    private var knownRegistryID: UInt64?
    private var faultHold = false
    private var manualHold: Bool
    private var quitting = false
    private var cleanupRequested = false
    private var cleanupInProgress = false
    private var cleanupCompletions: [() -> Void] = []

    init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        if let data = try? Data(contentsOf: folder.appendingPathComponent("routing-session.json")) { session = try? JSONDecoder().decode(RoutingSession.self, from: data) }
        manualHold = defaults.bool(forKey: "manualHold")
        state.autoEnabled = !defaults.bool(forKey: "automaticDisabled")
    }

    func start() {
        note("service_started")
        watcher = USBWatcher { [weak self] in self?.scheduleRefresh() }
        let devicesObserved = observer.add(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices) { [weak self] in self?.scheduleRefresh() }
        let outputObserved = observer.add(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.outputChanged() }
        wakeObserver = SystemWakeObserver { [weak self] in self?.scheduleRefresh(delay: 1.5) }
        if watcher?.isActive != true || !devicesObserved || !outputObserved || wakeObserver == nil {
            // Only degrade to periodic recovery if an OS subscription failed.
            note("notification_fallback_enabled")
            notificationFallback = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.reconcile(); self?.outputChanged()
            }
            notificationFallback?.tolerance = 10
        }
        // A crash followed by an offline output change must not undo the user's choice.
        if USBInventory.devices().isEmpty, session != nil, AudioDevices.current()?.uid != session?.targetUID { session?.restoreAllowed = false }
        reconcile()
    }

    private func note(_ event: String) {
        diagnostics.record(event)
        saveDiagnostic()
    }
    private func publish(_ title: String, _ detail: String, active: Bool = false, busy: Bool = false) {
        state.statusText = title; state.detailText = detail; state.active = active; state.busy = busy
        state.manualOverride = session?.restoreAllowed == false
        saveDiagnostic(); onChange?(state)
    }
    private func saveSession() {
        let url = folder.appendingPathComponent("routing-session.json")
        if let session, let data = try? JSONEncoder().encode(session) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else { try? FileManager.default.removeItem(at: url) }
    }
    private func saveDiagnostic() {
        diagnostics.schedule { [weak self] in self?.diagnosticSnapshot() ?? [:] }
    }
    private func diagnosticSnapshot() -> [String: Any] {
        ["app": "Bose USB Background", "version": ServiceRuntime.version, "status": state.statusText,
         "detail": state.detailText, "active": state.active, "busy": state.busy, "connected": state.connected,
         "automatic": state.autoEnabled, "manualHold": manualHold, "outputOverride": session?.restoreAllowed == false,
         "defaultOutput": AudioDevices.current()?.name ?? "없음", "rememberedVolume": defaults.object(forKey: "rememberedVolume") ?? NSNull(),
         "notificationFallback": notificationFallback != nil, "firmwareWrites": false]
    }
    private func scheduleRefresh(delay: TimeInterval = 0.35) {
        guard !quitting else { return }
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reconcile() }; debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
    private func outputChanged() {
        outputDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.quitting, !self.state.busy, let uid = self.activeUID else { return }
            self.outputDebounce = nil
            let targets = AudioDevices.outputs()
            guard targets.contains(where: { $0.uid == uid && $0.alive }), !USBInventory.devices().isEmpty else { return }
            let current = AudioDevices.current()
            if current?.uid != uid {
                if self.session?.restoreAllowed == true {
                    self.session?.restoreAllowed = false; self.saveSession(); self.note("user_output_choice_preserved")
                }
                self.publish("USB 준비됨", "현재 출력: \(current?.name ?? "다른 장치") · 사용자 선택 유지", active: true)
            } else { self.publish("USB 스피커 사용 중", "USB 연결 · 펌웨어 1.0.20", active: true) }
        }
        outputDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
    private func reconcile() {
        guard !quitting, !state.busy else { return }
        let devices = USBInventory.devices()
        state.connected = !devices.isEmpty
        if devices.isEmpty {
            if disconnected == nil && (knownRegistryID != nil || session != nil || activeUID != nil || faultHold || manualHold) {
                let item = DispatchWorkItem { [weak self] in
                    guard let self else { return }; self.disconnected = nil
                    if USBInventory.devices().isEmpty, !self.state.busy { self.handleDisconnect() } else { self.reconcile() }
                }; disconnected = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
            }
            if activeUID == nil { publish("연결 대기", "Bose를 USB로 연결하면 자동으로 준비합니다.") }
            return
        }
        disconnected?.cancel(); disconnected = nil
        guard devices.count == 1 else { publish("Bose 연결을 확인해 주세요", "지원 장치 한 대만 연결해 주세요."); return }
        let device = devices[0]
        if let knownRegistryID, knownRegistryID != device.registryID {
            // Mode rollback also changes registry IDs; faults require detach or Retry.
            if manualHold { manualHold = false; defaults.set(false, forKey: "manualHold") }
        }
        knownRegistryID = device.registryID
        if let activeUID, device.productID == 0x40fa, AudioDevices.outputs().contains(where: { $0.uid == activeUID && $0.isBoseUSB }) { return }
        if !state.autoEnabled { publish("자동 전환 꺼짐", "bose-usb resume으로 자동 USB 전환을 켤 수 있습니다."); return }
        if manualHold { publish("일반 모드", "이번 연결은 유지합니다. bose-usb resume으로 USB 전환을 재개합니다."); return }
        if faultHold { return }
        activate()
    }
    private func handleDisconnect() {
        volumeObserver.clear(); activeUID = nil; knownRegistryID = nil
        restoreRouting(); session = nil; saveSession()
        manualHold = false; defaults.set(false, forKey: "manualHold"); faultHold = false
        state.connected = false; note("usb_disconnected_output_restored_if_owned")
        publish("연결 대기", state.autoEnabled ? "Bose를 USB로 연결하면 자동으로 준비합니다." : "자동 USB 전환이 꺼져 있습니다.")
    }
    private func restoreRouting() {
        guard let session else { return }
        let outputs = AudioDevices.outputs()
        if let uid = RoutingPolicy.restoreUID(session: session, currentUID: AudioDevices.current()?.uid, availableUIDs: Set(outputs.map(\.uid))), let device = outputs.first(where: { $0.uid == uid && $0.alive }) {
            do { try AudioDevices.setDefault(device); note("previous_output_restored") }
            catch { note("output_restore_failed") }
        }
    }
    private func step(_ title: String, token: OperationToken) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentToken === token, !token.cancelled else { return }
            self.publish("USB 준비 중…", title, busy: true)
        }
    }
    private func wait<T>(seconds: TimeInterval, token: OperationToken, _ body: () -> T?) throws -> T {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            try token.check()
            if let value = body() { return value }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < end
        throw BridgeError("USB 장치가 준비되지 않았습니다. 케이블 연결을 확인해 주세요.")
    }
    private func activate() {
        guard !state.busy, !quitting else { return }
        let token = OperationToken(); currentToken = token
        let original = AudioDevices.current()
        if session == nil { session = RoutingSession(previousUID: original?.isBoseUSB == true ? nil : original?.uid, previousName: original?.name, targetUID: nil, originalVolume: nil) }
        saveSession()
        let savedSession = session!, remembered = defaults.object(forKey: "rememberedVolume") as? Float
        note("activation_started"); publish("USB 준비 중…", "장치와 펌웨어를 확인합니다.", busy: true)
        worker.async {
            var updated = savedSession
            var verified = false
            var errorText: String?
            do {
                let devices = USBInventory.devices()
                guard devices.count == 1 else { throw BridgeError("Bose 한 대의 연결이 필요합니다.") }
                try token.check()
                if devices[0].productID == 0x40fe {
                    try DeviceHelpers.require("bose_mode", ["audio"]); verified = true
                }
                self.step("USB 오디오 장치를 등록합니다.", token: token)
                _ = try self.wait(seconds: 12, token: token) { () -> USBIdentity? in
                    let d = USBInventory.devices(); return d.count == 1 && d[0].productID == 0x40fa ? d[0] : nil
                }
                if AudioDevices.outputs().filter(\.isBoseUSB).isEmpty { try DeviceHelpers.require("native_usb", ["configure"]) }
                let target = try self.wait(seconds: 8, token: token) { () -> AudioDevice? in let targets = AudioDevices.outputs().filter(\.isBoseUSB); return targets.count == 1 ? targets[0] : nil }
                try token.check(); self.step("스피커의 USB 입력을 선택합니다.", token: token)
                try DeviceHelpers.require("bose_source", ["usb"]); verified = true
                try token.check()
                updated.targetUID = target.uid
                if updated.originalVolume == nil { updated.originalVolume = AudioDevices.volume(target) }
                try AudioDevices.setVolume(RoutingPolicy.initialVolume(remembered: remembered), on: target)
                try token.check()
                let current = AudioDevices.current()
                if current?.uid != original?.uid && current?.uid != target.uid { updated.restoreAllowed = false }
                if updated.restoreAllowed { try AudioDevices.setDefault(target) }
                try token.check()
            } catch {
                errorText = String(describing: error)
                if let uid = updated.targetUID, let volume = updated.originalVolume, let target = AudioDevices.outputs().first(where: { $0.uid == uid && $0.isBoseUSB }) { try? AudioDevices.setVolume(volume, on: target) }
                // Restore only a version we verified in this operation. No speculative tokens.
                let remaining = USBInventory.devices()
                if verified, remaining.count == 1, remaining[0].productID == 0x40fa { _ = try? DeviceHelpers.run("bose_mode", ["normal"]) }
            }
            DispatchQueue.main.async {
                self.session = updated; self.saveSession(); self.currentToken = nil
                let currentDevices = USBInventory.devices()
                self.knownRegistryID = currentDevices.first?.registryID
                self.state.connected = !currentDevices.isEmpty
                if let errorText {
                    self.activeUID = nil; self.restoreRouting()
                    self.session = nil; self.saveSession(); self.faultHold = true
                    self.note("activation_failed"); self.publish("USB 전환 중단", errorText)
                } else {
                    self.activeUID = updated.targetUID; self.faultHold = false
                    self.watchVolume(); self.note("usb_ready")
                    self.publish(updated.restoreAllowed ? "USB 스피커 사용 중" : "USB 준비됨", updated.restoreAllowed ? "USB 연결 · 펌웨어 1.0.20" : "다른 출력 장치의 사용자 선택을 유지합니다.", active: true)
                }
                if self.cleanupRequested {
                    self.cleanupRequested = false
                    self.cleanup(completion: nil)
                } else if !self.quitting, token.cancelled { self.returnToNormal() }
            }
        }
    }
    private func watchVolume() {
        volumeObserver.clear()
        guard let uid = activeUID, let target = AudioDevices.outputs().first(where: { $0.uid == uid && $0.isBoseUSB }) else { return }
        func remember() {
            guard let v = AudioDevices.volume(target), v.isFinite, (0...1).contains(v) else { return }
            if defaults.object(forKey: "rememberedVolume") as? Float != v { defaults.set(v, forKey: "rememberedVolume") }
            saveDiagnostic()
        }
        remember()
        volumeObserver.add(target.id, selector: kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput) { [weak self] in
            guard let self, !self.state.busy, let v = AudioDevices.volume(target), v.isFinite, (0...1).contains(v) else { return }
            guard self.defaults.object(forKey: "rememberedVolume") as? Float != v else { return }
            self.defaults.set(v, forKey: "rememberedVolume"); self.saveDiagnostic()
        }
    }
    func setAutomaticEnabled(_ enabled: Bool) {
        state.autoEnabled = enabled; defaults.set(!enabled, forKey: "automaticDisabled")
        note(enabled ? "automatic_enabled" : "automatic_disabled")
        if enabled { retry() } else { currentToken?.cancel(); if !state.busy { returnToNormal() } }
    }
    func retry() {
        guard !quitting, !state.busy else { return }
        manualHold = false; defaults.set(false, forKey: "manualHold"); faultHold = false
        // An explicit resume is a fresh request to route audio to Bose. Remember
        // the user's current alternative so the next detach restores that choice.
        if let current = AudioDevices.current(), !current.isBoseUSB {
            session?.previousUID = current.uid; session?.previousName = current.name
        }
        session?.restoreAllowed = true; saveSession()
        guard USBInventory.devices().count == 1 else { reconcile(); return }
        activate()
    }
    func returnToNormal() { cleanup(completion: nil) }
    private func cleanup(completion: (() -> Void)?) {
        if let completion { cleanupCompletions.append(completion) }
        manualHold = true; defaults.set(true, forKey: "manualHold")
        currentToken?.cancel()
        if cleanupInProgress { return }
        if state.busy {
            cleanupRequested = true
            return
        }
        cleanupInProgress = true
        volumeObserver.clear(); activeUID = nil
        restoreRouting()
        if let uid = session?.targetUID, let volume = session?.originalVolume, let target = AudioDevices.outputs().first(where: { $0.uid == uid && $0.isBoseUSB }) { try? AudioDevices.setVolume(volume, on: target) }
        publish("일반 모드 복귀 중…", "이전 출력과 스피커 모드를 복원합니다.", busy: true)
        worker.async {
            var failure: String?
            let d = USBInventory.devices()
            if d.count == 1 && d[0].productID == 0x40fa {
                do {
                    do { try DeviceHelpers.require("bose_mode", ["normal"]) }
                    catch {
                        // Standard configuration can recover an unpublished HID interface.
                        try DeviceHelpers.require("native_usb", ["configure"])
                        try DeviceHelpers.require("bose_mode", ["normal"])
                    }
                    let stop = Date().addingTimeInterval(8)
                    while Date() < stop && USBInventory.devices().first?.productID != 0x40fe { Thread.sleep(forTimeInterval: 0.25) }
                    if USBInventory.devices().first?.productID != 0x40fe { throw BridgeError("일반 모드 재인식을 확인하지 못했습니다.") }
                } catch { failure = String(describing: error) }
            }
            DispatchQueue.main.async {
                if failure == nil { self.session = nil; self.saveSession() }
                let currentDevices = USBInventory.devices()
                self.knownRegistryID = currentDevices.first?.registryID
                self.state.connected = !currentDevices.isEmpty
                self.cleanupInProgress = false
                self.note(failure == nil ? "normal_mode_restored" : "normal_mode_restore_failed")
                self.publish(failure == nil ? (self.state.connected ? "일반 모드" : "연결 대기") : "복귀 확인 필요", failure ?? "이번 연결은 일반 모드로 유지합니다.")
                let completions = self.cleanupCompletions; self.cleanupCompletions.removeAll()
                completions.forEach { $0() }
            }
        }
    }
    func shutdown(completion: @escaping () -> Void) {
        let preserveHold = manualHold
        quitting = true; notificationFallback?.invalidate(); debounce?.cancel(); disconnected?.cancel(); outputDebounce?.cancel()
        observer.clear(); watcher = nil
        wakeObserver?.stop(); wakeObserver = nil
        cleanup {
            self.manualHold = self.state.statusText == "복귀 확인 필요" || preserveHold
            self.defaults.set(self.manualHold, forKey: "manualHold")
            self.diagnostics.write(self.diagnosticSnapshot()); completion()
        }
    }
}
