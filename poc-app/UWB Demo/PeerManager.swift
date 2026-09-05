import Combine
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

        var id: MCPeerID { peerID }
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
            sendDiscoveryToken(to: peerID, force: true)
            sendHeading(localHeading)
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
        peers[peerID] = nil
        isTearingDown = false
    }

    private func peerID(for sessionID: ObjectIdentifier) -> MCPeerID? {
        niSessions.first(where: { ObjectIdentifier($0.value) == sessionID })?.key
    }

    private func handleUpdate(sessionID: ObjectIdentifier, distance: Float?, direction: simd_float3?) {
        guard let peerID = peerID(for: sessionID), var peer = peers[peerID] else { return }
        if let distance {
            peer.distance = distance
        }
        if let direction {
            peer.direction = direction
        }
        peers[peerID] = peer
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

    private func handleInvalidation(sessionID: ObjectIdentifier) {
        guard !isTearingDown else { return }
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

extension PeerManager: NISessionDelegate {
    nonisolated func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        let sessionID = ObjectIdentifier(session)
        let distance = nearbyObjects.first?.distance
        let direction = nearbyObjects.first?.direction
        Task { @MainActor in
            self.handleUpdate(sessionID: sessionID, distance: distance, direction: direction)
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
            self.handleInvalidation(sessionID: sessionID)
        }
    }
}
