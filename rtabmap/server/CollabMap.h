#ifndef COLLAB_MAP_H
#define COLLAB_MAP_H

#include <rtabmap/core/Transform.h>

#include <atomic>
#include <condition_variable>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace rtabmap {
class Rtabmap;
}

namespace collab {

struct NodeMeshCache;

struct SyncResult
{
	bool ok;
	int accepted;
	int lastLocalId;
	int globalNodes;
	int loopClosures;
	std::string error;
};

struct ClientStatus
{
	std::string id;
	int lastLocalId;
	int nodes;
	long lastSeen;
};

struct ServerStatus
{
	int globalNodes;
	int poses;
	int loopClosures;
	int activeClients;
	std::vector<ClientStatus> clients;
};

struct JoinResult
{
	bool ok;
	std::string mode;
	int activeClients;
	int globalNodes;
	bool mustDownload;
	bool locked;
	bool showTag;
	bool mustWaitForLock;
	int tagId;
	std::string error;

	JoinResult() :
		ok(true),
		activeClients(0),
		globalNodes(0),
		mustDownload(false),
		locked(false),
		showTag(true),
		mustWaitForLock(true),
		tagId(0)
	{}
};

struct CalibrateResult
{
	bool ok;
	bool locked;
	bool showTag;
	int calibratedCount;
	int tagId;
	std::string error;

	CalibrateResult() :
		ok(false),
		locked(false),
		showTag(true),
		calibratedCount(0),
		tagId(0)
	{}
};

struct PullResult
{
	bool ok;
	int maxGlobalId;
	int posesCount;
	int nodesCount;
	int loopClosures;
	bool aligned;
	bool hasTransform;
	float localFromGlobal[7];
	std::string error;

	PullResult() :
		ok(true),
		maxGlobalId(0),
		posesCount(0),
		nodesCount(0),
		loopClosures(0),
		aligned(false),
		hasTransform(false)
	{
		localFromGlobal[0] = localFromGlobal[1] = localFromGlobal[2] = 0.0f;
		localFromGlobal[3] = localFromGlobal[4] = localFromGlobal[5] = 0.0f;
		localFromGlobal[6] = 1.0f;
	}
};

class CollabMap
{
public:
	explicit CollabMap(const std::string & dataDir);
	~CollabMap();

	bool init(std::string & error);

	static const long kActiveTimeoutSec = 45;
	// Temporary: one tagged phone is enough to start mapping. Set back to 2
	// to wait for a second connection before the room locks.
	static const int kLockPhonesRequired = 1;
	// Phones sit on the tag screen before /calibrate. Do not wipe a waiting
	// lock just because mapping heartbeats have not started yet.
	static const long kCalibWaitTimeoutSec = 180;
	// Unused leftover from the Poisson bake. Admin live view does not wait on this.
	static const int kBakeIntervalSec = 0;
	// Ignore graph-node pose updates for this long after a live /pose.
	static const long kLivePoseHoldSec = 2;

	SyncResult ingest(const std::string & clientId, int sinceId, const std::string & uploadDbPath);
	JoinResult join(const std::string & clientId);
	JoinResult heartbeat(const std::string & clientId, const std::string & jsonBody = "");
	JoinResult updateLivePose(const std::string & clientId, const std::string & jsonBody);
	CalibrateResult calibrate(
		const std::string & clientId,
		int tagId,
		bool detected,
		float tx, float ty, float tz,
		float qx, float qy, float qz, float qw);
	CalibrateResult calibrateFromJson(const std::string & clientId, const std::string & jsonBody);
	// Displayed marker width in meters (black square). Returns false if out of range.
	bool setTagSizeM(float meters);
	float tagSizeM() const;
	void resetDemoRoom();
	bool isRoomLocked();
	PullResult exportPull(const std::string & clientId, int sinceGlobalId, const std::string & destDbPath);
	ServerStatus status() const;
	bool lastIngestAligned() const;
	bool optimizeNow(std::string & error);
	// Run the phone-style assemble (Poisson + color/texture + cleanup) now and
	// write the pretty mesh file. Heavy; loads under the db lock, computes outside it.
	bool bakeNow(std::string & error);
	static bool writeDemoDeltaDb(
		const std::string & path,
		int localId,
		float x, float y, float z,
		std::string & error);

