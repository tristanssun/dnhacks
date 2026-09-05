import Combine
import Foundation
import NearbyInteraction

struct HTTPResponseBody: Decodable {
  let id: Int
  let token: String
  let success: Bool
}

enum DistanceMode: String, CaseIterable, Identifiable {
  case uwb
  case bluetooth

  var id: String { self.rawValue }

  var title: String {
    switch self {
    case .uwb:
      return "UWB"
    case .bluetooth:
      return "Bluetooth"
    }
  }
}

class InteractionManager: NSObject, ObservableObject {
  private static let apiURLDefaultsKey = "apiURL"
  private static let modeDefaultsKey = "distanceMode"

  static var defaultAPIURL: String {
    #if targetEnvironment(simulator)
      return "http://127.0.0.1:8787"
    #else
      return "http://192.168.1.250:8787"
    #endif
  }

  var distance: AnyPublisher<Float, Never> {
    self.distanceSubject.eraseToAnyPublisher()
  }

  private let distanceSubject = PassthroughSubject<Float, Never>()

  @Published var apiURL: String {
    didSet {
      UserDefaults.standard.set(self.apiURL, forKey: Self.apiURLDefaultsKey)
    }
  }
  @Published var mode: DistanceMode {
    didSet {
      guard oldValue != self.mode else { return }
      UserDefaults.standard.set(self.mode.rawValue, forKey: Self.modeDefaultsKey)
      self.handleModeChange()
    }
  }
  @Published var myTokenId: Int = 0
  @Published var isSupported: Bool = false
  @Published var isPeerReady: Bool = false
  @Published var statusMessage: String = "Start the token server, then get your code."

  var distanceCaption: String {
    switch self.mode {
    case .uwb:
      return "UWB"
    case .bluetooth:
      return "Bluetooth (approximate)"
    }
  }

  private var session: NISession? = nil
  private var peerToken: NIDiscoveryToken? = nil
  private var peerBluetoothId: Int? = nil
  private var shouldStartWhenPeerReady = false
  private let bluetoothRanger = BluetoothRangingManager()

