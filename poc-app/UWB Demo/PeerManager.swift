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
        /// Pairing stage reached with this peer, e.g. "mc tok ni run cam".
        var link: String?
        /// A peer that can range this one has shared an estimate of it recently.
        var isRelayed = false

        var id: MCPeerID { peerID }

        /// Distance to draw at `date` and whether it is backed by live UWB.
        /// Where a rendered distance actually came from. `relayed` is worth
        /// separating from the rest: it is not a degraded measurement of ours,
        /// it is another device's measurement reaching us second-hand, which is
        /// the normal and expected state for a peer beyond our own UWB range.
        enum DistanceSource {
            /// Local UWB, inside `liveWindow`.
            case live
            /// Local UWB that has aged past `liveWindow` but is not stale yet.
            case aging
            /// No usable UWB of our own; a peer that can range this device has
            /// shared its estimate recently.
            case relayed
            /// Filter dead reckoning or Bluetooth RSSI — no measurement behind it.
            case inferred
        }

        func displayDistance(at date: Date) -> (meters: Float, source: DistanceSource)? {
            if let range, !range.isStale(at: date) {
                return (range.value(at: date), range.isLive(at: date) ? .live : .aging)
            }
            if let estimatedDistance {
                return (estimatedDistance, isRelayed ? .relayed : .inferred)
            }
            if let bluetoothDistance {
                return (bluetoothDistance, .inferred)
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
    private var lastDeadReckonPosition: SIMD3<Float>?
    /// Peer's ARKit yaw from 0x56, half of the compass θ prior.
    private var lastRemoteYaw: [MCPeerID: Float] = [:]
    /// Last compass θ anchor per peer. See `updateThetaPrior`.
    private var lastThetaAnchor: [MCPeerID: Date] = [:]
    private let thetaAnchorInterval: TimeInterval = 2
    /// θ confidence below which the compass is allowed to intervene.
    private let thetaAnchorConfidence: Float = 0.3
    /// Most recent estimate per peer. `publishLocAR` computes these; everything
    /// else reuses them rather than walking the particle clouds again.
    private var lastEstimate: [MCPeerID: LocAREngine.Estimate] = [:]
    private var lastDiscoveryRefresh = Date.distantPast
    /// Invitations still inside their timeout, keyed by peer. See `invite`.
    private var pendingInvites: [MCPeerID: Date] = [:]
    /// When each peer last invited us. The non-initiator uses this to tell an
    /// initiator that is still trying from one that has given up.
    private var lastInviteReceived: [MCPeerID: Date] = [:]
    private let initiatorGrace: TimeInterval = 15
    private let launchedAt = CACurrentMediaTime()
    private var lastSessionState: [MCPeerID: MCSessionState] = [:]
    private var lastSendFailureLog: [MCPeerID: Date] = [:]
    private let inviteTimeout: TimeInterval = 12
    /// Last time an invitation actually produced a connection. Past
    /// `inviteStarvationLimit` with no progress, a pending invite stops earning
    /// protection from the discovery refresh.
    private var lastInviteProgress = Date()
    private let inviteStarvationLimit: TimeInterval = 30
    /// Slow enough not to disturb an invitation inside its 12 s timeout.
    private let discoveryRefreshInterval: TimeInterval = 20
    /// Peers whose ranging just resumed after a dropout; they get one calibrate
    /// that bypasses `calibrationInterval`. See `track` and `calibrateIfDue`.
    private var pendingRecalibration: Set<MCPeerID> = []
    /// Last time each peer's range, bearing, and shared estimate reached the
    /// filter. See `shouldIngest`. 10 Hz matches the paper's UWB rate (§5.2).
    private var lastRangeIngest: [MCPeerID: Date] = [:]
    private var lastBearingIngest: [MCPeerID: Date] = [:]
    private var lastThetaIngest: [MCPeerID: Date] = [:]
    /// Last ingest per (anchor, target) pair. See `shouldIngestRelative`.
    private var relativeIngestDates: [MCPeerID: [MCPeerID: Date]] = [:]
    private let relativeIngestInterval: TimeInterval = 1.0 / 3
    /// How recently a shared estimate must have arrived to mark a peer relayed.
    private let relayWindow: TimeInterval = 3
    private let ingestInterval: TimeInterval = 0.1
    /// Set by anything that changes filter state; drained by `publishTimer`.
    private var needsPublish = false
    private var publishTimer: Timer?
    /// Display refresh cap. Publishing is a view concern, so it runs on its own
    /// clock rather than once per inbound message: the seven call sites used to
    /// fan in at ~80 Hz with two devices connected, and each publish walks every
    /// particle and mutates the @Published `peers` map.
    private static let publishInterval: TimeInterval = 1.0 / 15
    let perf = PerfMonitor()
    private var pendingVIOReset = false
    private var useCameraAssistance = NISession.deviceCapabilities.supportsCameraAssistance
    /// The single peer whose NISession holds the camera-assistance claim.
    private var cameraAssistedPeer: MCPeerID?
    private var cameraAssistanceGrantedAt = Date.distantPast
    private var tokenRetries: [MCPeerID: Task<Void, Never>] = [:]
    private var tokenAttempts: [MCPeerID: Int] = [:]
    /// Last NISession invalidation reason per peer, surfaced in `linkStatus`.
    private var niErrors: [MCPeerID: String] = [:]
    /// Hold once converged: long enough for the filter to carry the bearing on
    /// VIO until this peer's next turn.
    private let cameraAssistanceMinHold: TimeInterval = 25
    /// Hold when convergence never arrives, so one bad peer can't starve the rest.
    private let cameraAssistanceMaxHold: TimeInterval = 45

    private struct RangeSample {
        let range: Float
        let date: Date
    }

    private var localRange: [MCPeerID: RangeSample] = [:]
    private var remoteRange: [MCPeerID: RangeSample] = [:]
    private var tracks: [MCPeerID: RangeTrack] = [:]
    private var bearingConfidence: [MCPeerID: Float] = [:]
    private var lastNIDirection: [MCPeerID: (direction: simd_float3, date: Date)] = [:]
    /// Latest body azimuth to each peer (0 forward, positive right), radians.
    private var lastBearing: [MCPeerID: (angle: Float, date: Date)] = [:]
    /// Newest peer-to-peer range sample already fed to the filter, keyed "a|b".
    private var peerRangeDates: [String: Date] = [:]
    /// Newest §8 estimate per anchor and target; unreliable packets may reorder.
    private var relativeEstimateDates: [MCPeerID: [MCPeerID: Date]] = [:]
    private var lastCalibration: [MCPeerID: Date] = [:]
    private let freshWindow: TimeInterval = 0.75
    /// Bearings arrive sparsely at range, and a usable one was being discarded
    /// for being 600 ms old. The filter's uniform-plus-NLOS model tolerates the
    /// extra staleness better than having no bearing at all.
    private let directionWindow: TimeInterval = 1.5
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
        perf.start()
        // Not `distantPast`: that made the first ping tick bounce the browser
        // ~250 ms in, during initial discovery, which dropped and re-vended the
        // browse entry an invitation had just been sent to.
        lastDiscoveryRefresh = Date()
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
            self?.broadcastRelativeEstimates()
            self?.calibrateAllDue()
            self?.refreshDiscoveryIfDue()
            self?.rotateCameraAssistanceIfDue()
            self?.setNeedsPublish()
        }
        publishTimer = Timer.scheduledTimer(withTimeInterval: Self.publishInterval, repeats: true) { [weak self] _ in
            self?.publishIfNeeded()
        }
    }

    /// Request a publish on the next tick. Cheap and idempotent, so callers can
    /// fire it per message without thinking about rate.
    private func setNeedsPublish() {
        needsPublish = true
    }

    private func publishIfNeeded() {
        guard needsPublish else { return }
        needsPublish = false
        publishLocAR()
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
        // Poses already arrive thinned to ~20 Hz by VIOTracker.
        deadReckon(from: pose, at: now)
        if now.timeIntervalSince(lastVIOSend) >= 0.1 {
            lastVIOSend = now
            sendVIO(pose)
        }
        setNeedsPublish()
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
            if send(data, to: peers, mode: .unreliable, label: "vio") {
                pendingVIOReset = false
            }
        } catch {}
    }

    private func handleRemoteVIO(_ data: Data, from peerID: MCPeerID) {
        let x = data.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: Float.self) }
        let y = data.subdata(in: 5..<9).withUnsafeBytes { $0.load(as: Float.self) }
        let z = data.subdata(in: 9..<13).withUnsafeBytes { $0.load(as: Float.self) }
        let yaw = data.subdata(in: 13..<17).withUnsafeBytes { $0.load(as: Float.self) }
        let isReset = data[data.startIndex + 17] & 1 == 1
        locar.ingestRemoteVIO(peerID: peerID, position: SIMD3<Float>(x, y, z), yaw: yaw, isReset: isReset)
        lastRemoteYaw[peerID] = yaw
        updateThetaPrior(for: peerID)
        if peers[peerID] == nil {
            peers[peerID] = Peer(peerID: peerID)
        }
        setNeedsPublish()
    }

    /// Project local VIO translation onto each resolved LocAR bearing. This is
    /// physical range change from display motion only; particle reweighting,
    /// resampling, and loss recovery never leak into the displayed RangeTrack.
    private func deadReckon(from pose: VIOTracker.Pose, at now: Date) {
        defer { lastDeadReckonPosition = pose.position }
        guard !pose.didResume, let previous = lastDeadReckonPosition else { return }
        let displacement = pose.position - previous
        let distance = simd_length(displacement)
        guard distance.isFinite, distance <= 2.5 else { return }

        let forward = SIMD2<Float>(sin(pose.yaw), cos(pose.yaw))
        let right = SIMD2<Float>(-cos(pose.yaw), sin(pose.yaw))
        for id in tracks.keys {
            // Reuse the estimate `publishLocAR` already computed rather than
            // walking 64 x 120 particles per peer a second time. At most one
            // publish interval stale, which is well inside a dead-reckoned gap.
            guard let estimate = lastEstimate[id],
                  estimate.bearingConfidence > deadReckonConfidence else { continue }
            let worldBearing = forward * estimate.direction.y + right * estimate.direction.x
            let rangeDelta = -simd_dot(SIMD2<Float>(displacement.x, displacement.z), worldBearing)
            guard rangeDelta.isFinite else { continue }
            tracks[id]?.nudge(rangeDelta, at: now)
        }
    }

    // MARK: Peer identity

    private var discoveryUUID: UUID? { UUID(uuidString: discoveryID) }

    /// 0x49 | discoveryID (UTF-8). Sent on connect so both sides know the
    /// other's stable ID regardless of who browsed and who advertised.
    private func sendHello(to peerID: MCPeerID) {
        var data = Data([0x49])
        data.append(contentsOf: Array(discoveryID.utf8))
        send(data, to: [peerID], mode: .reliable, label: "hello")
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
    /// 0x58 | psi (Float32, our world-frame azimuth to this peer) | age ms.
    ///
    /// Addressed to one peer and carrying only the bearing for that link, so
    /// unlike 0x57 there is no UUID and no list — an exchange only ever
    /// concerns the pair that made it.
    private func sendBearing(_ angle: Float, at date: Date, to peerID: MCPeerID) {
        guard let psi = locar.worldAzimuth(bodyAngle: angle) else { return }
        var data = Data([0x58])
        var value = psi
        var age = UInt16(clamping: Int(Date().timeIntervalSince(date) * 1000))
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &age) { data.append(contentsOf: $0) }
        send(data, to: [peerID], mode: .unreliable, label: "bearing")
    }

    /// Solves θ from the pair of bearings and feeds it to the filter.
    ///
    /// Rotation between the two measurements is harmless — both ψ are already
    /// world-referenced — but translation is not: a device moving d across the
    /// line shifts its bearing by about d/r. So the tolerated lag scales with
    /// range, which conveniently loosens exactly where θ error matters most.
    private func handleBearingExchange(_ data: Data, from peerID: MCPeerID) {
        let theirPsi = data.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: Float.self) }
        let ageMs = data.subdata(in: 5..<7).withUnsafeBytes { $0.load(as: UInt16.self) }
        guard theirPsi.isFinite else { return }
        let now = Date()
        guard let mine = lastBearing[peerID],
              let ourPsi = locar.worldAzimuth(bodyAngle: mine.angle) else { return }

        let range = lastEstimate[peerID]?.distance ?? tracks[peerID]?.range ?? 3
        let maxLag = min(max(0.08 * Double(range), 0.15), 0.7)
        let theirAge = Double(ageMs) / 1000
        let ourAge = now.timeIntervalSince(mine.date)
        guard theirAge < maxLag, ourAge < maxLag else { return }
        guard shouldIngest(peerID, .theta, at: now) else { return }

        let theta = LocAREngine.wrapAngle(ourPsi - theirPsi + .pi)
        locar.ingestThetaObservation(peerID: peerID, theta: theta)
        mcLog("theta-obs", peerID, String(format: "%.0f deg", theta * 180 / .pi))
        setNeedsPublish()
    }

    private func sendRawRange(_ sample: RangeSample, to peerID: MCPeerID) {
        let ageMs = UInt16(clamping: Int(Date().timeIntervalSince(sample.date) * 1000))
        var data = Data([0x52])
        var value = sample.range
        var age = ageMs
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &age) { data.append(contentsOf: $0) }
        send(data, to: [peerID], mode: .unreliable, label: "rawRange")
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
        send(data, to: session.connectedPeers, mode: .unreliable, label: "rangeList")
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
                track(sender, measurement: range, from: .remote, at: date)
                if let fused = fusedRange(for: sender, at: now),
                   shouldIngest(sender, .range, at: now) {
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
            setNeedsPublish()
        }
    }

    /// 0x57 | count (UInt8) | entries of: peer UUID (16 bytes) | target − self
    /// (three Float32s in our ARKit frame) | confidence (Float32) | age ms (UInt16).
    /// Only peers with a fresh direct UWB range are included: §8 estimates remain
    /// single-hop evidence and can never circle back through another estimator.
    private func broadcastRelativeEstimates() {
        guard let session = mcSession, session.connectedPeers.count > 1 else { return }
        let now = Date()
        var entries = Data()
        var count: UInt8 = 0
        for (peerID, sample) in localRange where now.timeIntervalSince(sample.date) < freshWindow {
            guard let remoteID = knownRemoteIDs[peerID], let uuid = UUID(uuidString: remoteID),
                  let estimate = locar.relativeVector(for: peerID), estimate.confidence > 0.6,
                  estimate.vector.x.isFinite, estimate.vector.y.isFinite, estimate.vector.z.isFinite,
                  estimate.confidence.isFinite else { continue }
            withUnsafeBytes(of: uuid.uuid) { entries.append(contentsOf: $0) }
            var dx = estimate.vector.x
            var dy = estimate.vector.y
            var dz = estimate.vector.z
            var confidence = estimate.confidence
            var age = UInt16(clamping: Int(now.timeIntervalSince(sample.date) * 1000))
            withUnsafeBytes(of: &dx) { entries.append(contentsOf: $0) }
            withUnsafeBytes(of: &dy) { entries.append(contentsOf: $0) }
            withUnsafeBytes(of: &dz) { entries.append(contentsOf: $0) }
            withUnsafeBytes(of: &confidence) { entries.append(contentsOf: $0) }
            withUnsafeBytes(of: &age) { entries.append(contentsOf: $0) }
            count += 1
            if count == 255 { break }
        }
        guard count > 0 else { return }
        var data = Data([0x57, count])
        data.append(entries)
        send(data, to: session.connectedPeers, mode: .unreliable, label: "estimates")
    }

    private func handleRelativeEstimates(_ data: Data, from sender: MCPeerID) {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return }
        let count = Int(bytes[1])
        let entrySize = 34
        guard bytes.count == 2 + count * entrySize else { return }
        let now = Date()
        let mine = discoveryUUID
        var dates = relativeEstimateDates[sender] ?? [:]
        var changed = false
        for index in 0..<count {
            let base = 2 + index * entrySize
            let uuid = bytes[base..<(base + 16)].withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
            let dx = bytes[(base + 16)..<(base + 20)].withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
            let dy = bytes[(base + 20)..<(base + 24)].withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
            let dz = bytes[(base + 24)..<(base + 28)].withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
            let confidence = bytes[(base + 28)..<(base + 32)].withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
            let ageMs = bytes[(base + 32)..<(base + 34)].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
            guard dx.isFinite, dy.isFinite, dz.isFinite, confidence.isFinite else { continue }
            guard mine == nil || uuid != mine else { continue }
            guard let target = peer(forRemoteUUID: uuid), target != sender else { continue }
            let date = now.addingTimeInterval(-Double(ageMs) / 1000)
            guard now.timeIntervalSince(date) < freshWindow else { continue }
            if let last = dates[target], last >= date { continue }
            dates[target] = date
            guard shouldIngestRelative(anchor: sender, target: target, at: now) else { continue }
            locar.ingestRelativeEstimate(
                target: target,
                anchor: sender,
                vector: SIMD3<Float>(dx, dy, dz),
                confidence: confidence
            )
            changed = true
        }
        relativeEstimateDates[sender] = dates
        if changed {
            setNeedsPublish()
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
        track(peerID, measurement: range, from: .remote, at: date)
        fuse(peerID)
    }

    /// UWB is the display truth; ARKit only fills the gaps between samples.
    private let trackMode: RangeTrack.Mode = .uwbFirst

    private func track(_ peerID: MCPeerID, measurement: Float, from source: RangeTrack.Source, at date: Date) {
        if var track = tracks[peerID] {
            // Stale -> fresh means UWB just came back after a dropout, during
            // which the filter had only dead reckoning. Snap the cloud now
            // rather than up to `calibrationInterval` later.
            if track.isStale(at: date) {
                pendingRecalibration.insert(peerID)
            }
            track.update(measurement, from: source, at: date)
            tracks[peerID] = track
        } else if source == .local || trackMode == .smoothed {
            tracks[peerID] = RangeTrack(range: measurement, at: date, mode: trackMode)
        }
    }

    private func fuse(_ peerID: MCPeerID) {
        let now = Date()
        if let range = fusedRange(for: peerID, at: now) {
            if shouldIngest(peerID, .range, at: now) {
                locar.ingestUWB(peerID: peerID, range: range)
            }
            calibrateIfDue(peerID, range: range, at: now)
        }
        setNeedsPublish()
    }

    private enum IngestChannel {
        case range
        case bearing
        case theta
    }

    /// Keyed by the (anchor, target) pair, not by target alone: N senders each
    /// reporting M peers fans in as N x M, so a per-target gate still lets the
    /// rate scale with the number of devices.
    ///
    /// 3 Hz rather than the 10 Hz the direct channels use. A shared estimate is
    /// a slow correction built from someone else's filter, not a primary
    /// observation, and it does not carry 10 Hz of new information.
    private func shouldIngestRelative(anchor: MCPeerID, target: MCPeerID, at now: Date) -> Bool {
        if let last = relativeIngestDates[anchor]?[target],
           now.timeIntervalSince(last) < relativeIngestInterval {
            return false
        }
        relativeIngestDates[anchor, default: [:]][target] = now
        return true
    }

    /// Gate on feeding the filter, per peer and per channel.
    ///
    /// The same physical range reaches `ingestUWB` from three paths — the local
    /// NI update, the peer's copy of that range, and the peer's range list — and
    /// each one multiplies the particle weights again. Three ingests of one
    /// measurement give a 64x inlier/outlier ratio instead of 4x, which is the
    /// false convergence and particle impoverishment the paper's uniform error
    /// model exists to avoid (§4.1.3).
    ///
    /// This decimates rather than drops: callers read the freshest stored sample
    /// through `fusedRange`, so whatever arrives next after the gate reopens is
    /// the most recent measurement, not a stale one.
    private func shouldIngest(_ peerID: MCPeerID, _ channel: IngestChannel, at now: Date) -> Bool {
        let last: Date?
        switch channel {
        case .range: last = lastRangeIngest[peerID]
        case .bearing: last = lastBearingIngest[peerID]
        case .theta: last = lastThetaIngest[peerID]
        }
        if let last, now.timeIntervalSince(last) < ingestInterval {
            return false
        }
        switch channel {
        case .range: lastRangeIngest[peerID] = now
        case .bearing: lastBearingIngest[peerID] = now
        case .theta: lastThetaIngest[peerID] = now
        }
        return true
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
        let forced = pendingRecalibration.contains(peerID)
        if !forced, let last = lastCalibration[peerID], now.timeIntervalSince(last) < calibrationInterval {
            return
        }
        // Cleared on the attempt, not on success: `calibrate` also declines when
        // the estimate already agrees with the range, which needs no retry.
        pendingRecalibration.remove(peerID)
        pendingInvites[peerID] = nil
        lastInviteReceived[peerID] = nil
        lastRemoteYaw[peerID] = nil
        lastThetaAnchor[peerID] = nil
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

    /// Recomputes every peer's estimate and hands the view one update. The map
    /// is built locally and assigned once: writing `peers[id]` inside the loop
    /// published a separate change per peer and invalidated the view tree that
    /// many times per publish.
    private func publishLocAR() {
        let now = Date()
        perfCounters.recordPublish()
        var updated = peers
        for id in Array(updated.keys) {
            guard var peer = updated[id] else { continue }
            let estimate = locar.estimate(for: id)
            lastEstimate[id] = estimate
            bearingConfidence[id] = estimate?.bearingConfidence ?? 0

            peer.range = tracks[id]
            peer.estimatedDistance = estimate?.distance
            peer.link = linkStatus(for: id)
            peer.isRelayed = hasRecentRelay(for: id, at: now)

            if let estimate, estimate.bearingConfidence > 0.6 {
                peer.locarDirection = estimate.direction
            } else if let angle = freshBearing(for: id, at: now) {
                peer.locarDirection = simd_float3(sin(angle), cos(angle), 0)
            } else {
                peer.locarDirection = nil
            }
            peer.locarHeading = (estimate?.bearingConfidence ?? 0) > 0.6 ? estimate?.heading : nil
            updated[id] = peer
        }
        peers = updated
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
        send(payload, to: session.connectedPeers, mode: .unreliable, label: "ping")
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
        send(data, to: peers, mode: .unreliable, label: "heading")
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

    /// Multipeer vends a fresh `MCPeerID` when a device is rediscovered, and it
    /// does not compare equal to the previous one. Every per-peer dictionary
    /// here is keyed by that object — `peers`, `niSessions`, `tracks`, and the
    /// filter's target clouds — so one phone can end up with two complete sets
    /// of state. In the logs that showed as `recenter_ms_per_s` doubling from
    /// ~40 to ~85 immediately after a lost/found pair, then stepping back down
    /// as teardown ran.
    ///
    /// The discovery ID is stable for the life of an install, so identity
    /// follows that rather than the object.
    private func isDuplicateOfConnected(_ peerID: MCPeerID, remoteID: String) -> Bool {
        guard let connected = mcSession?.connectedPeers else { return false }
        return connected.contains {
            $0 != peerID && knownRemoteIDs[$0]?.caseInsensitiveCompare(remoteID) == .orderedSame
        }
    }

    /// Drops stale `MCPeerID`s that name the same device as `peerID`. Only ones
    /// with no live session: a connected object is the working link, and the
    /// newly discovered duplicate is the one that should be ignored.
    private func reconcileIdentity(_ peerID: MCPeerID, remoteID: String) {
        let stale = knownRemoteIDs
            .filter { $0.key != peerID && $0.value.caseInsensitiveCompare(remoteID) == .orderedSame }
            .map(\.key)
        for old in stale where mcSession?.connectedPeers.contains(old) != true {
            mcLog("identity-merge", peerID, "dropping stale \(old.displayName)")
            knownRemoteIDs[old] = nil
            reconnectTasks[old]?.cancel()
            reconnectTasks[old] = nil
            tearDown(old)
        }
    }

    /// The lower discovery ID owns invitations for a pair. Both sides advertise
    /// and accept, but only one sends, so two invites can never cross.
    ///
    /// This used to be bypassed by a `force` flag on reconnect. Both devices see
    /// the same disconnect at the same instant and ran the same schedule, so
    /// both reached the forced path together, each invited the other, and each
    /// accepted — two overlapping attempts for one pair, one of which dies as
    /// "error in connectedHandler [Unable to connect]". The roles are now
    /// separated in time instead: see `scheduleReconnect`.
    private func isInitiator(for peerID: MCPeerID) -> Bool {
        guard let remoteID = knownRemoteIDs[peerID] else { return true }
        return discoveryID < remoteID
    }

    private func invite(_ peerID: MCPeerID) {
        guard let mcSession, !mcSession.connectedPeers.contains(peerID) else { return }
        let context = discoveryID.data(using: .utf8)
        // Recorded so a discovery refresh cannot bounce the browser out from
        // under this invitation before the peer's acceptance comes back.
        pendingInvites[peerID] = Date()
        mcLog("invite-sent", peerID, isInitiator(for: peerID) ? "initiator" : "fallback")
        browser?.invitePeer(peerID, to: mcSession, withContext: context, timeout: 12)
    }

    /// The peer left the browse. Stop chasing it: a reconnect task that keeps
    /// inviting a peer that is gone — app killed, rebuilt, or walked out of
    /// range — fails every time, and each failure drives another `.notConnected`
    /// which schedules yet another round.
    ///
    /// A reinstall makes this worse: `storedPeerID` mints a fresh `MCPeerID`,
    /// so the stale one held here can never connect again. Dropping the remote
    /// ID too means the pair re-tiebreaks from scratch when it reappears.
    private func handleLostPeer(_ peerID: MCPeerID) {
        mcLog("lost", peerID)
        // MC can drop a browse entry for a peer whose session is still healthy.
        guard mcSession?.connectedPeers.contains(peerID) != true else { return }
        reconnectTasks[peerID]?.cancel()
        reconnectTasks[peerID] = nil
        pendingInvites[peerID] = nil
        // `knownRemoteIDs` is deliberately kept. It is the tiebreak identity and
        // it is stable for the life of that install, so clearing it only opens a
        // window where `isInitiator` falls back to true on both devices at once
        // and they invite each other simultaneously. A browse entry dropping is
        // not evidence the peer's identity changed.
    }

    /// Recovers a browser that has silently stopped finding peers — the one case
    /// `didNotStartBrowsingForPeers` does not cover. Only while nothing is
    /// connected, and rarely, so it cannot disturb an invitation in flight the
    /// way the per-attempt refresh did.
    /// Re-arms advertising and browsing periodically, whether or not we are
    /// already connected to someone.
    ///
    /// This used to skip whenever any peer was connected, which meant a device
    /// stopped refreshing the moment it joined its first session — forever. Two
    /// devices never noticed, because both are idle while they find each other.
    /// A third arriving later did: the established pair had both stopped
    /// refreshing, so whichever of them needed to initiate toward the newcomer
    /// was browsing with a stale view and never saw it. The observed shape was
    /// a star — the middle device by join order reachable from both ends, the
    /// outer two unable to see each other.
    ///
    /// Rate-limited rather than gated. The original harm was refreshing
    /// immediately before an invite, which tore down the browse the invite was
    /// about to go through; a slow periodic refresh is decoupled from invite
    /// timing and safe while connected.
    private func refreshDiscoveryIfDue() {
        let now = Date()
        guard now.timeIntervalSince(lastDiscoveryRefresh) >= discoveryRefreshInterval else { return }
        lastDiscoveryRefresh = now
        mcLog("refresh", nil, hasPendingInvite() ? "advertiser only" : "advertiser+browser")
        refreshDiscovery()
    }

    /// Re-arming the advertiser is harmless and is what actually restores
    /// discoverability. Restarting the browser is the destructive half: it
    /// discards the browser's record of invitations it has sent, so a peer's
    /// acceptance arrives orphaned and MultipeerConnectivity logs "Received an
    /// invitation response ... but we never sent it an invitation. Aborting!"
    /// It also fires `lostPeer` for everyone currently visible.
    ///
    /// So the browser is only bounced when no invitation is outstanding.
    private func refreshDiscovery() {
        advertiser?.startAdvertisingPeer()
        guard !hasPendingInvite() else { return }
        browser?.stopBrowsingForPeers()
        browser?.startBrowsingForPeers()
    }

    /// True while any invitation is still inside its 12 s timeout.
    private func hasPendingInvite() -> Bool {
        let now = Date()
        pendingInvites = pendingInvites.filter { now.timeIntervalSince($0.value) < inviteTimeout }
        guard !pendingInvites.isEmpty else { return false }
        // Deferring to an in-flight invitation is only worth it while invitations
        // are plausibly working. If they have been failing for a long stretch,
        // the likeliest cause is that we are inviting a browse entry MC has
        // since discarded — and the only way out of that is the refresh this
        // guard is blocking. Protecting the invite forever deadlocks recovery.
        return now.timeIntervalSince(lastInviteProgress) < inviteStarvationLimit
    }

    /// Retry schedule, separated by role so the two sides never invite at once.
    /// The initiator retries promptly; the other side stays quiet until well
    /// past the initiator's last attempt, and only then takes over — which is
    /// what keeps recovery working when the initiator is the device that died.
    private func scheduleReconnect(_ peerID: MCPeerID) {
        reconnectTasks[peerID]?.cancel()
        // The non-initiator keeps checking rather than taking one shot at 12 s.
        // Each check defers while the initiator is still trying, so the takeover
        // has to be able to come back later — see `attemptReconnect`.
        let delays: [Duration] = isInitiator(for: peerID)
            ? [.seconds(1), .seconds(2.5)]
            : [.seconds(12), .seconds(15), .seconds(15)]
        reconnectTasks[peerID] = Task { [weak self] in
            for delay in delays {
                try? await Task.sleep(for: delay)
                guard let manager = self, !Task.isCancelled else { return }
                let connected = await MainActor.run {
                    manager.attemptReconnect(peerID)
                }
                if connected { return }
            }
        }
    }

    /// Returns true once the peer is connected, so the retry loop can stop.
    private func attemptReconnect(_ peerID: MCPeerID) -> Bool {
        if mcSession?.connectedPeers.contains(peerID) == true {
            return true
        }
        // The takeover is conditional, not timed. The initiator re-arms its own
        // retry on every failure, so it keeps inviting indefinitely; a fallback
        // on a fixed clock lands in the middle of that and both sides invite at
        // once. Duplicate sessions follow, and MC resolves them by tearing one
        // down — which in the logs killed an already-connected link. So the
        // non-initiator only steps in once the initiator has actually gone quiet.
        if !isInitiator(for: peerID),
           let last = lastInviteReceived[peerID],
           Date().timeIntervalSince(last) < initiatorGrace {
            mcLog("fallback-deferred", peerID, "initiator still trying")
            return false
        }
        // No `refreshDiscovery()` here. It restarted the browser and invited
        // through it in the same breath, before the peer had been rediscovered,
        // and it could invalidate an invitation still inside its 12 s timeout.
        // Periodic re-arming lives in `refreshDiscoveryIfDue`.
        invite(peerID)
        return false
    }

    /// Multipeer timeline, prefixed `MCLOG` so it filters out of the console the
    /// way `LOCARPERF` does. Every failure in this layer has so far been
    /// diagnosed indirectly, from Apple's own log messages plus inference; these
    /// lines make the sequence readable instead.
    ///
    /// Columns: elapsed, event, peer, detail.
    private func mcLog(_ event: String, _ peerID: MCPeerID? = nil, _ detail: String = "") {
        let elapsed = CACurrentMediaTime() - launchedAt
        print(String(format: "MCLOG,%.2f,%@,%@,%@", elapsed, event, peerID?.displayName ?? "-", detail))
    }

    private static func name(_ state: MCSessionState?) -> String {
        switch state {
        case .none: return "none"
        case .some(.notConnected): return "notConnected"
        case .some(.connecting): return "connecting"
        case .some(.connected): return "connected"
        @unknown default: return "unknown"
        }
    }

    /// Logged failures are throttled per peer, since a dead link fails at the
    /// full send rate and would bury everything else.
    private func logSendFailure(_ label: String, _ peerID: MCPeerID?, _ error: Error) {
        let key = peerID ?? localPeerID
        let now = Date()
        if let last = lastSendFailureLog[key], now.timeIntervalSince(last) < 1 { return }
        lastSendFailureLog[key] = now
        mcLog("send-fail", peerID, "\(label) \(error.localizedDescription)")
    }

    /// Single send path so every failure is visible. `try?` at ten call sites
    /// meant a wedged link looked identical to a healthy idle one.
    @discardableResult
    private func send(_ data: Data, to peers: [MCPeerID], mode: MCSessionSendDataMode, label: String) -> Bool {
        guard let mcSession, !peers.isEmpty else { return false }
        do {
            try mcSession.send(data, toPeers: peers, with: mode)
            return true
        } catch {
            logSendFailure(label, peers.first, error)
            return false
        }
    }

    private func handlePeerState(_ peerID: MCPeerID, _ state: MCSessionState) {
        // The previous state is what distinguishes a handshake that never
        // completed (connecting -> notConnected) from an established session
        // that died (connected -> notConnected). MC's delegate only reports the
        // new one, so the transition has to be reconstructed here.
        mcLog("state", peerID, "\(Self.name(lastSessionState[peerID])) -> \(Self.name(state))")
        lastSessionState[peerID] = state
        switch state {
        case .connected:
            reconnectTasks[peerID]?.cancel()
            reconnectTasks[peerID] = nil
            pendingInvites[peerID] = nil
            lastInviteProgress = Date()
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
            // A failed invitation is finished, not in flight. Leaving it in
            // `pendingInvites` to age out over 12 s meant the 1-2.5 s retry
            // cadence kept one permanently in the window, which held the
            // browser refresh down to advertiser-only forever and left us
            // re-inviting a stale browse entry with no way to get a fresh one.
            pendingInvites[peerID] = nil
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

    private func scheduleTokenRetry(_ peerID: MCPeerID) {
        guard tokenRetries[peerID] == nil else { return }
        let attempt = (tokenAttempts[peerID] ?? 0) + 1
        tokenAttempts[peerID] = attempt
        // Capped: if NI never vends a token the device has a real problem, and
        // spinning forever would just hide it.
        guard attempt <= 10 else { return }
        tokenRetries[peerID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                self.tokenRetries[peerID] = nil
                guard self.mcSession?.connectedPeers.contains(peerID) == true else { return }
                self.sendDiscoveryToken(to: peerID, force: true)
            }
        }
    }

    /// Coarse θ from the two compasses, as a seeding prior only.
    ///
    /// Each device has a fixed offset between its ARKit yaw and magnetic north:
    /// `heading - yaw`. θ maps that peer's frame into ours, so it is the
    /// difference of the two offsets. Both terms come from data already on the
    /// wire — their heading over 0x48, their ARKit yaw over 0x56.
    ///
    /// Indoor magnetometers are far too biased for this to be an observation.
    /// As a prior it is still worth a lot: it replaces a uniform draw over the
    /// whole circle with roughly a quadrant, and θ is otherwise only observable
    /// through translated peer VIO — so a cold cloud can stay uniform for as
    /// long as nobody happens to walk.
    private func updateThetaPrior(for peerID: MCPeerID) {
        guard let theirHeading = peers[peerID]?.heading,
              let theirYaw = lastRemoteYaw[peerID] else { return }
        let ourOffset = localHeading - locar.localYaw
        let theirOffset = theirHeading - theirYaw
        let compassTheta = theirOffset - ourOffset
        locar.setThetaPrior(compassTheta, for: peerID)

        // Fed as an observation only once θ has degenerated. The compass is
        // biased, not noisy, so applying it every cycle would drag a converged
        // θ onto the local magnetic error and hold it there. Gating on low
        // confidence makes it a floor under drift rather than a ceiling on
        // accuracy, and rate-limiting keeps a burst of headings from stacking
        // the same biased evidence several times over.
        let now = Date()
        guard let confidence = lastEstimate[peerID]?.thetaConfidence,
              confidence < thetaAnchorConfidence else { return }
        if let last = lastThetaAnchor[peerID], now.timeIntervalSince(last) < thetaAnchorInterval {
            return
        }
        lastThetaAnchor[peerID] = now
        locar.ingestThetaAnchor(peerID: peerID, theta: compassTheta)
    }

    /// Whether some peer has recently told us where this one is. Read across
    /// every anchor, since any device that can range the target may be the one
    /// relaying it. The window is generous relative to the 2 Hz broadcast so a
    /// single dropped `.unreliable` packet doesn't flicker the marker.
    private func hasRecentRelay(for peerID: MCPeerID, at now: Date) -> Bool {
        for (_, targets) in relativeEstimateDates {
            if let date = targets[peerID], now.timeIntervalSince(date) < relayWindow {
                return true
            }
        }
        return false
    }

    /// Compact pairing state per peer, so a failure can be read off the screen
    /// instead of inferred. Each stage has to succeed for ranging to start.
    private func linkStatus(for peerID: MCPeerID) -> String {
        var parts: [String] = []
        parts.append(mcSession?.connectedPeers.contains(peerID) == true ? "mc" : "mc✗")
        parts.append(sentTokenTo.contains(peerID) ? "tok" : "tok✗")
        parts.append(niSessions[peerID] != nil ? "ni" : "ni✗")
        parts.append(configurations[peerID] != nil ? "run" : "run✗")
        if cameraAssistedPeer == peerID {
            parts.append("cam")
        }
        // θ and how tightly the cloud agrees on it. This is the state variable
        // behind bearing error that grows with range, and nothing else exposes
        // it: a low confidence here predicts a large miss at distance even when
        // the range itself is perfect.
        if let estimate = lastEstimate[peerID] {
            parts.append(String(
                format: "θ%.0f/%.2f",
                estimate.theta * 180 / .pi,
                estimate.thetaConfidence
            ))
        }
        if let error = niErrors[peerID] {
            parts.append(error)
        }
        return parts.joined(separator: " ")
    }

    private func sendDiscoveryToken(to peerID: MCPeerID, force: Bool = false) {
        if !force, sentTokenTo.contains(peerID) {
            return
        }
        let session = niSession(for: peerID)
        guard let token = session.discoveryToken else {
            // A token is not always available the instant a session is created,
            // and nothing else retriggers this path. Returning silently
            // deadlocks the pair: each side sits waiting for a token the other
            // will never send, which looks exactly like "no NI at all".
            mcLog("token-nil", peerID)
            scheduleTokenRetry(peerID)
            return
        }
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else {
            mcLog("token-archive-fail", peerID)
            return
        }
        // `sentTokenTo` is only set on a send that actually succeeded. It used
        // to be set on the retry regardless of outcome, so `tok` in the on-screen
        // link status could read as sent while the token never left — exactly
        // the case worth diagnosing.
        if send(data, to: [peerID], mode: .reliable, label: "token") {
            sentTokenTo.insert(peerID)
            mcLog("token-sent", peerID)
            return
        }
        mcLog("token-send-failed", peerID, "retrying")
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                guard self.mcSession?.connectedPeers.contains(peerID) == true else { return }
                if self.send(data, to: [peerID], mode: .reliable, label: "token-retry") {
                    self.sentTokenTo.insert(peerID)
                    self.mcLog("token-sent", peerID, "retry")
                } else {
                    self.mcLog("token-send-failed", peerID, "gave up")
                }
            }
        }
    }

    private func handleData(_ data: Data, from peerID: MCPeerID) {
        if data.count == 9, data.first == 0x50 {
            var reply = Data([0x51])
            reply.append(data.subdata(in: 1..<9))
            send(reply, to: [peerID], mode: .unreliable, label: "pong")
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
        if data.count == 7, data.first == 0x58 {
            handleBearingExchange(data, from: peerID)
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
        if data.count >= 2, data.first == 0x57 {
            handleRelativeEstimates(data, from: peerID)
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
            updateThetaPrior(for: peerID)
            return
        }
        guard let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data) else { return }
        mcLog("token-recv", peerID)
        let session = niSession(for: peerID)
        let configuration = NINearbyPeerConfiguration(peerToken: token)
        configuration.isCameraAssistanceEnabled = usesCameraAssistance(peerID)
        configurations[peerID] = configuration
        session.run(configuration)
        sendDiscoveryToken(to: peerID)
    }

    /// Camera assistance runs on one NISession at a time. Every session used to
    /// claim the shared ARSession, so with two or more peers they contended and
    /// all of them lost bearing — the opposite of the intent, since camera
    /// assistance is what carries `horizontalAngle` past raw NI direction's
    /// ~5-8 m ceiling.
    ///
    /// The claim is held until the peer goes away rather than rotated between
    /// peers: reassigning costs a full re-convergence (sweep, movement, light),
    /// which is worse than leaving one peer unassisted.
    private func claimCameraAssistance(for peerID: MCPeerID) -> Bool {
        guard useCameraAssistance else { return false }
        if cameraAssistedPeer == nil {
            cameraAssistedPeer = peerID
            cameraAssistanceGrantedAt = Date()
        }
        return cameraAssistedPeer == peerID
    }

    /// Time-multiplex the single claim across peers. Convergence is what makes
    /// camera assistance worth having, so the holder keeps it until it has
    /// actually converged — but not forever, since a peer that never converges
    /// would otherwise starve everyone else.
    ///
    /// The filter is what makes this work: it coasts each peer's bearing on VIO
    /// between observations, so a peer only needs the camera periodically rather
    /// than continuously.
    private func rotateCameraAssistanceIfDue() {
        guard useCameraAssistance, let current = cameraAssistedPeer else { return }
        let candidates = niSessions.keys.sorted { $0.displayName < $1.displayName }
        guard candidates.count > 1, let index = candidates.firstIndex(of: current) else { return }

        let now = Date()
        let held = now.timeIntervalSince(cameraAssistanceGrantedAt)
        // A nil hint means NIAlgorithmConvergence reported `.converged`.
        let converged = peers[current]?.hint == nil
        let due = held >= (converged ? cameraAssistanceMinHold : cameraAssistanceMaxHold)
        guard due else { return }

        let next = candidates[(index + 1) % candidates.count]
        // Rotating re-runs both configurations, and re-running a configuration
        // restarts that peer's ranging. On a clock that manufactures a dropout
        // every cycle — the tilde flicker was partly self-inflicted. Rotate into
        // a gap instead: only hand the camera to a peer that has no live range
        // and therefore actually needs the help, and never interrupt one that is
        // already ranging cleanly.
        guard tracks[next]?.isLive(at: now) != true else { return }

        moveCameraAssistance(to: next, from: current)
    }

    /// Re-running a configuration briefly interrupts that peer's ranging, which
    /// is why the hold times are tens of seconds rather than a few.
    private func moveCameraAssistance(to next: MCPeerID, from current: MCPeerID) {
        guard next != current else { return }
        // Release before claiming: two sessions holding the ARSession at once is
        // the contention this whole mechanism exists to avoid.
        if let session = niSessions[current], let configuration = configurations[current] {
            configuration.isCameraAssistanceEnabled = false
            session.run(configuration)
        }
        cameraAssistedPeer = nil
        guard let session = niSessions[next], let configuration = configurations[next] else { return }
        cameraAssistedPeer = next
        cameraAssistanceGrantedAt = Date()
        session.setARSession(vio.session)
        configuration.isCameraAssistanceEnabled = true
        session.run(configuration)
    }

    private func usesCameraAssistance(_ peerID: MCPeerID) -> Bool {
        useCameraAssistance && cameraAssistedPeer == peerID
    }

    /// Hand the claim to a peer that is still around, so losing the assisted
    /// peer doesn't leave everyone on raw NI direction.
    private func releaseCameraAssistance(from peerID: MCPeerID) {
        guard cameraAssistedPeer == peerID else { return }
        cameraAssistedPeer = nil
        guard useCameraAssistance,
              let next = niSessions.keys.first,
              let session = niSessions[next],
              let configuration = configurations[next] else { return }
        cameraAssistedPeer = next
        cameraAssistanceGrantedAt = Date()
        session.setARSession(vio.session)
        configuration.isCameraAssistanceEnabled = true
        session.run(configuration)
    }

    private func niSession(for peerID: MCPeerID) -> NISession {
        if let session = niSessions[peerID] {
            return session
        }
        let session = NISession()
        session.delegate = self
        if claimCameraAssistance(for: peerID) {
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
        releaseCameraAssistance(from: peerID)
        sentTokenTo.remove(peerID)
        lastUWBUpdate[peerID] = nil
        localRange[peerID] = nil
        remoteRange[peerID] = nil
        tracks[peerID] = nil
        bearingConfidence[peerID] = nil
        lastNIDirection[peerID] = nil
        lastBearing[peerID] = nil
        peerRangeDates = peerRangeDates.filter { !$0.key.split(separator: "|").contains(Substring(peerID.displayName)) }
        relativeEstimateDates[peerID] = nil
        for anchor in Array(relativeEstimateDates.keys) {
            relativeEstimateDates[anchor]?[peerID] = nil
            if relativeEstimateDates[anchor]?.isEmpty == true {
                relativeEstimateDates[anchor] = nil
            }
        }
        lastCalibration[peerID] = nil
        pingSentAt[peerID] = nil
        forgetBluetooth(for: peerID)
        lastEstimate[peerID] = nil
        lastRangeIngest[peerID] = nil
        lastBearingIngest[peerID] = nil
        lastThetaIngest[peerID] = nil
        relativeIngestDates[peerID] = nil
        for anchor in Array(relativeIngestDates.keys) {
            relativeIngestDates[anchor]?[peerID] = nil
            if relativeIngestDates[anchor]?.isEmpty == true {
                relativeIngestDates[anchor] = nil
            }
        }
        pendingRecalibration.remove(peerID)
        tokenRetries[peerID]?.cancel()
        tokenRetries[peerID] = nil
        tokenAttempts[peerID] = nil
        niErrors[peerID] = nil
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
            sendBearing(angle, at: now, to: peerID)
            // Gated separately from range: bearing is a different information
            // channel and shouldn't be starved by range traffic, or vice versa.
            if shouldIngest(peerID, .bearing, at: now) {
                locar.ingestBearing(peerID: peerID, bodyAngle: angle)
            }
            changed = true
        }
        if let distance, distance.isFinite, distance > 0 {
            let sample = RangeSample(range: distance, date: now)
            localRange[peerID] = sample
            track(peerID, measurement: distance, from: .local, at: now)
            sendRawRange(sample, to: peerID)
            fuse(peerID)
        } else if changed {
            setNeedsPublish()
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
        niErrors[peerID] = Self.shortError(error)
        mcLog("ni-invalid", peerID, Self.shortError(error))
        niSessions[peerID] = nil
        configurations[peerID] = nil
        sentTokenTo.remove(peerID)
        // Without this the claim stays pinned to a peer whose session is gone:
        // no one else can claim it, and `rotateCameraAssistanceIfDue` can no
        // longer find the holder among `niSessions`, so rotation stops for good.
        releaseCameraAssistance(from: peerID)
        if mcSession?.connectedPeers.contains(peerID) == true {
            sendDiscoveryToken(to: peerID, force: true)
        }
    }

    private static func shortError(_ error: Error) -> String {
        guard let error = error as? NIError else { return "err" }
        switch error.code {
        case .invalidARConfiguration: return "badAR"
        case .resourceUsageTimeout: return "timeout"
        case .activeSessionsLimitExceeded: return "tooMany"
        case .userDidNotAllow: return "denied"
        case .invalidConfiguration: return "badCfg"
        default: return "err\(error.code.rawValue)"
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
        // Answered from the main actor so the decision can consult
        // `knownRemoteIDs`. The handler is escaping and the inviter allows 12 s,
        // so replying an actor hop later is well inside the budget.
        Task { @MainActor in
            self.answerInvitation(from: peerID, remoteID: remoteID, respond: invitationHandler)
        }
    }

    @MainActor
    private func answerInvitation(
        from peerID: MCPeerID,
        remoteID: String?,
        respond: @escaping (Bool, MCSession?) -> Void
    ) {
        remember(peerID, remoteID: remoteID)
        lastInviteReceived[peerID] = Date()

        // Duplicate is judged by discovery ID, not object identity. Comparing
        // `connectedPeers.contains(peerID)` misses a device we are already
        // connected to under an earlier `MCPeerID`, so the second invitation was
        // accepted, a duplicate connection formed, and its collapse took the
        // working session down with it — the `connected -> notConnected` at
        // t=151 in the logs, right after an advertiser-side "Unable to connect".
        let duplicate = remoteID.map { isDuplicateOfConnected(peerID, remoteID: $0) }
            ?? (mcSession?.connectedPeers.contains(peerID) == true)
        let crossed = pendingInvites[peerID] != nil
        mcLog(
            duplicate ? "invite-recv-reject" : "invite-recv-accept",
            peerID,
            [crossed ? "CROSSED with our own invite" : "", duplicate ? "duplicate identity" : ""]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        )
        guard !duplicate else {
            respond(false, nil)
            return
        }
        respond(true, invitationSession)
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
            self.mcLog("found", peerID, remoteID == nil ? "no discoveryInfo" : "")
            if let remoteID {
                // Already connected to this device under an earlier MCPeerID:
                // the live session is the real one, so drop this object rather
                // than building a second set of state around it.
                if self.isDuplicateOfConnected(peerID, remoteID: remoteID) {
                    self.mcLog("found-duplicate", peerID, "already connected under another peerID")
                    self.knownRemoteIDs[peerID] = nil
                    return
                }
                self.reconcileIdentity(peerID, remoteID: remoteID)
            }
            if self.isInitiator(for: peerID) {
                self.invite(peerID)
            } else {
                // Stay quiet and let the initiator lead, but arm the delayed
                // takeover in case it never manages to reach us.
                self.scheduleReconnect(peerID)
            }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.handleLostPeer(peerID)
        }
    }

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