	std::string mapDbPath() const {return globalDbPath_;}
	std::string mapPlyPath() const {return plyPath_;}
	std::string mapCloudPath() const {return cloudPath_;}
	std::string mapMeshPath() const {return meshPath_;}
	std::string mapLiveMeshPath() const {return meshPath_;}
	std::string mapBakedMeshPath() const {return bakedMeshPath_;}
	bool hasBakedMesh() const;
	// JPEG atlas for the textured bake (empty path if the last bake had none).
	std::string bakedAtlasPath() const;
	int bakeIntervalSec() const {return 0;}
	int meshGeneration() const;
	// Incremented on room reset. Recordings with this id are the current run
	// and stay out of History until the next reset. Name is address + start time.
	int currentRunId() const;
	std::string currentRunAddress() const;
	long currentRunStarted() const;
	std::string currentRunName() const;
	// First non-empty street address from a phone wins for this run.
	void noteRunAddress(const std::string & address);
	// First valid GPS fix from a phone wins for this run (sidebar site map).
	void noteRunGeo(double lat, double lng);
	double currentRunLat() const;
	double currentRunLng() const;
	// Current plus closed runs (address, timestamps) from runs.json.
	std::string runsJson() const;
	// Binary PLY (same layout as map.mesh) of the cached live node meshes with
	// global id > sinceNode, placed with the latest tag-frame poses. Empty
	// string when nothing is newer.
	std::string liveMeshSince(int sinceNode, int & nodesOut) const;
	// Nodes whose cleaned live mesh has faces (what the live export can place).
	int liveMeshNodeCount() const;
	bool ensureViewerCloud(std::string & error);
	bool exportLiveMeshNow(std::string & error);

	std::string statusJson() const;
	std::string syncJson(const SyncResult & result) const;
	std::string joinJson(const JoinResult & result) const;
	std::string demoJson(const std::string & clientId = "");
	std::string calibrateJson(const CalibrateResult & result) const;

	// Frame conversions (conventions documented next to the constants in
	// CollabMap.cpp). Public and static so collab_frame_test can check them.
	// T_G_from_clientRtabmapWorld from the phone-reported T_arkitWorld_from_tag.
	// The tag frame is leveled first (see levelArkitTagFrame).
	static rtabmap::Transform globalFromClientWorld(const rtabmap::Transform & arkitWorldFromTag);
	// Same tag center and heading, but up taken from ARKit gravity (+y) instead
	// of the tag's up edge, so a leaning laptop screen does not tilt the map.
	static rtabmap::Transform levelArkitTagFrame(const rtabmap::Transform & arkitWorldFromTag);
	// ARKit camera transform (ARKit world, ARKit camera axes) to the rtabmap
	// world / base_link pose the phone stores for that frame.
	static rtabmap::Transform rtabmapPoseFromArkit(const rtabmap::Transform & arkitCamera);
	// The fixed axis rotations themselves.
	static rtabmap::Transform rtabmapWorldFromOpenGL();
	static rtabmap::Transform openGLWorldFromRtabmap();

private:
	struct ClientState
	{
		ClientState() :
			lastLocalId(0),
			nodes(0),
			lastSeen(0),
			mapIdBase(-1),
			sessionMapId(-1),
			calibrated(false),
			detected(false),
			tagId(-1),
			hasTagXf(false),
			poseX(0.0f),
			poseY(0.0f),
			poseZ(0.0f),
			poseQx(0.0f),
			poseQy(0.0f),
			poseQz(0.0f),
			poseQw(1.0f),
			poseYaw(0.0f),
			poseRoll(0.0f),
			posePitch(0.0f),
			lastLivePoseAt(0)
		{
			for(int i = 0; i < 7; ++i)
			{
				odomFromTag[i] = 0.0f;
				tagFromClient[i] = 0.0f;
			}
			odomFromTag[6] = 1.0f;
			tagFromClient[6] = 1.0f;
		}
		int lastLocalId;
		int nodes;
		long lastSeen;
		int mapIdBase;
		int sessionMapId;
		std::map<int, int> localToGlobal;
		bool calibrated;
		bool detected;
		int tagId;
		bool hasTagXf;
		float odomFromTag[7];
		float tagFromClient[7];
		float poseX;
		float poseY;
		float poseZ;
		float poseQx;
		float poseQy;
		float poseQz;
		float poseQw;
		float poseYaw;
		float poseRoll;
		float posePitch;
		long lastLivePoseAt;
		std::vector<std::pair<float, float> > trail;
	};

	bool loadState();
	bool saveState() const;
	void syncIdsFromDatabase();