  override init() {
    if let stored = UserDefaults.standard.string(forKey: Self.apiURLDefaultsKey), !stored.isEmpty {
      self.apiURL = stored
    } else {
      self.apiURL = Self.defaultAPIURL
    }
    if let storedMode = UserDefaults.standard.string(forKey: Self.modeDefaultsKey),
      let mode = DistanceMode(rawValue: storedMode)
    {
      self.mode = mode
    } else {
      self.mode = .uwb
    }
    super.init()
    self.bluetoothRanger.onDistance = { [weak self] meters in
      self?.distanceSubject.send(meters)
    }
    self.bluetoothRanger.onStatus = { [weak self] message in
      self?.statusMessage = message
    }
    self.prepare()
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("-autoGetCode") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
          self.getMyToken()
        }
      }
    #endif
  }

  func prepare() {
    var supported: Bool

    #if targetEnvironment(simulator)
      supported = false
    #else
      if #available(iOS 16.0, watchOS 9.0, *) {
        supported = NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
      } else {
        supported = NISession.isSupported
      }
    #endif

    self.isSupported = supported
    if self.mode == .bluetooth {
      self.statusMessage = "Bluetooth mode uses signal strength, not UWB. Get your code to begin."
      return
    }
    if !supported {
      self.statusMessage =
        "This device cannot measure UWB distance. Switch to Bluetooth, or use token exchange on a supported iPhone."
      return
    }

    self.session = NISession()
    self.session?.delegate = self
  }

  func getMyToken() {
    if self.mode == .bluetooth {
      self.assignBluetoothCode()
      return
    }

    self.statusMessage = "Publishing discovery token…"

    guard let myTokenData = self.archivedDiscoveryToken() else {
      return
    }

    guard let endpoint = self.makeURL(path: "") else {
      self.statusMessage = "Server URL is invalid."
      return
    }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(
      withJSONObject: ["token": myTokenData.base64EncodedString()])

    URLSession.shared.dataTask(with: request) { data, response, error in
      if let error = error {
        DispatchQueue.main.async {
          self.statusMessage = "Could not reach server: \(error.localizedDescription)"
        }
        return
      }
      if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
        DispatchQueue.main.async {
          self.statusMessage = "Server returned HTTP \(httpResponse.statusCode)."
        }
        return
      }
      guard let data = data else {
        DispatchQueue.main.async {
          self.statusMessage = "Server returned an empty response."
        }
        return
      }
      do {
        let responseBody = try JSONDecoder().decode(HTTPResponseBody.self, from: data)
        if !responseBody.success {
          DispatchQueue.main.async {
            self.statusMessage = "Server rejected the token."
          }
          return
        }
        DispatchQueue.main.async {
          self.myTokenId = responseBody.id
          self.statusMessage = String(
            format: "Your code is %04d. Enter the other phone's code.", responseBody.id)
          print("NearbyInteraction: assigned code \(responseBody.id)")
        }
      } catch {
        DispatchQueue.main.async {
          self.statusMessage = "Could not parse server response."
        }
      }
    }.resume()
  }

  func getPeerToken(id: Int) {
    if self.mode == .bluetooth {
      self.peerBluetoothId = id
      self.isPeerReady = true
      self.statusMessage = "Peer code set. Tap Start on both phones."
      if self.shouldStartWhenPeerReady {
        self.shouldStartWhenPeerReady = false
        self.startBluetoothIfPossible()
      }
      return
    }

    self.isPeerReady = false
    self.peerToken = nil
    self.statusMessage = "Looking up peer code \(String(format: "%04d", id))…"

    guard let endpoint = self.makeURL(path: "\(id)") else {
      self.statusMessage = "Server URL is invalid."
      return
    }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"

    URLSession.shared.dataTask(with: request) { data, response, error in
      if let error = error {
        DispatchQueue.main.async {
          self.statusMessage = "Could not reach server: \(error.localizedDescription)"
        }
        return
      }
      if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
        DispatchQueue.main.async {
          self.statusMessage = "Server returned HTTP \(httpResponse.statusCode)."
        }
        return
      }
      guard let data = data else {
        DispatchQueue.main.async {
          self.statusMessage = "Server returned an empty response."
        }
        return
      }
      do {
        let responseBody = try JSONDecoder().decode(HTTPResponseBody.self, from: data)
        if !responseBody.success {
          DispatchQueue.main.async {
            self.statusMessage = "Peer code not found yet. Wait for the other phone, then tap Start."
          }
          return
        }

        guard let peerTokenData = Data(base64Encoded: responseBody.token) else {
          DispatchQueue.main.async {
            self.statusMessage = "Peer token was not valid Base64."
          }
          return
        }

        let peerToken = try NSKeyedUnarchiver.unarchivedObject(
          ofClass: NIDiscoveryToken.self, from: peerTokenData)

        DispatchQueue.main.async {
          self.peerToken = peerToken
          self.isPeerReady = peerToken != nil
          if peerToken == nil {
            self.statusMessage = "Got a peer record, but it is not a Nearby Interaction token."
            self.shouldStartWhenPeerReady = false
          } else if self.shouldStartWhenPeerReady {
            self.shouldStartWhenPeerReady = false
            self.startSessionIfPossible()
          } else {
            self.statusMessage = "Peer token ready. Tap Start on both phones."
          }
        }
      } catch {
        DispatchQueue.main.async {
          self.statusMessage = "Could not decode peer token: \(error.localizedDescription)"
        }
      }
    }.resume()
  }

  func run(peerId: Int? = nil) {
    if self.mode == .bluetooth {
      if let peerId = peerId {
        self.peerBluetoothId = peerId
        self.isPeerReady = true
      }
      self.startBluetoothIfPossible()
      return
    }

    if self.peerToken != nil {
      self.startSessionIfPossible()
      return
    }
    guard let peerId = peerId else {
      self.statusMessage = "Enter a 4-digit peer code first."
      return
    }
    self.shouldStartWhenPeerReady = true
    self.getPeerToken(id: peerId)
  }

  func invalidate() {
    self.bluetoothRanger.stop()
    if let session = self.session {
      session.delegate = nil
      session.invalidate()
      self.session = nil
    }
  }

  private func handleModeChange() {
    self.shouldStartWhenPeerReady = false
    self.peerToken = nil
    self.peerBluetoothId = nil
    self.isPeerReady = false
    self.myTokenId = 0
    self.invalidate()
    self.prepare()
  }

  private func assignBluetoothCode() {
    self.myTokenId = 1000 + Int.random(in: 0..<9000)
    self.statusMessage = String(
      format: "Your code is %04d. Enter the other phone's code.", self.myTokenId)
  }

  private func startBluetoothIfPossible() {
    guard self.myTokenId != 0 else {
      self.statusMessage = "Get your code first."
      return
    }
    guard let peerId = self.peerBluetoothId else {
      self.statusMessage = "Enter a 4-digit peer code first."
      return
    }

    if let session = self.session {
      session.delegate = nil
      session.invalidate()
      self.session = nil
    }
    self.bluetoothRanger.start(myCode: self.myTokenId, peerCode: peerId)
  }

  private func startSessionIfPossible() {
    guard self.isSupported else {
      self.statusMessage = "Nearby Interaction is not available on this device or simulator."
      return
    }
    guard let peerToken = self.peerToken else {
      self.statusMessage = "Peer token is not ready yet."
      return
    }
    guard let session = self.session else {
      self.prepare()
      self.statusMessage = "Session was reset. Get a new code and pair again."
      return
    }

    self.bluetoothRanger.stop()
    session.run(NINearbyPeerConfiguration(peerToken: peerToken))
    self.statusMessage = "Nearby Interaction session started."
  }

  private func archivedDiscoveryToken() -> Data? {
    if let myToken = self.session?.discoveryToken,
      let myTokenData = try? NSKeyedArchiver.archivedData(
        withRootObject: myToken, requiringSecureCoding: true)
    {
      return myTokenData
    }

    if !self.isSupported {
      return Data("simulator-\(UUID().uuidString)".utf8)
    }

    self.statusMessage = "Discovery token is not ready yet. Try again in a moment."
    return nil
  }

  private func makeURL(path: String) -> URL? {
    var base = self.apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }
    if path.isEmpty {
      return URL(string: base)
    }
    return URL(string: "\(base)/\(path)")
  }
}

