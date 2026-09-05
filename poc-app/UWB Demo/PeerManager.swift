import ARKit
import Combine
import CoreBluetooth
import CoreLocation
import MultipeerConnectivity
import NearbyInteraction
import simd
import UIKit

final class PeerManager: NSObject, ObservableObject {
    struct Peer: Identifiable {
        let peerID: MCPeerID
        var distance: Float?
        var direction: simd_float3?
        var heading: Float?
        var uwbLatencyMs: Int?
        var bluetoothDistance: Float?
        var bluetoothLatencyMs: Int?
        /// Tracked UWB range. The view extrapolates it to render time.
        var range: RangeTrack?
        /// LocAR filter range, used when UWB has dropped out.
        var estimatedDistance: Float?
        var locarDirection: simd_float3?
        var locarHeading: Float?
        /// Why Nearby Interaction can't give a bearing yet, e.g. "sweep left/right".
        var hint: String?

        var id: MCPeerID { peerID }

        /// Distance to draw at `date` and whether it is backed by live UWB.
        func displayDistance(at date: Date) -> (meters: Float, isLive: Bool)? {
            if let range, !range.isStale(at: date) {
                return (range.value(at: date), range.isLive(at: date))
            }
            if let estimatedDistance {
                return (estimatedDistance, false)
            }
            if let bluetoothDistance {
                return (bluetoothDistance, false)
            }
            return nil
        }
        var displayName: String { peerID.displayName }
    }

    @Published var peers: [MCPeerID: Peer] = [:]
    @Published var localHeading: Float = 0
    @Published var unsupportedMessage: String?

    private let serviceType = "uwbdemo"
    private nonisolated let discoveryID: String
    private let localPeerID: MCPeerID
    private var mcSession: MCSession?
    private nonisolated(unsafe) var invitationSession: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var niSessions: [MCPeerID: NISession] = [:]
    private var configurations: [MCPeerID: NINearbyPeerConfiguration] = [:]
    private var sentTokenTo: Set<MCPeerID> = []
    private var establishedPeers: Set<MCPeerID> = []
    private var knownRemoteIDs: [MCPeerID: String] = [:]
    private var reconnectTasks: [MCPeerID: Task<Void, Never>] = [:]
    private var isTearingDown = false
    private let locationManager = CLLocationManager()
    private var lastSentHeading: Float?
    private var lastHeadingSend = Date.distantPast
    private let bleService = CBUUID(string: "55574244-4445-4D4F-8055-574244454D4F")
    private var bleCentral: CBCentralManager?
    private var blePeripheral: CBPeripheralManager?
    private var lastUWBUpdate: [MCPeerID: Date] = [:]
    private var pingSentAt: [MCPeerID: Date] = [:]
    private var pingTimer: Timer?
    private var bleFilters: [MCPeerID: BLEFilter] = [:]
    private var blePeripherals: [UUID: CBPeripheral] = [:]
    private var blePeripheralPeer: [UUID: MCPeerID] = [:]
    private var bleConnected: Set<UUID> = []
    private let vio = VIOTracker()
    private let locar = LocAREngine()
    private var lastVIOSend = Date.distantPast
    private var lastLocarPublish = Date.distantPast
    private var pendingVIOReset = false
    private var useCameraAssistance = NISession.deviceCapabilities.supportsCameraAssistance

    private struct RangeSample {
        let range: Float
        let date: Date
    }

    private var localRange: [MCPeerID: RangeSample] = [:]
    private var remoteRange: [MCPeerID: RangeSample] = [:]
    private var tracks: [MCPeerID: RangeTrack] = [:]
    private var bearingConfidence: [MCPeerID: Float] = [:]
    /// Filter expected range at the last tracker nudge, per peer.
    private var rangeBaseline: [MCPeerID: Float] = [:]
    private var vioFrame = 0
    private var lastNIDirection: [MCPeerID: (direction: simd_float3, date: Date)] = [:]
    /// Latest body azimuth to each peer (0 forward, positive right), radians.
    private var lastBearing: [MCPeerID: (angle: Float, date: Date)] = [:]
    /// Newest peer-to-peer range sample already fed to the filter, keyed "a|b".
    private var peerRangeDates: [String: Date] = [:]
    private var lastCalibration: [MCPeerID: Date] = [:]
    private let freshWindow: TimeInterval = 0.75
    private let directionWindow: TimeInterval = 0.5
    private let calibrationInterval: TimeInterval = 2
    /// Bearing confidence needed before VIO motion is allowed to dead-reckon range.
    private let deadReckonConfidence: Float = 0.7

    private struct BLESample {
        let rssi: Double
        let date: Date
    }

    private struct BLEFilter {
        var samples: [BLESample] = []
        var rssi: Double?
        var variance: Double = 16
        var meters: Float?
    }

