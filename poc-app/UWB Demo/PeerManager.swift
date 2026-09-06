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
    /// ARKit tracking state. Camera assistance only converges at `normal`, and
    /// `isReliable` deliberately accepts `limited` for the filter's sake, so
    /// this is the only signal that says whether `horizontalAngle` is even
    /// possible on this device.
    @Published var trackingState = "init"
    /// Bumped on every ARKit re-origin (tracking resumed after a loss). The
    /// map keeps peer positions in the ARKit horizontal frame so they hold
    /// still while the phone turns; a re-origin changes what that frame means,
    /// so the map rotates its state to preserve body-relative positions.
    @Published private(set) var frameEpoch = 0
    /// Our azimuth in the ARKit horizontal frame, radians. Increases
    /// counter-clockwise viewed from above (ARKit: turning right moves forward
    /// from -z toward +x, which is a falling `atan2(x, z)`).
    var localYaw: Float { locar.localYaw }

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
    /// θ agreement required before a VIO-propagated bearing is shown at all.
    /// Below this the raw Nearby Interaction bearing, or nothing, is honest.
    private let thetaTrustThreshold: Float = 0.5
    /// How recently theta must have been measured before a VIO-propagated
    /// bearing is trusted on screen.
    ///
    /// Cloud agreement cannot tell a converged theta from a confidently wrong
    /// one: when theta is wrong every particle moves the same wrong way, so the
    /// cloud stays tight and `thetaConfidence` stays near 1. On the harness it
    /// read 1.00 in 100% of samples while theta was 49 deg out, which is why
    /// neither existing gate ever fired. Time since a real measurement is the
    /// one signal that does separate them, because an unchecked theta has been
    /// drifting the whole time.
    private let thetaMeasurementWindow: TimeInterval = 90
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
    /// Rate gate only. Whether theta has been *measured* is `thetaAge`'s
    /// question, and the solver answers it.
    private var lastThetaIngest: [MCPeerID: Date] = [:]
    private var lastBearingLog: [MCPeerID: Date] = [:]
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
    /// Sliding-window least squares on each peer's frame transform. The store
    /// is fed on the main actor; `solveFramesIfDue` snapshots it and solves on
    /// a utility task. See `FrameSolver`.
    private var frameStore = FrameSolver.Store()
    private var frameIDs: [MCPeerID: Int] = [:]
    private var nextFrameID = 0
    private var frameSolutions: [MCPeerID: FrameSolver.Solution] = [:]
    private var frameSolveInFlight = false
    private var lastFrameSolve = Date.distantPast
    private var frameSolveCount = 0
    private var lastFrameLog: [MCPeerID: Date] = [:]
    /// When the solver last delivered a θ good enough to hand the cloud.
    /// Counts as a θ measurement for `thetaAge`.
    private var lastFrameTrust: [MCPeerID: Date] = [:]
    private let frameSolveInterval: TimeInterval = 1
    /// The full θ grid every Nth solve; the rest warm-start from the previous
    /// answer. A wrong basin can therefore hold for at most this many seconds.
    private let frameFullSearchEvery = 5
    /// σ_θ under which the solver's θ replaces the cloud's, radians. Well
    /// under the compass prior's 0.6, so a compass-only θ never qualifies.
    private let frameThetaSigmaLimit: Float = 0.2
    /// Bearing σ under which the solver's bearing is the one drawn, radians.
    private let frameBearingSigmaLimit: Float = 0.25

    /// Clock offset per peer, their `CACurrentMediaTime` minus ours, from an
    /// NTP-style exchange (0x43/0x44). The solver evaluates every residual at
    /// the instant it was measured, and a peer's VIO pose carries its ARKit
    /// capture time on their clock; this is what makes that time ours. The
    /// sample with the smallest round trip wins, since asymmetric transport
    /// delay is bounded by the round trip and the shortest one bounds it best.
    private var clockSamples: [MCPeerID: [(offset: Double, rtt: Double)]] = [:]
    private var clockOffset: [MCPeerID: Double] = [:]
    private var pingTicks = 0
    private static let clockSampleCount = 16
    /// A converted peer time further than this from its arrival is a bad
    /// offset, not a slow network; fall back to arrival time.
    private let clockSanityWindow: TimeInterval = 1.0

    /// ARKit collaborative sessions as a mode. Nearby Interaction's camera
    /// assistance requires the shared ARSession to have collaboration off, so
    /// the two cannot run together; only one ARSession can hold the camera.
    ///
    /// `.huddle` starts collaborating so that peers who begin together get
    /// their maps merged, and stays that way while every peer keeps producing
    /// participant fixes, which are better than anything camera assistance
    /// can offer. Once `huddleMergeTimeout` has passed, any peer that has gone
    /// `fixSilence` without a fix flips the device to camera assistance for
    /// everyone; a newly connected peer starts a fresh huddle.
    private enum CollaborationPolicy {
        case off
        case always
        case huddle
    }
    private let collaborationPolicy: CollaborationPolicy = .huddle
    private var collaborationActive = false
    private var huddleStartedAt: Date?
    /// Short, because two phones facing each other never see the same scene
    /// and so never merge; camera assistance must come back quickly then.
    private let huddleMergeTimeout: TimeInterval = 20
    private let fixSilence: TimeInterval = 10
    /// Peer ARSession identifiers from 0x4A, which is how a participant anchor
    /// names its device.
    private var participantSessions: [UUID: MCPeerID] = [:]
    private var lastVisualFix: [MCPeerID: Date] = [:]
    private var lastVisualFixLog: [MCPeerID: Date] = [:]
    private var useCameraAssistance = NISession.deviceCapabilities.supportsCameraAssistance
    /// The single peer whose NISession holds the camera-assistance claim.
    private var cameraAssistedPeer: MCPeerID?
    private var cameraAssistanceGrantedAt = Date.distantPast
    private var tokenRetries: [MCPeerID: Task<Void, Never>] = [:]
    private var tokenAttempts: [MCPeerID: Int] = [:]
    /// The last discovery token each peer sent, kept so a session of ours that
    /// is rebuilt can run against it at once, and its archived bytes so a
    /// *changed* token — the peer rebuilt its session — is recognised.
    private var peerTokens: [MCPeerID: NIDiscoveryToken] = [:]
    private var peerTokenData: [MCPeerID: Data] = [:]
    /// Session rebuilds pending after an invalidation. See `scheduleSessionRebuild`.
    private var sessionRebuilds: [MCPeerID: Task<Void, Never>] = [:]
    /// Teardowns deferred across a Multipeer blip. See `scheduleTeardown`.
    private var pendingTeardowns: [MCPeerID: Task<Void, Never>] = [:]
    private let teardownGrace: TimeInterval = 15
    /// Ranging watchdog state. See `watchRanging`.
    private var rangingRecoveryStep: [MCPeerID: Int] = [:]
    private var lastRangingRecovery: [MCPeerID: Date] = [:]
    private let rangingSilence: TimeInterval = 15
    /// Multipeer liveness. See `watchLinks`.
    private var lastPongAt: [MCPeerID: Date] = [:]
    private var connectedSince: [MCPeerID: Date] = [:]
    private let pongSilence: TimeInterval = 12
    /// Remote IDs that have had a huddle. A reconnect is not a new peer.
    private var huddledIDs: Set<String> = []
    /// Last NISession invalidation reason per peer, surfaced in `linkStatus`.
    private var niErrors: [MCPeerID: String] = [:]
    /// Hold once converged.
    ///
    /// The floor is not how long theta takes to learn — peer bearings average
    /// as sigma/sqrt(N), so ten of them at ~7 deg each reach ~2 deg in a couple
    /// of seconds. It is how long camera assistance takes to *re*-converge after
    /// `moveCameraAssistance` re-runs the configuration, because until it does
    /// `horizontalAngle` is nil and nothing is harvested. Rotate faster than
    /// that and every slot is spent reconverging, which is worse than never
    /// rotating: measured on the filter, a 5 s period against a 5 s
    /// reconvergence produced zero exchanges and 22 deg of theta error, against
    /// 2.8 deg at 12 s.
    private let cameraAssistanceMinHold: TimeInterval = 8
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
    /// Latest body azimuth to each peer (0 forward, positive right), radians,
    /// together with the world-frame azimuth psi derived from it at the instant
    /// of measurement.
    ///
    /// psi has to be captured here rather than recomputed later. It is
    /// `localYaw - bodyAngle`, and `localYaw` moves with the phone, so deriving
    /// it at send time reads the *current* yaw against a bearing up to
    /// `maxLag` old. Any rotation inside that window then enters the peer's
    /// theta as pure error: at a mild 100 deg/s over a 0.3 s lag that is 30 deg
    /// injected into a measurement the filter accepts as good to 7.
    private var lastBearing: [MCPeerID: (angle: Float, psi: Float?, date: Date)] = [:]
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

    /// The archived `MCPeerID` is reused across launches so reconnecting peers
    /// see a stable identity — but only while it still matches the callsign the
    /// user has chosen. Renaming re-mints it, which is why an edit needs a
    /// relaunch to reach the team.
    private static func storedPeerID() -> MCPeerID {
        let name = DisplayName.resolved()
        if let data = UserDefaults.standard.data(forKey: "UWBDemo.mcPeerID"),
           let peer = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data),
           peer.displayName == name {
            return peer
        }
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
            self?.watchRanging()
            self?.watchLinks()
            self?.sendClockSyncIfDue()
            self?.updateCollaborationPolicy()
            self?.solveFramesIfDue()
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
        vio.onCollaborationData = { [weak self] data in
            self?.sendCollaboration(data)
        }
        vio.onParticipant = { [weak self] sessionID, transform, time in
            self?.handleParticipant(sessionID: sessionID, transform: transform, at: time)
        }
        collaborationActive = collaborationPolicy != .off
        vio.start(collaborating: collaborationActive)
    }

    private func handleLocalVIO(_ pose: VIOTracker.Pose) {
        if trackingState != pose.trackingLabel {
            mcLog("arkit", nil, "\(trackingState) -> \(pose.trackingLabel)")
            trackingState = pose.trackingLabel
        }
        guard pose.isReliable else { return }
        if pose.didResume {
            pendingVIOReset = true
            frameEpoch += 1
        }
        let now = Date()
        locar.setLocal(pose)
        if pose.didResume {
            // Our frame changed; every transform the solver knew is void.
            frameStore.reset()
            frameSolutions.removeAll()
        }
        // ARKit capture time, on the same clock as CACurrentMediaTime.
        frameStore.recordLocalPose(pose.position, yaw: pose.yaw, at: pose.timestamp)
        // Poses already arrive thinned to ~20 Hz by VIOTracker.
        deadReckon(from: pose, at: now)
        if now.timeIntervalSince(lastVIOSend) >= 0.1 {
            lastVIOSend = now
            sendVIO(pose)
        }
        setNeedsPublish()
    }

    /// 0x56 | x y z yaw (Float32 each) | flags (bit0 = ARKit re-origin) |
    /// capture time (Float64, sender's `CACurrentMediaTime` clock).
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
        var timestamp = pose.timestamp
        withUnsafeBytes(of: &timestamp) { data.append(contentsOf: $0) }
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
        let frameID = frameID(for: peerID)
        if isReset {
            frameStore.clearPeer(frameID)
            frameSolutions[peerID] = nil
        }
        // Capture time on our clock when the offset is known and sane, else
        // arrival. At walking speed 100 ms of transport is 15 cm of pose error,
        // comparable to the range noise itself.
        let arrival = CACurrentMediaTime()
        var time = arrival
        if data.count >= 26, let offset = clockOffset[peerID] {
            let captured = data.subdata(in: 18..<26).withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
            let converted = captured - offset
            if converted.isFinite, abs(converted - arrival) < clockSanityWindow {
                time = converted
            }
        }
        frameStore.recordPeerPose(frameID, SIMD3<Float>(x, y, z), yaw: yaw, at: time)
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
    /// unlike 0x57 there is no UUID and no list — a bearing only ever
    /// concerns the pair that made it. The receiver applies it to its cloud
    /// for us directly (`handleBearingExchange`), with no bearing of its own.
    private func sendBearing(_ psi: Float?, at date: Date, to peerID: MCPeerID) {
        guard let psi else {
            bearingLog("send-skip", peerID, "no world azimuth (ARKit not tracking)")
            return
        }
        bearingLog("bearing-sent", peerID, String(format: "%.0f deg", psi * 180 / .pi))
        var data = Data([0x58])
        var value = psi
        var age = UInt16(clamping: Int(Date().timeIntervalSince(date) * 1000))
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &age) { data.append(contentsOf: $0) }
        send(data, to: [peerID], mode: .unreliable, label: "bearing")
    }

    /// Feeds the peer's bearing to us into the filter as an observation on
    /// every particle. See `LocAREngine.ingestPeerBearing`: no bearing of our
    /// own is needed, so one camera-assisted side per link is enough.
    ///
    /// Rotation since the measurement is harmless — ψ is world-referenced on
    /// their side — but translation is not: a device moving d across the line
    /// shifts its bearing by about d/r. So the tolerated age scales with range,
    /// which conveniently loosens exactly where θ error matters most.
    private func handleBearingExchange(_ data: Data, from peerID: MCPeerID) {
        let theirPsi = data.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: Float.self) }
        let ageMs = data.subdata(in: 5..<7).withUnsafeBytes { $0.load(as: UInt16.self) }
        guard theirPsi.isFinite else { return }
        let now = Date()

        let range = lastEstimate[peerID]?.distance ?? tracks[peerID]?.range ?? 3
        let maxLag = min(max(0.08 * Double(range), 0.15), 0.7)
        let theirAge = Double(ageMs) / 1000
        guard theirAge < maxLag else {
            bearingLog("theta-skip", peerID, String(format: "stale: theirs %.2fs limit %.2fs", theirAge, maxLag))
            return
        }
        frameStore.recordPeerBearing(frameID(for: peerID), azimuth: theirPsi, at: CACurrentMediaTime() - theirAge)
        // Checked before the gate: `shouldIngest` records the ingest, and a
        // bearing the engine had no cloud to apply to must not count as a
        // theta measurement for `thetaAge`.
        guard locar.hasTargets(peerID) else {
            bearingLog("theta-skip", peerID, "no cloud yet (no range)")
            return
        }
        guard shouldIngest(peerID, .theta, at: now) else { return }

        locar.ingestPeerBearing(peerID: peerID, azimuth: theirPsi)
        bearingLog("theta-obs", peerID, String(format: "their psi %.0f deg", theirPsi * 180 / .pi))
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
                frameStore.recordRange(frameID(for: sender), range, at: CACurrentMediaTime() - Double(ageMs) / 1000)
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
            frameStore.recordPairRange(frameID(for: sender), frameID(for: other), range, at: CACurrentMediaTime() - Double(ageMs) / 1000)
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
            guard !hasBetterDirectFix(for: target, at: now) else { continue }
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
        frameStore.recordRange(frameID(for: peerID), range, at: CACurrentMediaTime() - Double(ageMs) / 1000)
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

    /// Body azimuth to this peer for display, corrected for rotation since the
    /// measurement.
    ///
    /// The stored sample is up to `directionWindow` old and the phone keeps
    /// turning underneath it, so replaying the raw body angle swings the arrow
    /// with every rotation. Re-deriving it from the world azimuth captured at
    /// measurement time keeps the arrow pointing at the same place in the room.
    private func freshBearing(for peerID: MCPeerID, at now: Date) -> Float? {
        guard let sample = lastBearing[peerID], now.timeIntervalSince(sample.date) < directionWindow else {
            return nil
        }
        guard let psi = sample.psi else { return sample.angle }
        return LocAREngine.wrapAngle(locar.localYaw - psi)
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
        guard peer.hint != hint else {
            // Re-log a state that persists. Logging only transitions made a
            // convergence stuck on one reason for 40 s look identical to a
            // delegate that never fired again.
            if let hint {
                bearingLog("convergence-stuck", peerID, hint)
            }
            return
        }
        // A nil hint means converged — but so did a delegate that never fired,
        // which is a completely different situation. Logging the transition
        // separates them.
        mcLog("convergence", peerID, hint ?? "converged")
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

    // MARK: Clock sync

    /// 0x43 | t0 (Float64, our CACurrentMediaTime). Once a second, on the
    /// ping tick.
    private func sendClockSyncIfDue() {
        pingTicks += 1
        guard pingTicks % 4 == 0, let session = mcSession, !session.connectedPeers.isEmpty else { return }
        var data = Data([0x43])
        var t0 = CACurrentMediaTime()
        withUnsafeBytes(of: &t0) { data.append(contentsOf: $0) }
        send(data, to: session.connectedPeers, mode: .unreliable, label: "clock")
    }

    /// 0x44 | t0 | t1 (their receive) | t2 (their send), all Float64. Standard
    /// NTP: offset = ((t1 − t0) + (t2 − t3)) / 2, rtt = (t3 − t0) − (t2 − t1).
    private func handleClockReply(_ data: Data, from peerID: MCPeerID) {
        let t3 = CACurrentMediaTime()
        let t0 = data.subdata(in: 1..<9).withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
        let t1 = data.subdata(in: 9..<17).withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
        let t2 = data.subdata(in: 17..<25).withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
        guard t0.isFinite, t1.isFinite, t2.isFinite, t3 >= t0, t2 >= t1 else { return }
        let rtt = (t3 - t0) - (t2 - t1)
        guard rtt >= 0, rtt < 2 else { return }
        let offset = ((t1 - t0) + (t2 - t3)) / 2
        var samples = clockSamples[peerID] ?? []
        samples.append((offset, rtt))
        if samples.count > Self.clockSampleCount {
            samples.removeFirst(samples.count - Self.clockSampleCount)
        }
        clockSamples[peerID] = samples
        guard let best = samples.min(by: { $0.rtt < $1.rtt }) else { return }
        let previous = clockOffset[peerID]
        clockOffset[peerID] = best.offset
        if previous == nil || abs((previous ?? 0) - best.offset) > 0.05 {
            mcLog("clock", peerID, String(format: "offset %.3fs rtt %.0fms", best.offset, best.rtt * 1000))
        }
    }

    // MARK: Collaboration

    /// 0x4A | our ARSession identifier (16 bytes). A participant anchor on the
    /// other side carries this as its session identifier.
    private func sendSessionIdentifier(to peerID: MCPeerID) {
        var data = Data([0x4A])
        withUnsafeBytes(of: vio.sessionIdentifier.uuid) { data.append(contentsOf: $0) }
        send(data, to: [peerID], mode: .reliable, label: "ar-session")
    }

    /// 0x41 | archived `ARSession.CollaborationData`. Critical data (map
    /// merges) goes reliably; the per-frame optional stream can drop.
    private func sendCollaboration(_ data: ARSession.CollaborationData) {
        guard collaborationActive, let peers = mcSession?.connectedPeers, !peers.isEmpty else { return }
        guard let archived = try? NSKeyedArchiver.archivedData(withRootObject: data, requiringSecureCoding: true) else { return }
        var payload = Data([0x41])
        payload.append(archived)
        let mode: MCSessionSendDataMode = data.priority == .critical ? .reliable : .unreliable
        send(payload, to: peers, mode: mode, label: "collab")
    }

    private func handleCollaboration(_ data: Data, from peerID: MCPeerID) {
        guard collaborationActive else { return }
        guard let collaboration = try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: ARSession.CollaborationData.self, from: Data(data)
        ) else {
            mcLog("collab-unarchive-fail", peerID)
            return
        }
        vio.update(with: collaboration)
    }

    /// A participant anchor: the peer's camera in our ARKit world. Its
    /// position and yaw, against the peer's own reported pose at the same
    /// instant, fix the whole transform, which is why the solver treats it as
    /// the strongest evidence it has.
    private func handleParticipant(sessionID: UUID, transform: simd_float4x4, at time: TimeInterval) {
        guard let peerID = participantSessions[sessionID] else { return }
        guard let yaw = VIOTracker.yaw(from: transform) else { return }
        let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        frameStore.recordVisualFix(frameID(for: peerID), position: position, yaw: yaw, at: time)
        let now = Date()
        let first = lastVisualFix[peerID] == nil
        lastVisualFix[peerID] = now
        if first || now.timeIntervalSince(lastVisualFixLog[peerID] ?? .distantPast) >= 5 {
            lastVisualFixLog[peerID] = now
            mcLog("vfix", peerID, String(format: "(%.1f, %.1f, %.1f) yaw %.0f", position.x, position.y, position.z, yaw * 180 / .pi))
        }
    }

    /// A newly connected peer starts a huddle: maps can only merge while both
    /// devices collaborate, and a peer that joins later has never merged.
    ///
    /// Once per device identity, not per connection: a Multipeer blip that
    /// reconnects the same peer is not a new arrival, and re-entering
    /// collaboration on every one would keep switching camera assistance off.
    private func beginHuddle(for peerID: MCPeerID) {
        guard collaborationPolicy == .huddle else { return }
        let identity = knownRemoteIDs[peerID] ?? peerID.displayName
        guard !huddledIDs.contains(identity) else { return }
        huddledIDs.insert(identity)
        huddleStartedAt = Date()
        enterCollaboration(reason: "peer \(peerID.displayName) connected")
    }

    private func updateCollaborationPolicy() {
        guard collaborationPolicy == .huddle, collaborationActive else { return }
        let now = Date()
        guard let started = huddleStartedAt, now.timeIntervalSince(started) > huddleMergeTimeout else { return }
        // Past the merge window, a peer with no recent fix is one collaboration
        // is not helping, while camera assistance would.
        let silent = niSessions.keys.filter { peer in
            now.timeIntervalSince(lastVisualFix[peer] ?? .distantPast) > fixSilence
        }
        guard let peer = silent.first else { return }
        leaveCollaboration(reason: "no participant fix from \(peer.displayName) in \(Int(fixSilence)) s")
    }

    private func enterCollaboration(reason: String) {
        guard !collaborationActive else { return }
        // Camera assistance and collaboration cannot share the ARSession.
        // Release the claim first so nothing holds `setARSession` while the
        // configuration changes underneath it.
        if let holder = cameraAssistedPeer {
            if let session = niSessions[holder], let configuration = configurations[holder] {
                configuration.isCameraAssistanceEnabled = false
                session.run(configuration)
            }
            cameraAssistedPeer = nil
        }
        collaborationActive = true
        vio.setCollaborating(true)
        mcLog("collab-on", nil, reason)
        for peer in mcSession?.connectedPeers ?? [] {
            sendSessionIdentifier(to: peer)
        }
    }

    private func leaveCollaboration(reason: String) {
        guard collaborationActive else { return }
        collaborationActive = false
        vio.setCollaborating(false)
        mcLog("collab-off", nil, reason)
        guard useCameraAssistance, cameraAssistedPeer == nil else { return }
        // Hand the camera to the peer whose θ has gone longest unmeasured.
        let now = Date()
        guard let next = niSessions.keys.min(by: { thetaAge(of: $0, at: now) > thetaAge(of: $1, at: now) }),
              let session = niSessions[next], let configuration = configurations[next] else { return }
        cameraAssistedPeer = next
        cameraAssistanceGrantedAt = now
        session.setARSession(vio.session)
        configuration.isCameraAssistanceEnabled = true
        session.run(configuration)
        mcLog("cam-grant", next, "after collaboration")
    }

    // MARK: Frame solver

    private func frameID(for peerID: MCPeerID) -> Int {
        if let id = frameIDs[peerID] {
            return id
        }
        let id = nextFrameID
        nextFrameID += 1
        frameIDs[peerID] = id
        return id
    }

    /// Snapshot the store and solve off the main actor, at most one solve in
    /// flight. The store is plain value types, so the snapshot is one copy and
    /// the main actor keeps feeding the live store meanwhile.
    private func solveFramesIfDue() {
        let now = Date()
        guard !frameSolveInFlight, !frameIDs.isEmpty,
              now.timeIntervalSince(lastFrameSolve) >= frameSolveInterval else { return }
        let time = CACurrentMediaTime()
        frameStore.prune(before: time - FrameSolver.Store.window)
        let snapshot = frameStore
        var warm: [Int: FrameSolver.Solution] = [:]
        for (peerID, solution) in frameSolutions {
            if let id = frameIDs[peerID] {
                warm[id] = solution
            }
        }
        let fullSearch = frameSolveCount % frameFullSearchEvery == 0
        frameSolveCount += 1
        lastFrameSolve = now
        frameSolveInFlight = true
        Task.detached(priority: .utility) { [weak self] in
            let solutions = FrameSolver.solve(snapshot, warm: warm, now: time, fullSearch: fullSearch)
            await MainActor.run {
                self?.applyFrameSolutions(solutions)
            }
        }
    }

    private func applyFrameSolutions(_ solutions: [Int: FrameSolver.Solution]) {
        frameSolveInFlight = false
        let now = Date()
        for (peerID, id) in frameIDs {
            guard let solution = solutions[id] else { continue }
            frameSolutions[peerID] = solution
            let trusted = !solution.ambiguous && solution.sigmaTheta < frameThetaSigmaLimit
            if trusted {
                // The cloud's θ becomes the solver's belief. Floored so a very
                // sharp solve does not collapse the cloud to a single θ.
                locar.setThetaBelief(peerID: peerID, theta: solution.theta, sigma: max(solution.sigmaTheta, 0.02))
                lastFrameTrust[peerID] = now
            }
            if now.timeIntervalSince(lastFrameLog[peerID] ?? .distantPast) >= 3 {
                lastFrameLog[peerID] = now
                mcLog("frame", peerID, String(
                    format: "θ%.0f±%.0f%@ n=%d r=%d b=%d v=%d cost %.2f%@",
                    solution.theta * 180 / .pi,
                    min(solution.sigmaTheta * 180 / .pi, 999),
                    solution.ambiguous ? "?" : "",
                    solution.residualCount,
                    solution.rangeCount,
                    solution.bearingCount,
                    solution.fixCount,
                    solution.cost,
                    trusted ? " trusted" : ""
                ))
            }
        }
        setNeedsPublish()
    }

    /// The solver's bearing to this peer now: the peer's latest VIO pose
    /// through the solved transform, against our latest pose. Nil unless the
    /// transform is unambiguous, the poses and the solve are recent, and the
    /// bearing's own σ is inside `frameBearingSigmaLimit`. `heading` is the
    /// peer's facing in our body frame, from its ARKit yaw and θ rather than
    /// the compasses.
    private func frameBearing(for peerID: MCPeerID, at now: Date) -> (direction: simd_float3, heading: Float?)? {
        guard let solution = frameSolutions[peerID], !solution.ambiguous,
              let id = frameIDs[peerID],
              let peerPose = frameStore.peers[id]?.poses.last,
              let ourPose = frameStore.localPoses.last else { return nil }
        let time = CACurrentMediaTime()
        guard time - peerPose.time < 2, time - ourPose.time < 2, time - solution.solvedAt < 5,
              let bearing = solution.azimuth(peer: peerPose.position, from: ourPose.position),
              bearing.sigma < frameBearingSigmaLimit else { return nil }
        let body = LocAREngine.wrapAngle(locar.localYaw - bearing.azimuth)
        let direction = simd_float3(sin(body), cos(body), 0)
        let heading = lastRemoteYaw[peerID].map { LocAREngine.wrapAngle(locar.localYaw - ($0 + solution.theta)) }
        return (direction, heading)
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

            // Both gates, not just cloud agreement. A bearing carried by peer
            // VIO is only as good as θ, and when θ has converged on a wrong
            // value every particle moves the same wrong way — the cloud stays
            // tight and confidence stays high while the arrow is badly wrong.
            // That is exactly the lateral-motion-at-range case: the tangential
            // component changes range by d²/2r, which at 6 m is centimetres, so
            // ranging cannot contradict θ and the error is invisible until the
            // devices come close enough for NI direction to fix it.
            // A device that cannot do camera assistance can still receive a
            // peer's bearing, but paired with another such device it never
            // will, so requiring one there could blank its map permanently.
            // On that hardware cloud agreement is genuinely all there is.
            let thetaMeasured = !useCameraAssistance
                || thetaAge(of: id, at: now) < thetaMeasurementWindow
            // The solver's bearing first. It carries its own σ from the window
            // geometry, so unlike the cloud it cannot be confidently wrong
            // about θ; when that σ is not small enough it simply declines.
            let frame = frameBearing(for: id, at: now)
            if let frame {
                peer.locarDirection = frame.direction
            } else if let estimate, estimate.bearingConfidence > 0.6,
               estimate.thetaConfidence > thetaTrustThreshold, thetaMeasured {
                peer.locarDirection = estimate.direction
            } else if let angle = freshBearing(for: id, at: now) {
                peer.locarDirection = simd_float3(sin(angle), cos(angle), 0)
            } else {
                peer.locarDirection = nil
            }
            peer.locarHeading = frame?.heading
                ?? ((estimate?.bearingConfidence ?? 0) > 0.6 ? estimate?.heading : nil)
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

    /// Bearing-exchange events, throttled per peer. These fire at Nearby
    /// Interaction rates when they fire at all, so an unthrottled log would
    /// bury the rest of the timeline.
    private func bearingLog(_ event: String, _ peerID: MCPeerID, _ detail: String) {
        let now = Date()
        if let last = lastBearingLog[peerID], now.timeIntervalSince(last) < 2 { return }
        lastBearingLog[peerID] = now
        mcLog(event, peerID, detail)
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
            // Back inside the grace: the NI session was never torn down and
            // carries on as it was.
            if pendingTeardowns[peerID] != nil {
                mcLog("teardown-cancelled", peerID, "reconnected inside grace")
                pendingTeardowns[peerID]?.cancel()
                pendingTeardowns[peerID] = nil
            }
            pendingInvites[peerID] = nil
            lastInviteProgress = Date()
            connectedSince[peerID] = Date()
            lastPongAt[peerID] = nil
            rangingRecoveryStep[peerID] = 0
            establishedPeers.insert(peerID)
            if peers[peerID] == nil {
                peers[peerID] = Peer(peerID: peerID)
            }
            sendHello(to: peerID)
            sendSessionIdentifier(to: peerID)
            beginHuddle(for: peerID)
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
                scheduleTeardown(peerID)
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
        // Heading and ARKit yaw rotate in opposite senses: compass heading
        // grows clockwise, ARKit yaw (`atan2(forward.x, forward.z)`) grows
        // counter-clockwise viewed from above — turning right takes forward
        // from -z toward +x, a falling angle. So the per-device constant that
        // survives rotation is `heading + yaw`, the azimuth of north in that
        // device's ARKit frame. θ rotates the peer's frame into ours, and north
        // is north in both: north_theirs + θ = north_ours.
        //
        // This used to be `heading - yaw`, which is only invariant when the two
        // phones face the same or opposite directions — exactly the two ways a
        // pair is usually tested, so the prior looked right until the phones
        // were held at 90°, where it was off by 180°.
        let ourNorth = localHeading + locar.localYaw
        let theirNorth = theirHeading + theirYaw
        let compassTheta = LocAREngine.wrapAngle(ourNorth - theirNorth)
        locar.setThetaPrior(compassTheta, for: peerID)
        frameStore.setCompassTheta(frameID(for: peerID), compassTheta)

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

    /// True when our own measurements of this peer beat anything a third party
    /// can tell us about it.
    ///
    /// A shared estimate arrives in the sender's frame and has to be rotated by
    /// theta before it means anything here, so it carries the sender's theta
    /// error on top of its own — and the sender is subject to the same single
    /// camera-assistance claim we are, so its fix on this target is often the
    /// weak one. It ships whenever its confidence clears 0.6 regardless.
    /// Applying that over a peer we range and bear ourselves replaces a
    /// first-hand measurement with a worse second-hand one, and when the two
    /// disagree enough `ingestRelativeEstimate` reseeds 30% of the cloud onto
    /// the relayed position.
    ///
    /// Relaying still does the job it exists for: a peer we cannot range
    /// ourselves fails both tests here and is placed entirely through its anchor.
    private func hasBetterDirectFix(for peerID: MCPeerID, at now: Date) -> Bool {
        guard let sample = localRange[peerID], now.timeIntervalSince(sample.date) < freshWindow else {
            return false
        }
        return freshBearing(for: peerID, at: now) != nil
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
        if collaborationActive {
            parts.append("collab")
        } else if !useCameraAssistance {
            parts.append("camOff")
        } else if cameraAssistedPeer == peerID {
            parts.append("cam")
        }
        if let fix = lastVisualFix[peerID], Date().timeIntervalSince(fix) < 5 {
            parts.append("vfix")
        }
        if let offset = clockOffset[peerID], offset.isFinite {
            parts.append("clk")
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
        // The solver's θ and its σ, "?" when a second basin ties.
        if let solution = frameSolutions[peerID] {
            parts.append(String(
                format: "ls%.0f±%.0f%@",
                solution.theta * 180 / .pi,
                min(solution.sigmaTheta * 180 / .pi, 999),
                solution.ambiguous ? "?" : ""
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
        // A session created here for a peer whose token we already hold can
        // run now rather than wait for the peer to send it again.
        if configurations[peerID] == nil, peerTokens[peerID] != nil {
            runSession(for: peerID)
        }
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
            tokenAttempts[peerID] = nil
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
        if data.count == 1, data.first == 0x4B {
            // The peer wants our token again: its session is new, or it lost ours.
            sendDiscoveryToken(to: peerID, force: true)
            return
        }
        if data.count == 9, data.first == 0x43 {
            // Clock sync request: echo t0, add our receive and send times.
            var reply = Data([0x44])
            reply.append(data.subdata(in: 1..<9))
            var received = CACurrentMediaTime()
            withUnsafeBytes(of: &received) { reply.append(contentsOf: $0) }
            var sent = CACurrentMediaTime()
            withUnsafeBytes(of: &sent) { reply.append(contentsOf: $0) }
            send(reply, to: [peerID], mode: .unreliable, label: "clock")
            return
        }
        if data.count == 25, data.first == 0x44 {
            handleClockReply(data, from: peerID)
            return
        }
        if data.count > 1, data.first == 0x41 {
            handleCollaboration(data.dropFirst(), from: peerID)
            return
        }
        if data.count == 17, data.first == 0x4A {
            let uuid = data.subdata(in: 1..<17).withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
            participantSessions = participantSessions.filter { $0.value != peerID }
            participantSessions[uuid] = peerID
            mcLog("ar-session", peerID, uuid.uuidString.prefix(8).description)
            return
        }
        if data.count == 9, data.first == 0x50 {
            var reply = Data([0x51])
            reply.append(data.subdata(in: 1..<9))
            send(reply, to: [peerID], mode: .unreliable, label: "pong")
            return
        }
        if data.count == 9, data.first == 0x51 {
            lastPongAt[peerID] = Date()
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
        if data.count == 18 || data.count == 26, data.first == 0x56 {
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
        let changed = peerTokenData[peerID].map { $0 != data } ?? false
        mcLog("token-recv", peerID, changed ? "changed: peer rebuilt its session" : "")
        peerTokens[peerID] = token
        peerTokenData[peerID] = data
        runSession(for: peerID)
        // A changed token means the peer's session is new and has never held
        // our token. The unforced send here used to be skipped as "already
        // sent", so the peer waited forever for a token that never came: both
        // ends dark on UWB while Multipeer was fine, and the peer drawn only by
        // relay. Forcing on a change ends there, because our token has not
        // changed and the peer will not force one back.
        sendDiscoveryToken(to: peerID, force: changed)
    }

    /// Run this peer's session against the token we hold for it, creating the
    /// session if needed. Re-running a live configuration is how NI resumes,
    /// so this is safe to repeat.
    private func runSession(for peerID: MCPeerID) {
        guard let token = peerTokens[peerID] else { return }
        let session = niSession(for: peerID)
        let configuration = NINearbyPeerConfiguration(peerToken: token)
        configuration.isCameraAssistanceEnabled = usesCameraAssistance(peerID)
        configurations[peerID] = configuration
        session.run(configuration)
    }

    /// 0x4B: ask the peer to send its discovery token again.
    private func requestToken(from peerID: MCPeerID) {
        guard mcSession?.connectedPeers.contains(peerID) == true else { return }
        send(Data([0x4B]), to: [peerID], mode: .reliable, label: "token-request")
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
        guard useCameraAssistance, !collaborationActive else { return false }
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
        guard useCameraAssistance, !collaborationActive, let current = cameraAssistedPeer else { return }
        let now = Date()
        let held = now.timeIntervalSince(cameraAssistanceGrantedAt)
        // A nil hint means NIAlgorithmConvergence reported `.converged`.
        let converged = peers[current]?.hint == nil
        let due = held >= (converged ? cameraAssistanceMinHold : cameraAssistanceMaxHold)
        guard due else { return }
        guard let next = nextCameraAssistanceCandidate(excluding: current, at: now) else { return }
        mcLog("cam-rotate", next, String(format: "from %@ after %.0fs", current.displayName, held))
        moveCameraAssistance(to: next, from: current)
    }

    /// The peer that has gone longest without a real theta measurement.
    ///
    /// This used to be round-robin behind a hard veto: hand the claim on only to
    /// a peer with no live range, on the reasoning that re-running a
    /// configuration interrupts ranging and so should happen in a gap that
    /// already exists. The effect with three devices was the opposite of the
    /// intent. Once every link is healthy no peer ever qualifies, so the veto
    /// fires every time and the claim never moves again. One peer per device
    /// keeps `horizontalAngle` forever and every other peer loses its only
    /// source of theta. Two devices never showed it: one link, and the single
    /// claim covers it.
    ///
    /// So the veto is now a preference — a peer with no live range still goes
    /// first, since it has nothing else — and staleness breaks the rest. A
    /// peer's bearing to us now measures theta on its own, so a link only
    /// needs the claim on one of its two ends at a time; ordering by staleness
    /// spreads the claim over links rather than pairing ends.
    private func nextCameraAssistanceCandidate(excluding current: MCPeerID, at now: Date) -> MCPeerID? {
        let candidates = niSessions.keys.filter { $0 != current }
        guard !candidates.isEmpty else { return nil }
        return candidates.min { a, b in
            let aDark = tracks[a]?.isLive(at: now) != true
            let bDark = tracks[b]?.isLive(at: now) != true
            if aDark != bDark { return aDark }
            let aAge = thetaAge(of: a, at: now)
            let bAge = thetaAge(of: b, at: now)
            // Deterministic tiebreak, so two peers that have never been measured
            // cannot oscillate the claim between them.
            if aAge != bAge { return aAge > bAge }
            return a.displayName < b.displayName
        }
    }

    /// Seconds since a bearing of this peer's last actually measured its
    /// theta. `lastThetaIngest` is written only when one succeeds.
    ///
    /// Only the solver counts. A peer's bearing reaching the cloud used to
    /// count too, but on its own it does not measure theta: it fixes theta
    /// *given* the peer's position, and when that position comes from the
    /// compass-seeded theta the cloud ends up confidently placing the peer
    /// wherever the compass bias says, which indoors is tens of degrees out.
    /// The solver's sigma is the one number that says theta was observed.
    private func thetaAge(of peerID: MCPeerID, at now: Date) -> TimeInterval {
        guard let last = lastFrameTrust[peerID] else { return .greatestFiniteMagnitude }
        return now.timeIntervalSince(last)
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
        guard useCameraAssistance, !collaborationActive,
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
        pendingTeardowns[peerID]?.cancel()
        pendingTeardowns[peerID] = nil
        sessionRebuilds[peerID]?.cancel()
        sessionRebuilds[peerID] = nil
        let session = niSessions.removeValue(forKey: peerID)
        session?.delegate = nil
        session?.invalidate()
        configurations[peerID] = nil
        peerTokens[peerID] = nil
        peerTokenData[peerID] = nil
        rangingRecoveryStep[peerID] = nil
        lastRangingRecovery[peerID] = nil
        lastPongAt[peerID] = nil
        connectedSince[peerID] = nil
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
        lastRemoteYaw[peerID] = nil
        lastThetaAnchor[peerID] = nil
        lastRangeIngest[peerID] = nil
        lastBearingIngest[peerID] = nil
        lastThetaIngest[peerID] = nil
        lastBearingLog[peerID] = nil
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
        if let frameID = frameIDs.removeValue(forKey: peerID) {
            frameStore.clearPeer(frameID)
        }
        frameSolutions[peerID] = nil
        lastFrameTrust[peerID] = nil
        lastFrameLog[peerID] = nil
        clockSamples[peerID] = nil
        clockOffset[peerID] = nil
        lastVisualFix[peerID] = nil
        lastVisualFixLog[peerID] = nil
        participantSessions = participantSessions.filter { $0.value != peerID }
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
        let bearing = bodyAngle(horizontalAngle: horizontalAngle, direction: direction)
        if bearing == nil {
            // A device with no bearing contributes nothing to the peer's theta,
            // so name which input was missing rather than just that the result
            // was nil.
            bearingLog(
                "no-bearing",
                peerID,
                "hAngle \(horizontalAngle == nil ? "nil" : "ok") dir \(direction == nil ? "nil" : "ok")"
                    + (useCameraAssistance ? "" : " camOff")
            )
        }
        if let angle = bearing {
            // Resolved here, against the yaw this bearing was actually taken at.
            let psi = locar.worldAzimuth(bodyAngle: angle)
            lastBearing[peerID] = (angle, psi, now)
            if let psi {
                frameStore.recordOurBearing(frameID(for: peerID), azimuth: psi, at: CACurrentMediaTime())
            }
            sendBearing(psi, at: now, to: peerID)
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
            frameStore.recordRange(frameID(for: peerID), distance, at: CACurrentMediaTime())
            sendRawRange(sample, to: peerID)
            fuse(peerID)
        } else if changed {
            setNeedsPublish()
        }
    }

    private func handleRemove(sessionID: ObjectIdentifier, peerEnded: Bool) {
        guard let peerID = peerID(for: sessionID) else { return }
        mcLog("ni-remove", peerID, peerEnded ? "peerEnded" : "timeout")
        restartRanging(peerID)
        // The peer's session ended, so its next one carries a new token. It
        // sends that on its own; asking too covers a lost send.
        if peerEnded {
            requestToken(from: peerID)
        }
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
            if collaborationActive {
                // A collaborating ARSession is the one configuration camera
                // assistance rejects by documentation. Nothing should have
                // claimed it in this mode; if something did, the mode is the
                // fault, not the hardware, so do not write the device off.
                mcLog("cam-conflict", peerID(for: sessionID), "invalidARConfiguration while collaborating")
            } else {
                // Permanent and global: once off, no session ever asks for camera
                // assistance again, so the device silently loses `horizontalAngle`
                // and with it every bearing past raw NI direction's short range.
                // That is exactly the state that stops this device measuring
                // anyone's theta, so it must be visible.
                if useCameraAssistance {
                    mcLog("cam-disabled", peerID(for: sessionID), "invalidARConfiguration, permanent")
                }
                useCameraAssistance = false
            }
        }
        guard let peerID = peerID(for: sessionID) else { return }
        niErrors[peerID] = Self.shortError(error)
        mcLog("ni-invalid", peerID, Self.shortError(error))
        let limited = (error as? NIError)?.code == .activeSessionsLimitExceeded
        dropSession(for: peerID)
        scheduleSessionRebuild(for: peerID, after: limited ? 3 : 1)
    }

    /// Forget a session that is gone or being replaced. Without releasing the
    /// camera claim it stayed pinned to a peer whose session was gone: no one
    /// else could claim it, and `rotateCameraAssistanceIfDue` could no longer
    /// find the holder among `niSessions`, so rotation stopped for good.
    private func dropSession(for peerID: MCPeerID) {
        if let session = niSessions.removeValue(forKey: peerID) {
            session.delegate = nil
            session.invalidate()
        }
        configurations[peerID] = nil
        sentTokenTo.remove(peerID)
        releaseCameraAssistance(from: peerID)
    }

    /// Rebuild after a pause. Immediate recreation turned an active-session
    /// limit into a tight invalidate-and-create loop. The new session runs at
    /// once against the peer's stored token, which is still valid unless the
    /// peer rebuilt too, in which case its changed token arrives and re-runs
    /// us. Our new token goes out forced, since the peer's session has never
    /// held it, and we ask for theirs in case ours was not the only one lost.
    private func scheduleSessionRebuild(for peerID: MCPeerID, after delay: TimeInterval) {
        sessionRebuilds[peerID]?.cancel()
        sessionRebuilds[peerID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                self.sessionRebuilds[peerID] = nil
                guard self.mcSession?.connectedPeers.contains(peerID) == true,
                      self.niSessions[peerID] == nil else { return }
                self.mcLog("ni-rebuild", peerID)
                self.runSession(for: peerID)
                self.sendDiscoveryToken(to: peerID, force: true)
                self.requestToken(from: peerID)
            }
        }
    }

    /// Multipeer drops for a second or two far more often than a peer actually
    /// leaves, and Nearby Interaction ranging does not depend on Multipeer
    /// once tokens are exchanged. Tearing the NI session down on every blip
    /// threw away a converged session and cost a full token exchange plus
    /// camera re-convergence on each reconnect. So teardown waits; a reconnect
    /// inside the grace cancels it and the session carries on untouched.
    private func scheduleTeardown(_ peerID: MCPeerID) {
        pendingTeardowns[peerID]?.cancel()
        mcLog("teardown-deferred", peerID, "\(Int(teardownGrace)) s grace")
        let grace = teardownGrace
        pendingTeardowns[peerID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                self.pendingTeardowns[peerID] = nil
                guard self.mcSession?.connectedPeers.contains(peerID) != true else { return }
                self.mcLog("teardown", peerID, "grace expired")
                self.tearDown(peerID)
            }
        }
    }

    /// Escalating recovery for a peer that is connected over Multipeer but
    /// silent on Nearby Interaction. NI's own `didRemove(.timeout)` covers the
    /// common case; this covers the ones it does not — a configuration that
    /// never ran, a token pair that fell out of step — where nothing else
    /// would ever act. Steps, `rangingSilence` apart: re-run our configuration;
    /// re-exchange tokens; rebuild our session. Each full cycle waits longer,
    /// since a peer that Multipeer reaches but UWB does not is usually just
    /// far away, and rebuilding a session every 45 s buys nothing there. Any
    /// ranging update resets the escalation.
    private func watchRanging() {
        guard let session = mcSession else { return }
        let now = Date()
        for peerID in session.connectedPeers {
            // Pairing has not started until a token has gone either way.
            guard sentTokenTo.contains(peerID) || peerTokens[peerID] != nil else { continue }
            let lastUpdate = lastUWBUpdate[peerID] ?? connectedSince[peerID] ?? now
            let silent = now.timeIntervalSince(lastUpdate)
            guard silent >= rangingSilence else {
                rangingRecoveryStep[peerID] = 0
                continue
            }
            let step = rangingRecoveryStep[peerID] ?? 0
            let cycle = step / 3
            let interval = rangingSilence * Double(min(cycle + 1, 4))
            if let last = lastRangingRecovery[peerID], now.timeIntervalSince(last) < interval { continue }
            lastRangingRecovery[peerID] = now
            rangingRecoveryStep[peerID] = step + 1
            switch step % 3 {
            case 0:
                mcLog("ni-watchdog", peerID, "silent \(Int(silent)) s: re-run")
                if configurations[peerID] != nil {
                    runSession(for: peerID)
                } else {
                    sendDiscoveryToken(to: peerID, force: true)
                    requestToken(from: peerID)
                }
            case 1:
                mcLog("ni-watchdog", peerID, "silent \(Int(silent)) s: re-exchange tokens")
                sendDiscoveryToken(to: peerID, force: true)
                requestToken(from: peerID)
            default:
                mcLog("ni-watchdog", peerID, "silent \(Int(silent)) s: rebuild session")
                dropSession(for: peerID)
                scheduleSessionRebuild(for: peerID, after: 0.5)
            }
        }
    }

    /// A Multipeer link can sit in `.connected` long after it stopped carrying
    /// anything. Pings go out at 4 Hz, so `pongSilence` without a single pong
    /// is a dead link; cancelling it produces the `.notConnected` that the
    /// reconnect schedule already knows how to handle.
    private func watchLinks() {
        guard let session = mcSession else { return }
        let now = Date()
        for peerID in session.connectedPeers {
            let since = lastPongAt[peerID] ?? connectedSince[peerID] ?? now
            guard now.timeIntervalSince(since) >= pongSilence else { continue }
            lastPongAt[peerID] = now
            mcLog("mc-zombie", peerID, "no pong for \(Int(pongSilence)) s, cancelling")
            session.cancelConnectPeer(peerID)
        }
    }

    /// The app is back in front. Nearby Interaction suspends in the background
    /// and Multipeer usually drops, and neither reliably announces recovery.
    /// Re-run every session we have, re-pair the ones we do not, re-arm
    /// discovery, and chase peers that were connected before.
    func sceneDidBecomeActive() {
        let now = Date()
        mcLog("scene-active")
        for peerID in mcSession?.connectedPeers ?? [] {
            lastPongAt[peerID] = now
            rangingRecoveryStep[peerID] = 0
            lastRangingRecovery[peerID] = now
            if configurations[peerID] != nil {
                runSession(for: peerID)
            } else {
                sendDiscoveryToken(to: peerID, force: true)
                requestToken(from: peerID)
            }
        }
        lastDiscoveryRefresh = .distantPast
        refreshDiscoveryIfDue()
        for peerID in knownRemoteIDs.keys where mcSession?.connectedPeers.contains(peerID) != true {
            scheduleReconnect(peerID)
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
        let peerEnded = reason == .peerEnded
        Task { @MainActor in
            self.handleRemove(sessionID: sessionID, peerEnded: peerEnded)
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