extension InteractionManager: NISessionDelegate {
  func sessionDidStartRunning(_ session: NISession) {
    DispatchQueue.main.async {
      guard self.mode == .uwb else { return }
      self.statusMessage = "Session is running. Move the phones to update distance."
    }
  }
  func session(_ session: NISession, didUpdate: [NINearbyObject]) {
    guard self.mode == .uwb else { return }
    for update in didUpdate {
      guard let distance = update.distance else {
        continue
      }
      DispatchQueue.main.async {
        self.distanceSubject.send(distance)
      }
    }
  }
  func session(
    _ session: NISession, didRemove: [NINearbyObject], reason: NINearbyObject.RemovalReason
  ) {
    DispatchQueue.main.async {
      self.statusMessage = "Lost nearby object (\(reason))."
    }
  }
  func sessionWasSuspended(_ session: NISession) {
    DispatchQueue.main.async {
      self.statusMessage = "Session suspended."
    }
  }
  func sessionSuspensionEnded(_ session: NISession) {
    if let peerToken = self.peerToken {
      session.run(NINearbyPeerConfiguration(peerToken: peerToken))
    }
    DispatchQueue.main.async {
      self.statusMessage = "Session resumed."
    }
  }
  func session(_ session: NISession, didInvalidateWith error: Error) {
    DispatchQueue.main.async {
      guard self.mode == .uwb else { return }
      self.statusMessage = "Session ended: \(error.localizedDescription)"
      self.peerToken = nil
      self.isPeerReady = false
      self.prepare()
    }
  }
}