    override init() {
        discoveryID = Self.storedDiscoveryID()
        localPeerID = Self.storedPeerID()
        super.init()
        guard NISession.isSupported, NISession.deviceCapabilities.supportsPreciseDistanceMeasurement else {
            unsupportedMessage = "This device does not support precise Ultra Wideband distance measurement."
            return
        }
        start()
    }

    private static func storedDiscoveryID() -> String {
        if let id = UserDefaults.standard.string(forKey: "UWBDemo.discoveryID") {
            return id
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "UWBDemo.discoveryID")
        return id
    }

    private static func storedPeerID() -> MCPeerID {
        if let data = UserDefaults.standard.data(forKey: "UWBDemo.mcPeerID"),
           let peer = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data) {
            return peer
        }
        let base = UIDevice.current.name
        let suffix = String(UUID().uuidString.prefix(4))
        let name = (base.isEmpty || base == "iPhone") ? "iPhone \(suffix)" : base
        let peer = MCPeerID(displayName: name)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: peer, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: "UWBDemo.mcPeerID")
        }
        return peer
    }

    private func start() {
        replaceSession()

        let advertiser = MCNearbyServiceAdvertiser(
            peer: localPeerID,
            discoveryInfo: ["id": discoveryID],
            serviceType: serviceType
        )
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser

        let browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
        startHeading()
        startBluetooth()
        startVIO()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.sendPings()
            self?.readConnectedRSSI()
            self?.shareRanges()
            self?.calibrateAllDue()
            self?.publishLocAR()
        }
    }

    private func startVIO() {
        vio.onPose = { [weak self] pose in
            self?.handleLocalVIO(pose)
        }
        vio.start()
    }

    private func handleLocalVIO(_ pose: VIOTracker.Pose) {
        guard pose.isReliable else { return }
        if pose.didResume {
            pendingVIOReset = true
        }
        let now = Date()
        locar.setLocal(pose)
        vioFrame += 1
        if vioFrame % 3 == 0 {
            deadReckon(at: now)
        }
        if now.timeIntervalSince(lastVIOSend) >= 0.1 {
            lastVIOSend = now
            sendVIO(pose)
        }
        if now.timeIntervalSince(lastLocarPublish) >= 0.07 {
            publishLocAR()
        }
    }

    /// 0x56 | x y z yaw (Float32 each) | flags (bit0 = ARKit re-origin)
    private func sendVIO(_ pose: VIOTracker.Pose) {
        guard let peers = mcSession?.connectedPeers, !peers.isEmpty else { return }
        var data = Data([0x56])
        var x = pose.position.x
        var y = pose.position.y
        var z = pose.position.z
        var yaw = pose.yaw
        withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &y) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &z) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &yaw) { data.append(contentsOf: $0) }
        data.append(pendingVIOReset ? 1 : 0)
        do {
            try mcSession?.send(data, toPeers: peers, with: .unreliable)
            pendingVIOReset = false
        } catch {}
    }

    private func handleRemoteVIO(_ data: Data, from peerID: MCPeerID) {
        let x = data.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: Float.self) }
        let y = data.subdata(in: 5..<9).withUnsafeBytes { $0.load(as: Float.self) }
        let z = data.subdata(in: 9..<13).withUnsafeBytes { $0.load(as: Float.self) }
        let yaw = data.subdata(in: 13..<17).withUnsafeBytes { $0.load(as: Float.self) }
        let isReset = data[data.startIndex + 17] & 1 == 1
        locar.ingestRemoteVIO(peerID: peerID, position: SIMD3<Float>(x, y, z), yaw: yaw, isReset: isReset)
        deadReckon(at: Date())
        if peers[peerID] == nil {
            peers[peerID] = Peer(peerID: peerID)
        }
        publishLocAR()
    }

    /// Feeds the range change the filter accumulated since the last baseline
    /// into each tracker, only when that peer's bearing is resolved (with an
    /// ambiguous ring the expected range barely moves anyway). Baselines are
    /// re-taken after every measurement so weight updates aren't counted as motion.
    private func deadReckon(at now: Date) {
        for id in tracks.keys {
            guard let new = locar.expectedRange(id) else { continue }
            if let base = rangeBaseline[id], (bearingConfidence[id] ?? 0) > deadReckonConfidence {
                tracks[id]?.nudge(new - base, at: now)
            }
            rangeBaseline[id] = new
        }
    }

    private func resetBaselines() {
        for id in tracks.keys {
            rangeBaseline[id] = locar.expectedRange(id)
        }
    }

    // MARK: Peer identity

    private var discoveryUUID: UUID? { UUID(uuidString: discoveryID) }

    /// 0x49 | discoveryID (UTF-8). Sent on connect so both sides know the
    /// other's stable ID regardless of who browsed and who advertised.
    private func sendHello(to peerID: MCPeerID) {
        var data = Data([0x49])
        data.append(contentsOf: Array(discoveryID.utf8))
        try? mcSession?.send(data, toPeers: [peerID], with: .reliable)
    }

    private func peer(forRemoteUUID uuid: UUID) -> MCPeerID? {
        let text = uuid.uuidString
        return knownRemoteIDs.first { $0.value.caseInsensitiveCompare(text) == .orderedSame }?.key
    }

    // MARK: Range fusion

    /// Both phones measure the same physical range. Each side averages its own
    /// fresh sample with the peer's fresh sample, so both screens see the same
    /// number. Stale samples are dropped instead of being re-used.
    private func fusedRange(for peerID: MCPeerID, at now: Date) -> Float? {
        let mine = localRange[peerID].flatMap { now.timeIntervalSince($0.date) < freshWindow ? $0.range : nil }
        let theirs = remoteRange[peerID].flatMap { now.timeIntervalSince($0.date) < freshWindow ? $0.range : nil }
        switch (mine, theirs) {
        case let (a?, b?):
            return (a + b) / 2
        case let (a?, nil):
            return a
        case let (nil, b?):
            return b
        default:
            return nil
        }
    }

    private func freshDirection(for peerID: MCPeerID, at now: Date) -> simd_float3? {
        guard let sample = lastNIDirection[peerID], now.timeIntervalSince(sample.date) < directionWindow else {
            return nil
        }
        return sample.direction
    }

    /// 0x52 | range (Float32) | age in ms (UInt16). Age lets the receiver keep
    /// its own freshness clock without synchronizing clocks between phones.
    private func sendRawRange(_ sample: RangeSample, to peerID: MCPeerID) {
        let ageMs = UInt16(clamping: Int(Date().timeIntervalSince(sample.date) * 1000))
        var data = Data([0x52])
        var value = sample.range
        var age = ageMs
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &age) { data.append(contentsOf: $0) }
        try? mcSession?.send(data, toPeers: [peerID], with: .unreliable)
    }

    private func shareRanges() {
        let now = Date()
        for (peerID, sample) in localRange where now.timeIntervalSince(sample.date) < freshWindow {
            sendRawRange(sample, to: peerID)
        }
        broadcastRangeList(at: now)
    }

    /// 0x54 | count (UInt8) | entries of: peer UUID (16 bytes) | range (Float32) | age ms (UInt16).
    /// Every phone hears every pair's range, which is what lets A↔B and B↔C
    /// constrain A↔C and lets a blocked pair be placed through a third phone.
    private func broadcastRangeList(at now: Date) {
        guard let session = mcSession, session.connectedPeers.count > 1 else { return }
        var entries = Data()
        var count: UInt8 = 0
        for (peerID, sample) in localRange where now.timeIntervalSince(sample.date) < freshWindow {
            guard let remoteID = knownRemoteIDs[peerID], let uuid = UUID(uuidString: remoteID) else { continue }
            withUnsafeBytes(of: uuid.uuid) { entries.append(contentsOf: $0) }
            var range = sample.range
            var age = UInt16(clamping: Int(now.timeIntervalSince(sample.date) * 1000))
            withUnsafeBytes(of: &range) { entries.append(contentsOf: $0) }
            withUnsafeBytes(of: &age) { entries.append(contentsOf: $0) }
            count += 1
            if count == 255 { break }
        }
        guard count > 0 else { return }
        var data = Data([0x54, count])
        data.append(entries)
        try? session.send(data, toPeers: session.connectedPeers, with: .unreliable)
    }

    private func handleRangeList(_ data: Data, from sender: MCPeerID) {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return }
        let count = Int(bytes[1])
        let entrySize = 22
        guard bytes.count == 2 + count * entrySize else { return }
        let now = Date()
        let mine = discoveryUUID
        var changed = false
        for index in 0..<count {
            let base = 2 + index * entrySize
            let uuid = bytes[base..<(base + 16)].withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
            let range = bytes[(base + 16)..<(base + 20)].withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
            let ageMs = bytes[(base + 20)..<(base + 22)].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
            guard range.isFinite, range > 0 else { continue }
            let date = now.addingTimeInterval(-Double(ageMs) / 1000)

            if let mine, uuid == mine {
                // The sender's measurement of the sender↔me range.
                if let existing = remoteRange[sender], existing.date >= date { continue }
                remoteRange[sender] = RangeSample(range: range, date: date)
                track(sender, measurement: range, sigma: RangeTrack.remoteSigma, at: date)
                if let fused = fusedRange(for: sender, at: now) {
                    locar.ingestUWB(peerID: sender, range: fused)
                }
                changed = true
                continue
            }

            guard let other = peer(forRemoteUUID: uuid), other != sender else { continue }
            let key = [sender.displayName, other.displayName].sorted().joined(separator: "|")
            if let last = peerRangeDates[key], last >= date { continue }
            peerRangeDates[key] = date
            locar.ingestPeerRange(sender, other, range: range)
            changed = true
        }
        if changed {
            resetBaselines()
            publishLocAR()
        }
    }

    private func handleRemoteRange(_ data: Data, from peerID: MCPeerID) {
        let range = data.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: Float.self) }
        let ageMs = data.subdata(in: 5..<7).withUnsafeBytes { $0.load(as: UInt16.self) }
        guard range.isFinite, range > 0 else { return }
        let date = Date().addingTimeInterval(-Double(ageMs) / 1000)
        if let existing = remoteRange[peerID], existing.date > date {
            return
        }
        remoteRange[peerID] = RangeSample(range: range, date: date)
        track(peerID, measurement: range, sigma: RangeTrack.remoteSigma, at: date)
        fuse(peerID)
    }

    private func track(_ peerID: MCPeerID, measurement: Float, sigma: Float, at date: Date) {
        if var track = tracks[peerID] {
            track.update(measurement, sigma: sigma, at: date)
            tracks[peerID] = track
        } else {
            tracks[peerID] = RangeTrack(range: measurement, at: date)
        }
    }

    private func fuse(_ peerID: MCPeerID) {
        let now = Date()
        if let range = fusedRange(for: peerID, at: now) {
            locar.ingestUWB(peerID: peerID, range: range)
            calibrateIfDue(peerID, range: range, at: now)
        }
        resetBaselines()
        publishLocAR()
    }

    private func freshBearing(for peerID: MCPeerID, at now: Date) -> Float? {
        guard let sample = lastBearing[peerID], now.timeIntervalSince(sample.date) < directionWindow else {
            return nil
        }
        return sample.angle
    }

    /// Body azimuth from this NI update. Camera-assisted `horizontalAngle` when
    /// present (positive = right, matching `asin(direction.x)`), otherwise the
    /// 3D direction projected through ARKit, otherwise the raw device-frame vector.
    private func bodyAngle(horizontalAngle: Float?, direction: simd_float3?) -> Float? {
        if let horizontalAngle, horizontalAngle.isFinite {
            return horizontalAngle
        }
        guard let direction else { return nil }
        if let angle = locar.bodyAngle(fromNI: direction) {
            return angle
        }
        // No ARKit pose: assume the phone is flat (forward = +Y) or upright (forward = -Z).
        if hypot(direction.x, direction.y) > 0.2 {
            return atan2(direction.x, direction.y)
        }
        return atan2(direction.x, -direction.z)
    }

    private static func hint(for convergence: NIAlgorithmConvergence) -> String? {
        switch convergence.status {
        case .converged:
            return nil
        case .notConverged(let reasons):
            guard let reason = reasons.first else { return "Move a little" }
            switch reason {
            case .insufficientHorizontalSweep:
                return "Sweep phone left/right"
            case .insufficientVerticalSweep:
                return "Tilt phone up/down"
            case .insufficientMovement:
                return "Move a little"
            case .insufficientLighting:
                return "Needs more light"
            default:
                return reason.localizedDescription
            }
        @unknown default:
            return nil
        }
    }

    private func handleConvergence(sessionID: ObjectIdentifier, hint: String?) {
        guard let peerID = peerID(for: sessionID), var peer = peers[peerID] else { return }
        guard peer.hint != hint else { return }
        peer.hint = hint
        peers[peerID] = peer
    }

    private func calibrateIfDue(_ peerID: MCPeerID, range: Float, at now: Date) {
        if let last = lastCalibration[peerID], now.timeIntervalSince(last) < calibrationInterval {
            return
        }
        let direction = freshDirection(for: peerID, at: now)
        if locar.calibrate(peerID: peerID, range: range, direction: direction) {
            lastCalibration[peerID] = now
        }
    }

    private func calibrateAllDue() {
        let now = Date()
        let ids = Set(localRange.keys).union(remoteRange.keys)
        for peerID in ids {
            guard let range = fusedRange(for: peerID, at: now) else { continue }
            calibrateIfDue(peerID, range: range, at: now)
        }
    }

    // MARK: Output

    private func publishLocAR() {
        let now = Date()
        lastLocarPublish = now
        for id in peers.keys {
            guard var peer = peers[id] else { continue }
            let estimate = locar.estimate(for: id)
            bearingConfidence[id] = estimate?.bearingConfidence ?? 0

            peer.range = tracks[id]
            peer.estimatedDistance = estimate?.distance

            if let estimate, estimate.bearingConfidence > 0.6 {
                peer.locarDirection = estimate.direction
            } else if let angle = freshBearing(for: id, at: now) {
                peer.locarDirection = simd_float3(sin(angle), cos(angle), 0)
            } else {
                peer.locarDirection = nil
            }
            peer.locarHeading = estimate?.heading
            peers[id] = peer
        }
    }

    private func startBluetooth() {
        bleCentral = CBCentralManager(delegate: self, queue: .main)
        blePeripheral = CBPeripheralManager(delegate: self, queue: .main)
    }

    private func sendPings() {
        guard let session = mcSession, !session.connectedPeers.isEmpty else { return }
        let now = Date()
        var payload = Data([0x50])
        var stamp = now.timeIntervalSince1970
        withUnsafeBytes(of: &stamp) { payload.append(contentsOf: $0) }
        for peer in session.connectedPeers {
            pingSentAt[peer] = now
        }
        try? session.send(payload, toPeers: session.connectedPeers, with: .unreliable)
    }

    private func readConnectedRSSI() {
        for peripheral in blePeripherals.values where peripheral.state == .connected {
            peripheral.readRSSI()
        }
    }

    private func rememberBLEPeripheral(_ peripheral: CBPeripheral, peerID: MCPeerID) {
        blePeripherals[peripheral.identifier] = peripheral
        blePeripheralPeer[peripheral.identifier] = peerID
        if peripheral.state == .disconnected || peripheral.state == .disconnecting {
            bleCentral?.connect(peripheral)
        }
    }

    private func forgetBluetooth(for peerID: MCPeerID) {
        bleFilters[peerID] = nil
        let ids = blePeripheralPeer.filter { $0.value == peerID }.map(\.key)
        for id in ids {
            if let peripheral = blePeripherals[id] {
                bleCentral?.cancelPeripheralConnection(peripheral)
            }
            blePeripherals[id] = nil
            blePeripheralPeer[id] = nil
            bleConnected.remove(id)
        }
    }

    private func applyBluetoothRSSI(_ rssi: Int, to peerID: MCPeerID) {
        guard (-95..<0).contains(rssi) else { return }

        let now = Date()
        var filter = bleFilters[peerID] ?? BLEFilter()
        filter.samples.append(BLESample(rssi: Double(rssi), date: now))
        filter.samples.removeAll { now.timeIntervalSince($0.date) > 3 }
        if filter.samples.count > 28 {
            filter.samples.removeFirst(filter.samples.count - 28)
        }

        guard filter.samples.count >= 4 else {
            let instant = Self.meters(fromRSSI: Double(rssi))
            filter.meters = instant
            bleFilters[peerID] = filter
            publishBluetoothDistance(instant, to: peerID)
            return
        }

        let measurement = Self.trimmedMean(filter.samples.map(\.rssi))
        if let estimate = filter.rssi {
            let process = 0.18
            var uncertainty = filter.variance + process
            let noise = abs(measurement - estimate) > 7 ? 48.0 : 14.0
            let gain = uncertainty / (uncertainty + noise)
            filter.rssi = estimate + gain * (measurement - estimate)
            filter.variance = (1 - gain) * uncertainty
        } else {
            filter.rssi = measurement
            filter.variance = 8
        }

        let raw = Self.meters(fromRSSI: filter.rssi ?? measurement)
        if let previous = filter.meters {
            let alpha: Float = abs(raw - previous) > 2 ? 0.05 : 0.1
            filter.meters = previous + alpha * (raw - previous)
        } else {
            filter.meters = raw
        }
        bleFilters[peerID] = filter
        publishBluetoothDistance(filter.meters ?? raw, to: peerID)
    }

    private func publishBluetoothDistance(_ meters: Float, to peerID: MCPeerID) {
        if var peer = peers[peerID] {
            peer.bluetoothDistance = meters
            peers[peerID] = peer
        } else {
            peers[peerID] = Peer(peerID: peerID, bluetoothDistance: meters)
        }
    }

    private static func meters(fromRSSI rssi: Double) -> Float {
        Float(min(max(pow(10, (-59 - rssi) / 22), 0.4), 25))
    }

    private static func trimmedMean(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard sorted.count >= 5 else { return sorted[sorted.count / 2] }
        let drop = max(sorted.count / 5, 1)
        let kept = sorted.dropFirst(drop).dropLast(drop)
        return kept.reduce(0, +) / Double(kept.count)
    }

    private func peerID(forAdvertisedName name: String?) -> MCPeerID? {
        if let name {
            if let match = knownRemoteIDs.first(where: { $0.value.hasPrefix(name) || name.hasPrefix($0.value.prefix(8)) }) {
                return match.key
            }
        }
        let connected = mcSession?.connectedPeers ?? []
        if connected.count == 1 {
            return connected[0]
        }
        return establishedPeers.count == 1 ? establishedPeers.first : nil
    }

    private func startHeading() {
        guard CLLocationManager.headingAvailable() else { return }
        locationManager.delegate = self
        locationManager.headingFilter = 2
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingHeading()
    }

    private func applyHeading(_ degrees: CLLocationDirection) {
        guard degrees >= 0 else { return }
        let heading = Float(degrees * .pi / 180)
        localHeading = heading
        let now = Date()
        let changed = lastSentHeading.map { abs(heading - $0) > 0.04 } ?? true
        guard changed, now.timeIntervalSince(lastHeadingSend) >= 0.12 else { return }
        lastSentHeading = heading
        lastHeadingSend = now
        sendHeading(heading)
    }

    private func sendHeading(_ heading: Float) {
        guard let peers = mcSession?.connectedPeers, !peers.isEmpty else { return }
        var data = Data([0x48])
        withUnsafeBytes(of: heading) { data.append(contentsOf: $0) }
        try? mcSession?.send(data, toPeers: peers, with: .unreliable)
    }

    private func replaceSession() {
        let old = mcSession
        old?.delegate = nil
        mcSession = nil
        invitationSession = nil
        let session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        mcSession = session
        invitationSession = session
        old?.disconnect()
    }

    private func remember(_ peerID: MCPeerID, remoteID: String?) {
        if let remoteID {
            knownRemoteIDs[peerID] = remoteID
        }
    }

    private func invite(_ peerID: MCPeerID, force: Bool = false) {
        guard let mcSession, !mcSession.connectedPeers.contains(peerID) else { return }
        if !force, let remoteID = knownRemoteIDs[peerID], discoveryID >= remoteID {
            return
        }
        let context = discoveryID.data(using: .utf8)
        browser?.invitePeer(peerID, to: mcSession, withContext: context, timeout: 12)
    }

    private func refreshDiscovery() {
        advertiser?.startAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        browser?.startBrowsingForPeers()
    }

    private func scheduleReconnect(_ peerID: MCPeerID) {
        reconnectTasks[peerID]?.cancel()
        reconnectTasks[peerID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let manager = self, !Task.isCancelled else { return }
            await MainActor.run {
                manager.attemptReconnect(peerID, force: false)
            }
            try? await Task.sleep(for: .seconds(2.5))
            guard let manager = self, !Task.isCancelled else { return }
            await MainActor.run {
                manager.attemptReconnect(peerID, force: true)
            }
        }
    }

    private func attemptReconnect(_ peerID: MCPeerID, force: Bool) {
        guard mcSession?.connectedPeers.contains(peerID) != true else { return }
        refreshDiscovery()
        invite(peerID, force: force)
    }

    private func handlePeerState(_ peerID: MCPeerID, _ state: MCSessionState) {
        switch state {
        case .connected:
            reconnectTasks[peerID]?.cancel()
            reconnectTasks[peerID] = nil
            establishedPeers.insert(peerID)
            if peers[peerID] == nil {
                peers[peerID] = Peer(peerID: peerID)
            }
            sendHello(to: peerID)
            sendDiscoveryToken(to: peerID, force: true)
            sendHeading(localHeading)
            if let pose = vio.pose, pose.isReliable {
                pendingVIOReset = true
                sendVIO(pose)
            }
        case .notConnected:
            guard !isTearingDown else { return }
            if establishedPeers.contains(peerID) {
                establishedPeers.remove(peerID)
                tearDown(peerID)
            }
            if mcSession?.connectedPeers.contains(peerID) == true {
                return
            }
            scheduleReconnect(peerID)
        default:
            break
        }
    }

    private func sendDiscoveryToken(to peerID: MCPeerID, force: Bool = false) {
        if !force, sentTokenTo.contains(peerID) {
            return
        }
        let session = niSession(for: peerID)
        guard let token = session.discoveryToken else { return }
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else { return }
        do {
            try mcSession?.send(data, toPeers: [peerID], with: .reliable)
            sentTokenTo.insert(peerID)
        } catch {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self else { return }
                try? self.mcSession?.send(data, toPeers: [peerID], with: .reliable)
                self.sentTokenTo.insert(peerID)
            }
        }
    }

    private func handleData(_ data: Data, from peerID: MCPeerID) {
        if data.count == 9, data.first == 0x50 {
            var reply = Data([0x51])
            reply.append(data.subdata(in: 1..<9))
            try? mcSession?.send(reply, toPeers: [peerID], with: .unreliable)
            return
        }
        if data.count == 9, data.first == 0x51 {
            if let sent = pingSentAt[peerID] {
                let ms = max(Int(Date().timeIntervalSince(sent) * 1000), 0)
                if var peer = peers[peerID] {
                    peer.bluetoothLatencyMs = ms
                    peers[peerID] = peer
                }
            }
            return
        }
        if data.count == 7, data.first == 0x52 {
            handleRemoteRange(data, from: peerID)
            return
        }
        if data.count >= 2, data.first == 0x54 {
            handleRangeList(data, from: peerID)
            return
        }
        if data.count > 1, data.first == 0x49 {
            if let id = String(data: data.dropFirst(), encoding: .utf8), UUID(uuidString: id) != nil {
                remember(peerID, remoteID: id)
            }
            return
        }
        if data.count == 18, data.first == 0x56 {
            handleRemoteVIO(data, from: peerID)
            return
        }
        if data.count == 5, data.first == 0x48 {
            let heading = data.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: Float.self) }
            if var peer = peers[peerID] {
                peer.heading = heading
                peers[peerID] = peer
            } else {
                peers[peerID] = Peer(peerID: peerID, heading: heading)
            }
            return
        }
        guard let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data) else { return }
        let session = niSession(for: peerID)
        let configuration = NINearbyPeerConfiguration(peerToken: token)
        configuration.isCameraAssistanceEnabled = useCameraAssistance
        configurations[peerID] = configuration
        session.run(configuration)
        sendDiscoveryToken(to: peerID)
    }

    private func niSession(for peerID: MCPeerID) -> NISession {
        if let session = niSessions[peerID] {
            return session
        }
        let session = NISession()
        session.delegate = self
        if useCameraAssistance {
            session.setARSession(vio.session)
        }
        niSessions[peerID] = session
        if peers[peerID] == nil {
            peers[peerID] = Peer(peerID: peerID)
        }
        return session
    }

    private func tearDown(_ peerID: MCPeerID) {
        isTearingDown = true
        let session = niSessions.removeValue(forKey: peerID)
        session?.delegate = nil
        configurations[peerID] = nil
        sentTokenTo.remove(peerID)
        lastUWBUpdate[peerID] = nil
        localRange[peerID] = nil
        remoteRange[peerID] = nil
        tracks[peerID] = nil
        bearingConfidence[peerID] = nil
        rangeBaseline[peerID] = nil
        lastNIDirection[peerID] = nil
        lastBearing[peerID] = nil
        peerRangeDates = peerRangeDates.filter { !$0.key.split(separator: "|").contains(Substring(peerID.displayName)) }
        lastCalibration[peerID] = nil
        pingSentAt[peerID] = nil
        forgetBluetooth(for: peerID)
        locar.forget(peerID)
        peers[peerID] = nil
        isTearingDown = false
    }

    private func peerID(for sessionID: ObjectIdentifier) -> MCPeerID? {
        niSessions.first(where: { ObjectIdentifier($0.value) == sessionID })?.key
    }

    private func handleUpdate(sessionID: ObjectIdentifier, distance: Float?, direction: simd_float3?, horizontalAngle: Float?) {
        guard let peerID = peerID(for: sessionID), var peer = peers[peerID] else { return }
        if let distance {
            peer.distance = distance
        }
        if let direction {
            peer.direction = direction
        }
        let now = Date()
        if let last = lastUWBUpdate[peerID] {
            peer.uwbLatencyMs = max(Int(now.timeIntervalSince(last) * 1000), 0)
        }
        lastUWBUpdate[peerID] = now
        peers[peerID] = peer
        if let direction {
            lastNIDirection[peerID] = (direction, now)
        }
        var changed = false
        if let angle = bodyAngle(horizontalAngle: horizontalAngle, direction: direction) {
            lastBearing[peerID] = (angle, now)
            locar.ingestBearing(peerID: peerID, bodyAngle: angle)
            changed = true
        }
        if let distance, distance.isFinite, distance > 0 {
            let sample = RangeSample(range: distance, date: now)
            localRange[peerID] = sample
            track(peerID, measurement: distance, sigma: RangeTrack.localSigma, at: now)
            sendRawRange(sample, to: peerID)
            fuse(peerID)
        } else if changed {
            resetBaselines()
            publishLocAR()
        }
    }

    private func handleRemove(sessionID: ObjectIdentifier) {
        guard let peerID = peerID(for: sessionID) else { return }
        restartRanging(peerID)
    }

    private func restartRanging(_ peerID: MCPeerID) {
        if let session = niSessions[peerID],
           let configuration = configurations[peerID] ?? session.configuration as? NINearbyPeerConfiguration {
            session.run(configuration)
            return
        }
        if mcSession?.connectedPeers.contains(peerID) == true {
            sendDiscoveryToken(to: peerID, force: true)
        }
    }

    private func handleSuspensionEnded(sessionID: ObjectIdentifier) {
        guard let peerID = peerID(for: sessionID), let session = niSessions[peerID] else { return }
        if let configuration = configurations[peerID] ?? session.configuration as? NINearbyPeerConfiguration {
            session.run(configuration)
        }
    }

    private func handleInvalidation(sessionID: ObjectIdentifier, error: Error) {
        guard !isTearingDown else { return }
        if let error = error as? NIError, error.code == .invalidARConfiguration {
            useCameraAssistance = false
        }
        guard let peerID = peerID(for: sessionID) else { return }
        niSessions[peerID] = nil
        configurations[peerID] = nil
        sentTokenTo.remove(peerID)
        if mcSession?.connectedPeers.contains(peerID) == true {
            sendDiscoveryToken(to: peerID, force: true)
        }
    }
}

