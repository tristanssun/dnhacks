import Combine
import Foundation
import NearbyInteraction

struct HTTPResponseBody: Decodable {
  let id: Int
  let token: String
  let success: Bool
}

class InteractionManager: NSObject, ObservableObject {
  private static let apiURLDefaultsKey = "apiURL"

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
  @Published var myTokenId: Int = 0
  @Published var isSupported: Bool = false
  @Published var isPeerReady: Bool = false
  @Published var statusMessage: String = "Start the token server, then get your code."

  private var session: NISession? = nil
  private var peerToken: NIDiscoveryToken? = nil
  private var shouldStartWhenPeerReady = false

  override init() {
    if let stored = UserDefaults.standard.string(forKey: Self.apiURLDefaultsKey), !stored.isEmpty {
      self.apiURL = stored
    } else {
      self.apiURL = Self.defaultAPIURL
    }
    super.init()
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
    if !supported {
      self.statusMessage =
        "This device cannot measure UWB distance. Token exchange still works if the server is running."
      return
    }

    self.session = NISession()
    self.session?.delegate = self
  }

  func getMyToken() {
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
    self.session?.invalidate()
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
      self.statusMessage = "Session is running. Move the phones to update distance."
    }
  }
  func session(_ session: NISession, didUpdate: [NINearbyObject]) {
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
      self.statusMessage = "Session ended: \(error.localizedDescription)"
      self.peerToken = nil
      self.isPeerReady = false
      self.prepare()
    }
  }
}
