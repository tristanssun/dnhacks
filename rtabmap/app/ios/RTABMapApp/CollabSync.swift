//
//  CollabSync.swift
//  RTABMapApp
//
//  Background LAN sync of new RTAB-Map nodes while mapping.
//

import Foundation

class CollabSync {
    static let clientIdKey = "CollabClientId"
    static let defaultServerURL = CollabServerConfig.defaultURL

    var clientId: String
    var serverURL: String
    var databasePathProvider: (() -> String?)?
    var enabled: Bool = false
    var onImportRemote: ((String, [Float], Bool) -> Int)?
    var onClearRemote: (() -> Void)?
    var onSyncNotice: ((String) -> Void)?
    var onSyncTick: (() -> Void)?

    private var lastSyncedId: Int = 0
    private var lastPulledGlobalId: Int = 0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.rtabmap.collab-sync", qos: .utility)
    private var isSyncing = false
    private var poseInFlight = false
    private var lastLivePose: [String: Any]?
    private let session: URLSession

    init() {
        self.clientId = CollabSync.persistentClientId()
        self.serverURL = UserDefaults.standard.string(forKey: "CollabServerURL") ?? CollabSync.defaultServerURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    static func persistentClientId() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: clientIdKey), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString
        defaults.set(id, forKey: clientIdKey)
        return id
    }

    func configure(enabled: Bool, serverURL: String, databasePath: String) {
        self.enabled = enabled
        self.serverURL = serverURL
        self.clientId = CollabSync.persistentClientId()
        let path = databasePath
        self.databasePathProvider = { path }
        NSLog("CollabSync: configure enabled=%d url=%@ db=%@ client=%@", enabled ? 1 : 0, serverURL, path, self.clientId)
    }

    struct JoinResult {
        var ok: Bool
        var mode: String
        var activeClients: Int
        var globalNodes: Int
        var mustDownload: Bool
        var locked: Bool
        var showTag: Bool
        var mustWaitForLock: Bool
        var tagId: Int
        var error: String
    }

    struct DemoStatus {
        var ok: Bool
        var locked: Bool
        var showTag: Bool
        var tagId: Int
        var calibratedCount: Int
        var thisPhoneLocked: Bool
        var globalNodes: Int
    }

    func resetForNewScan() {
        queue.async {
            self.lastSyncedId = 0
            self.lastPulledGlobalId = 0
            self.onClearRemote?()
        }
    }

    func setLastSyncedId(_ id: Int) {
        queue.sync {
            self.lastSyncedId = max(0, id)
        }
    }

    func setLastPulledGlobalId(_ id: Int) {
        queue.sync {
            self.lastPulledGlobalId = max(0, id)
        }
    }

    func normalizedServerURL() -> String {
        var urlString = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if urlString.isEmpty {
            urlString = CollabSync.defaultServerURL
        }
        while urlString.hasSuffix("/") {
            urlString.removeLast()
        }
        return urlString
    }

    func joinSession() -> JoinResult? {
        clientId = CollabSync.persistentClientId()
        serverURL = UserDefaults.standard.string(forKey: "CollabServerURL") ?? CollabSync.defaultServerURL
        guard let url = URL(string: normalizedServerURL() + "/join") else {
            NSLog("CollabSync: invalid join URL %@", serverURL)
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(clientId, forHTTPHeaderField: "X-Client-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var statusCode = 0
        var requestError: Error?
        session.dataTask(with: request) { data, response, error in
            responseData = data
            requestError = error
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20)

        if let requestError = requestError {
            NSLog("CollabSync: POST /join failed: %@", requestError.localizedDescription)
            return nil
        }
        guard statusCode == 200, let responseData = responseData,
              let obj = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            let detail = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            NSLog("CollabSync: POST /join HTTP %d %@", statusCode, detail)
            return nil
        }
        let ok = (obj["ok"] as? Bool) ?? false
        if !ok {
            NSLog("CollabSync: POST /join ok=false %@", String(describing: obj["error"]))
            return nil
        }
        let locked = (obj["locked"] as? Bool) ?? false
        let result = JoinResult(
            ok: true,
            mode: (obj["mode"] as? String) ?? "",
            activeClients: jsonInt(obj, "active_clients") ?? 0,
            globalNodes: jsonInt(obj, "global_nodes") ?? 0,
            mustDownload: (obj["must_download"] as? Bool) ?? false,
            locked: locked,
            showTag: (obj["show_tag"] as? Bool) ?? !locked,
            mustWaitForLock: (obj["must_wait_for_lock"] as? Bool) ?? !locked,
            tagId: jsonInt(obj, "tag_id") ?? DemoTag.id,
            error: ""
        )
        NSLog("CollabSync: join mode=%@ active=%d nodes=%d must_download=%d locked=%d mustWait=%d",
              result.mode, result.activeClients, result.globalNodes, result.mustDownload ? 1 : 0,
              result.locked ? 1 : 0, result.mustWaitForLock ? 1 : 0)
        return result
    }

    func downloadMapDb(to path: String) -> Bool {
        guard let url = URL(string: normalizedServerURL() + "/map.db") else {
            NSLog("CollabSync: invalid map.db URL %@", serverURL)
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(clientId, forHTTPHeaderField: "X-Client-Id")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60

        let semaphore = DispatchSemaphore(value: 0)
        var fileData: Data?
        var statusCode = 0
        var requestError: Error?
        session.dataTask(with: request) { data, response, error in
            fileData = data
            requestError = error
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 65)

        if let requestError = requestError {
            NSLog("CollabSync: GET /map.db failed: %@", requestError.localizedDescription)
            return false
        }
        guard statusCode == 200, let fileData = fileData, !fileData.isEmpty else {
            NSLog("CollabSync: GET /map.db HTTP %d bytes=%d", statusCode, fileData?.count ?? 0)
            return false
        }
        do {
            let dest = URL(fileURLWithPath: path)
            try? FileManager.default.removeItem(at: dest)
            try fileData.write(to: dest, options: .atomic)
            NSLog("CollabSync: downloaded map.db (%d bytes) to %@", fileData.count, path)
            return true
        } catch {
            NSLog("CollabSync: write map.db failed: %@", error.localizedDescription)
            return false
        }
    }

    func fetchDemo() -> DemoStatus? {
        guard let url = URL(string: normalizedServerURL() + "/demo") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(clientId, forHTTPHeaderField: "X-Client-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8
        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var statusCode = 0
        session.dataTask(with: request) { data, response, _ in
            responseData = data
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 10)
        guard statusCode == 200, let responseData = responseData,
              let obj = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            return nil
        }
        let locked = (obj["locked"] as? Bool) ?? false
        var thisPhone = false
        if let calibrated = obj["calibrated"] as? [[String: Any]] {
            for item in calibrated {
                if (item["id"] as? String) == clientId, (item["locked"] as? Bool) == true {
                    thisPhone = true
                }
            }
        }
        return DemoStatus(
            ok: (obj["ok"] as? Bool) ?? true,
            locked: locked,
            showTag: (obj["show_tag"] as? Bool) ?? !locked,
            tagId: jsonInt(obj, "tag_id") ?? DemoTag.id,
            calibratedCount: jsonInt(obj, "calibrated_count") ?? 0,
            thisPhoneLocked: thisPhone,
            globalNodes: jsonInt(obj, "global_nodes") ?? 0
        )
    }

    func postCalibrate(pose: TagPose) -> DemoStatus? {
        guard let url = URL(string: normalizedServerURL() + "/calibrate") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(clientId, forHTTPHeaderField: "X-Client-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8
        request.httpBody = try? JSONSerialization.data(withJSONObject: pose.jsonBody())
        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var statusCode = 0
        session.dataTask(with: request) { data, response, _ in
            responseData = data
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 10)
        guard statusCode == 200, let responseData = responseData,
              let obj = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              (obj["ok"] as? Bool) ?? false else {
            let detail = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            NSLog("CollabSync: POST /calibrate HTTP %d %@", statusCode, detail)
            return nil
        }
        let locked = (obj["locked"] as? Bool) ?? false
        NSLog("CollabSync: calibrate ok locked=%d show_tag=%d count=%d",
              locked ? 1 : 0, ((obj["show_tag"] as? Bool) ?? !locked) ? 1 : 0,
              jsonInt(obj, "calibrated_count") ?? 0)
        return DemoStatus(
            ok: true,
            locked: locked,
            showTag: (obj["show_tag"] as? Bool) ?? !locked,
            tagId: jsonInt(obj, "tag_id") ?? pose.tagId,
            calibratedCount: jsonInt(obj, "calibrated_count") ?? 0,
            thisPhoneLocked: true,
            globalNodes: 0
        )
    }

    func postLivePose(tx: Float, ty: Float, tz: Float, qx: Float, qy: Float, qz: Float, qw: Float) {
        let body: [String: Any] = [
            "tx": tx, "ty": ty, "tz": tz,
            "qx": qx, "qy": qy, "qz": qz, "qw": qw
        ]
        lastLivePose = body
        guard enabled else { return }
        queue.async { [weak self] in
            self?.sendLivePose(body)
        }
    }

    private func sendLivePose(_ body: [String: Any]) {
        guard !poseInFlight else { return }
        guard let url = URL(string: normalizedServerURL() + "/pose") else { return }
        poseInFlight = true
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(clientId, forHTTPHeaderField: "X-Client-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 2
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        session.dataTask(with: request) { [weak self] _, _, error in
            if let error = error {
                NSLog("CollabSync: POST /pose failed: %@", error.localizedDescription)
            }
            self?.queue.async { self?.poseInFlight = false }
        }.resume()
    }

    private func postHeartbeat() {
        guard let url = URL(string: normalizedServerURL() + "/heartbeat") else {
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(clientId, forHTTPHeaderField: "X-Client-Id")
        request.timeoutInterval = 10
        if let pose = lastLivePose,
           let data = try? JSONSerialization.data(withJSONObject: pose) {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
        }
        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { _, _, error in
            if let error = error {
                NSLog("CollabSync: POST /heartbeat failed: %@", error.localizedDescription)
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 12)
    }

    func start() {
        queue.async {
            if self.timer != nil {
                NSLog("CollabSync: already running (enabled=%d server=%@ client=%@)", self.enabled ? 1 : 0, self.serverURL, self.clientId)
                return
            }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in
                self?.syncOnce()
            }
            timer.resume()
            self.timer = timer
            NSLog("CollabSync: started (enabled=%d server=%@ client=%@)", self.enabled ? 1 : 0, self.serverURL, self.clientId)
        }
    }

    func stop(flush: Bool = false) {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            if flush {
                self.syncOnce()
            }
            NSLog("CollabSync: stopped (flush=%d, lastSyncedId=%d lastPulledGlobalId=%d)", flush ? 1 : 0, self.lastSyncedId, self.lastPulledGlobalId)
        }
    }

    /// Stop the 2s timer, flush upload+pull, then download the merged global db.
    /// Call from a non-collab queue. Returns downloaded byte count (0 on failure).
    func stopAndDownloadGlobalMap(to path: String) -> Int {
        var bytes = 0
        let semaphore = DispatchSemaphore(value: 0)
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.syncOnce()
            if self.downloadMapDb(to: path) {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let size = attrs[.size] as? NSNumber {
                    bytes = size.intValue
                }
            }
            NSLog("CollabSync: stop+download global.db bytes=%d path=%@", bytes, path)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 180)
        return bytes
    }

    private func syncOnce() {
        if isSyncing {
            NSLog("CollabSync: skip, already syncing")
            return
        }
        guard enabled else {
            NSLog("CollabSync: skip, disabled")
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        if let path = databasePathProvider?(), !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            if let snapPath = snapshotLiveDatabase(path) {
                defer { removeSnapshot(snapPath) }
                uploadFromSnapshot(snapPath, livePath: path)
            } else {
                NSLog("CollabSync: snapshot failed, heartbeat+pull only")
                postHeartbeat()
            }
        } else {
            NSLog("CollabSync: no local db, heartbeat+pull only")
            postHeartbeat()
        }

        pullOnce()
    }

    private func uploadFromSnapshot(_ snapPath: String, livePath: String) {
        let currentLast = lastNodeId(databasePath: snapPath)
        NSLog("CollabSync: tick enabled=1 url=%@ db=%@ lastNodeId=%d lastSyncedId=%d lastPulled=%d",
              serverURL, livePath, currentLast, lastSyncedId, lastPulledGlobalId)
        if currentLast <= lastSyncedId {
            NSLog("CollabSync: skip POST, no new nodes (lastNodeId=%d lastSyncedId=%d). Heartbeat to keep the room lock.", currentLast, lastSyncedId)
            postHeartbeat()
            return
        }

        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rtabmap.delta.\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        let exported = exportDeltaDb(src: snapPath, dst: tmpURL.path, sinceId: lastSyncedId)
        NSLog("CollabSync: exportDeltaDb sinceId=%d count=%d dst=%@", lastSyncedId, exported, tmpURL.path)
        if exported <= 0 {
            NSLog("CollabSync: skip POST, export returned %d", exported)
            return
        }

        guard let body = try? Data(contentsOf: tmpURL) else {
            NSLog("CollabSync: failed to read delta db at %@", tmpURL.path)
            return
        }
        NSLog("CollabSync: upload bytes=%d nodes=%d url=%@/sync", body.count, exported, serverURL)

        guard let url = URL(string: normalizedServerURL() + "/sync") else {
            NSLog("CollabSync: invalid server URL %@", serverURL)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(clientId, forHTTPHeaderField: "X-Client-Id")
        request.setValue(String(lastSyncedId), forHTTPHeaderField: "X-Since-Id")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.timeoutInterval = 120
        request.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var statusCode = 0
        var requestError: Error?

        session.dataTask(with: request) { data, response, error in
            responseData = data
            requestError = error
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 125)

        if let requestError = requestError {
            NSLog("CollabSync: POST /sync failed: %@", requestError.localizedDescription)
            return
        }
        if statusCode != 200 {
            let detail = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            NSLog("CollabSync: POST /sync HTTP %d %@", statusCode, detail)
            return
        }

        var newLast = currentLast
        if let responseData = responseData,
           let obj = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
            if let last = jsonInt(obj, "last_local_id") {
                newLast = last
            }
            let accepted = jsonInt(obj, "accepted") ?? exported
            NSLog("CollabSync: uploaded %d nodes, accepted=%d last_local_id=%d", exported, accepted, newLast)
            if accepted > 0 {
                let word = accepted == 1 ? "scan" : "scans"
                onSyncNotice?("Synced \(accepted) \(word)")
                onSyncTick?()
            }
        } else {
            NSLog("CollabSync: uploaded %d nodes (no JSON last_local_id, using %d)", exported, newLast)
        }
        lastSyncedId = newLast
    }

    private func parseTransformHeader(_ value: String?) -> [Float] {
        guard let value = value, !value.isEmpty else {
            return []
        }
        let parts = value.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
        return parts.count >= 7 ? Array(parts.prefix(7)) : []
    }

    private func headerInt(_ response: HTTPURLResponse?, _ name: String) -> Int? {
        guard let raw = response?.value(forHTTPHeaderField: name) else {
            return nil
        }
        return Int(raw.trimmingCharacters(in: .whitespaces))
    }

    private func isSqliteData(_ data: Data) -> Bool {
        guard data.count >= 15 else {
            return false
        }
        return data.subdata(in: 0..<15) == Data("SQLite format 3".utf8)
    }

    private func pullOnce() {
        let since = lastPulledGlobalId
        let pullURL = normalizedServerURL() + "/pull?since_global_id=\(since)"
        guard let url = URL(string: pullURL) else {
            NSLog("CollabSync: invalid pull URL %@", serverURL)
            return
        }
        NSLog("CollabSync: GET /pull url=%@ client=%@ since=%d", pullURL, clientId, since)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(clientId, forHTTPHeaderField: "X-Client-Id")
        request.setValue(String(since), forHTTPHeaderField: "X-Since-Global-Id")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var http: HTTPURLResponse?
        var requestError: Error?
        session.dataTask(with: request) { data, response, error in
            responseData = data
            http = response as? HTTPURLResponse
            requestError = error
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 65)

        if let requestError = requestError {
            NSLog("CollabSync: GET /pull failed: %@", requestError.localizedDescription)
            return
        }
        let statusCode = http?.statusCode ?? 0
        let bytes = responseData?.count ?? 0
        if statusCode != 200 {
            let detail = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            NSLog("CollabSync: GET /pull url=%@ HTTP %d bytes=%d %@", pullURL, statusCode, bytes, detail)
            return
        }

        let maxId = headerInt(http, "X-Max-Global-Id") ?? 0
        let nodes = headerInt(http, "X-Nodes-Count") ?? 0
        let poses = headerInt(http, "X-Poses-Count") ?? 0
        let aligned = (http?.value(forHTTPHeaderField: "X-Aligned") ?? "0") == "1"
        let transform = parseTransformHeader(http?.value(forHTTPHeaderField: "X-Client-To-Global"))
        NSLog("CollabSync: GET /pull url=%@ HTTP %d since=%d max_id=%d nodes=%d poses=%d aligned=%d xf=%d bytes=%d",
              pullURL, statusCode, since, maxId, nodes, poses, aligned ? 1 : 0, transform.count, bytes)

        if !aligned {
            NSLog("CollabSync: remote overlay may be misaligned until inter-session loop closure")
        }

        var imported = 0
        var importedOk = nodes == 0
        if let responseData = responseData, isSqliteData(responseData) {
            let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rtabmap.pull.\(UUID().uuidString).db")
            do {
                try responseData.write(to: tmpURL, options: .atomic)
                if let onImportRemote = onImportRemote {
                    imported = onImportRemote(tmpURL.path, transform, aligned)
                    importedOk = true
                    NSLog("CollabSync: importRemoteDeltaDb imported=%d meshes added path=%@", imported, tmpURL.path)
                } else {
                    NSLog("CollabSync: no importRemote handler, remote clouds not drawn")
                }
            } catch {
                NSLog("CollabSync: write pull db failed: %@", error.localizedDescription)
            }
            try? FileManager.default.removeItem(at: tmpURL)
        } else if nodes > 0 {
            NSLog("CollabSync: GET /pull had nodes=%d but body is not a sqlite db", nodes)
        }

        if importedOk, maxId > lastPulledGlobalId {
            lastPulledGlobalId = maxId
        } else if nodes > 0 && !importedOk {
            NSLog("CollabSync: keep lastPulled=%d, import failed for %d nodes", lastPulledGlobalId, nodes)
        }
        if imported > 0 {
            let word = imported == 1 ? "scan" : "scans"
            onSyncNotice?("Received \(imported) from others")
            onSyncTick?()
        } else if nodes == 0 {
            onSyncTick?()
        }
        NSLog("CollabSync: pull done imported=%d lastPulled=%d", imported, lastPulledGlobalId)
    }

    private func jsonInt(_ obj: [String: Any], _ key: String) -> Int? {
        if let value = obj[key] as? Int {
            return value
        }
        if let value = obj[key] as? NSNumber {
            return value.intValue
        }
        return nil
    }

    private func snapshotLiveDatabase(_ path: String) -> String? {
        let fm = FileManager.default
        let src = URL(fileURLWithPath: path)
        let dst = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rtabmap.live-snap.\(UUID().uuidString).db")
        do {
            try fm.copyItem(at: src, to: dst)
            let wal = path + "-wal"
            let shm = path + "-shm"
            if fm.fileExists(atPath: wal) {
                try fm.copyItem(atPath: wal, toPath: dst.path + "-wal")
            }
            if fm.fileExists(atPath: shm) {
                try fm.copyItem(atPath: shm, toPath: dst.path + "-shm")
            }
            NSLog("CollabSync: snapshot %@ -> %@ (wal=%d shm=%d)", path, dst.path, fm.fileExists(atPath: wal) ? 1 : 0, fm.fileExists(atPath: shm) ? 1 : 0)
            return dst.path
        } catch {
            NSLog("CollabSync: snapshot failed: %@", error.localizedDescription)
            removeSnapshot(dst.path)
            return nil
        }
    }

    private func removeSnapshot(_ path: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: path)
        try? fm.removeItem(atPath: path + "-wal")
        try? fm.removeItem(atPath: path + "-shm")
    }
}