extension PeerManager: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            self.handlePeerState(peerID, state)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.handleData(data, from: peerID)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}

    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: (any Error)?) {}

    nonisolated func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?, fromPeer peerID: MCPeerID, certificateHandler: @escaping (Bool) -> Void) {
        certificateHandler(true)
    }
}

extension PeerManager: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let remoteID = context.flatMap { String(data: $0, encoding: .utf8) }
        Task { @MainActor in
            self.remember(peerID, remoteID: remoteID)
        }
        if invitationSession?.connectedPeers.contains(peerID) == true {
            invitationHandler(false, nil)
            return
        }
        invitationHandler(true, invitationSession)
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            self.advertiser?.startAdvertisingPeer()
        }
    }
}

extension PeerManager: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let remoteID = info?["id"]
        Task { @MainActor in
            self.remember(peerID, remoteID: remoteID)
            self.invite(peerID)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            self.browser?.startBrowsingForPeers()
        }
    }
}

extension PeerManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let degrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor in
            self.applyHeading(degrees)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                manager.startUpdatingHeading()
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

extension PeerManager: CBCentralManagerDelegate, CBPeripheralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            guard central.state == .poweredOn else { return }
            central.scanForPeripherals(
                withServices: [self.bleService],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let rssi = RSSI.intValue
        let id = peripheral.identifier
        Task { @MainActor in
            let peerID = self.blePeripheralPeer[id] ?? self.peerID(forAdvertisedName: name)
            guard let peerID else { return }
            self.rememberBLEPeripheral(peripheral, peerID: peerID)
            if !self.bleConnected.contains(id) {
                self.applyBluetoothRSSI(rssi, to: peerID)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        Task { @MainActor in
            peripheral.delegate = self
            self.bleConnected.insert(id)
            peripheral.readRSSI()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.bleConnected.remove(peripheral.identifier)
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.bleConnected.remove(peripheral.identifier)
            central.connect(peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        let id = peripheral.identifier
        let rssi = RSSI.intValue
        Task { @MainActor in
            guard error == nil, let peerID = self.blePeripheralPeer[id] else { return }
            self.applyBluetoothRSSI(rssi, to: peerID)
        }
    }

    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            guard peripheral.state == .poweredOn else { return }
            peripheral.startAdvertising([
                CBAdvertisementDataServiceUUIDsKey: [self.bleService],
                CBAdvertisementDataLocalNameKey: String(self.discoveryID.prefix(8))
            ])
        }
    }
}

extension PeerManager: NISessionDelegate {
    nonisolated func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        let sessionID = ObjectIdentifier(session)
        let distance = nearbyObjects.first?.distance
        let direction = nearbyObjects.first?.direction
        let horizontalAngle = nearbyObjects.first?.horizontalAngle
        Task { @MainActor in
            self.handleUpdate(sessionID: sessionID, distance: distance, direction: direction, horizontalAngle: horizontalAngle)
        }
    }

    nonisolated func session(_ session: NISession, didUpdateAlgorithmConvergence convergence: NIAlgorithmConvergence, for object: NINearbyObject?) {
        let sessionID = ObjectIdentifier(session)
        let hint = Self.hint(for: convergence)
        Task { @MainActor in
            self.handleConvergence(sessionID: sessionID, hint: hint)
        }
    }

    nonisolated func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        let sessionID = ObjectIdentifier(session)
        Task { @MainActor in
            self.handleRemove(sessionID: sessionID)
        }
    }

    nonisolated func sessionWasSuspended(_ session: NISession) {}

    nonisolated func sessionSuspensionEnded(_ session: NISession) {
        let sessionID = ObjectIdentifier(session)
        Task { @MainActor in
            self.handleSuspensionEnded(sessionID: sessionID)
        }
    }

    nonisolated func session(_ session: NISession, didInvalidateWith error: Error) {
        let sessionID = ObjectIdentifier(session)
        Task { @MainActor in
            self.handleInvalidation(sessionID: sessionID, error: error)
        }
    }
}