	bool ingestLocked(const std::string & clientId, int sinceId, const std::string & uploadDbPath, SyncResult & result);
	bool optimizeAndExport(std::string & error);
	// Adds measured start-tag links between locked sessions that are not yet
	// connected in the graph. Returns the number of links accepted. The
	// Locked variant expects mutex_ to be held by the caller.
	int addTagConstraints(rtabmap::Rtabmap & rtabmap);
	int addTagConstraintsLocked(rtabmap::Rtabmap & rtabmap);
	bool exportViewerCloudLocked(std::string & error);
	bool exportLiveMeshLocked(std::string & error);
	void scheduleOptimize();
	void optimizeWorker();
	void scheduleBake();
	void bakeLoop();
	void bakeOnce(bool forced);
	bool bakeAndExport(std::string & error);
	bool parseLivePoseJson(const std::string & jsonBody, float & x, float & y, float & z,
		float & qx, float & qy, float & qz, float & qw) const;
	bool shouldSkipGraphPoseLocked(const ClientState & client, long now) const;
	int countActiveLocked(long now, long timeoutSec) const;
	static bool isActiveSeen(long lastSeen, long now, long timeoutSec);
	void resetRoomLocked();
	// Copy the current baked (or live) mesh into dataDir/models before a wipe.
	// Returns the archived file name, or empty if nothing was copied.
	std::string archiveCurrentModelLocked();
	// Write run_id onto current-run video sidecars so the next increment
	// makes them show up under History > Recordings.
	void stampCurrentRunVideosLocked();
	void stampCurrentRunVideoAddressesLocked();
	bool applyRunAddressLocked(const std::string & raw);
	bool applyRunGeoLocked(double lat, double lng);
	void noteRunAddressFromJsonLocked(const std::string & jsonBody);
	void closeCurrentRunLocked(const std::string & modelName);
	void loadRuns();
	void saveRunsLocked() const;
	std::vector<std::string> currentRunUsersLocked() const;
	std::string runRecordJson(
		int id,
		const std::string & address,
		double lat,
		double lng,
		long started,
		long ended,
		const std::string & model,
		const std::vector<std::string> & users) const;
	void clearSessionCalibrationLocked();
	// Startup: keep recent real calibrations, drop the rest, recompute the lock.
	void restoreSessionLockLocked();
	void expireStaleLockLocked();
	void touchClientLocked(const std::string & clientId, long now);
	void applyLockFieldsLocked(JoinResult & result) const;
	void recomputeLockLocked();
	void applyTagPoseLocked(
		ClientState & client,
		float x, float y, float z,
		float qx, float qy, float qz, float qw,
		bool fromLive = false);
	int countCalibratedLocked() const;
	void alignPosesToTagFrame(std::map<int, rtabmap::Transform> & poses) const;

	static std::string makeDirRecursive(const std::string & path);

private:
	std::string dataDir_;
	std::string globalDbPath_;
	std::string statePath_;
	std::string plyPath_;
	std::string cloudPath_;
	std::string meshPath_;
	std::string bakedMeshPath_;

	int nextGlobalId_;
	int nextMapIdBase_;
	int globalNodes_;
	int poses_;
	int loopClosures_;
	int meshGen_;
	int lastBakedNodes_;
	bool lastIngestAligned_;
	// Cross-map loop closures currently in the graph. When > 0 the optimizer
	// has pulled every session into the root client's frame, so the tag
	// alignment of that one client applies to all nodes.
	int interMapLc_;
	// Background heavy pass (detectMoreLoopClosures + pose refresh) policy:
	// run when no upload arrived for kHeavyIdleSec and at least
	// kHeavyPassMinIntervalSec since the last pass; force one every
	// kHeavyPassMaxIntervalSec during a continuous walk.
	static const long kHeavyIdleSec = 3;
	static const long kHeavyPassMinIntervalSec = 10;
	static const long kHeavyPassMaxIntervalSec = 60;
	long lastHeavyPassAt_;
	long lastIngestAt_;
	// Per-node live meshes in their camera frame, built once per node. The
	// live mesh export only reloads poses and meshes nodes it has not seen.
	NodeMeshCache * meshCache_;
	mutable std::mutex meshCacheMutex_;
	// map.cloud / map.ply are downloads, rebuilt on demand when stale.
	bool cloudStale_;
	// Phone-style assembled ("pretty") mesh: generation counter, highest node
	// id it covers (live meshes newer than this are overlaid), last run time.
	int bakeGen_;
	int bakeMaxNodeId_;
	long lastBakeAt_;
	bool bakeTextured_;
	std::string bakedAtlasPath_;
	// Bumped on every room reset; a bake that started under an older epoch is
	// thrown away instead of resurrecting the previous room's surface.
	int roomEpoch_;
	int runId_;
	std::string runAddress_;
	double runLat_;
	double runLng_;
	long runStarted_;
	struct RunRecord
	{
		int id;
		std::string address;
		double lat;
		double lng;
		long started;
		long ended;
		std::string model;
		std::vector<std::string> users;
	};
	std::vector<RunRecord> pastRuns_;
	std::string runsPath_;
	// Tag-frame poses used by the last live mesh export, so an overlay of
	// "nodes newer than the bake" can be built from the cache without the db.
	std::map<int, rtabmap::Transform> livePosesG_;
	static const long kBakeIdleSec = 5;
	static const long kBakeMinIntervalSec = 60;
	static const long kBakeMaxIntervalSec = 180;
	bool roomLocked_;
	int lockedTagId_;
	// Physical width of the black marker square as displayed by the admin page
	// (meters). Reported to phones in /join, /demo and /calibrate; persisted.
	float tagSizeM_;
	std::map<std::string, ClientState> clients_;

	mutable std::mutex mutex_;
	std::mutex dbMutex_;
	std::atomic<bool> optimizeRunning_;
	std::atomic<bool> optimizeAgain_;
	std::atomic<bool> bakeRunning_;
	std::atomic<bool> bakeAgain_;
	std::atomic<bool> bakeStop_;
	std::mutex bakeMutex_;
	std::condition_variable bakeCv_;
	std::thread bakeThread_;
};

}

#endif
