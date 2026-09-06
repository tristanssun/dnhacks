#include "CollabMap.h"
#include "DemoTag.h"
#include "HttpServer.h"

#include <rtabmap/core/CameraModel.h>
#include <rtabmap/core/DBDriver.h>
#include <rtabmap/core/DBReader.h>
#include <rtabmap/core/EnvSensor.h>
#include <rtabmap/core/GPS.h>
#include <rtabmap/core/Link.h>
#include <rtabmap/core/Memory.h>
#include <rtabmap/core/Optimizer.h>
#include <rtabmap/core/Parameters.h>
#include <rtabmap/core/Rtabmap.h>
#include <rtabmap/core/SensorCaptureInfo.h>
#include <rtabmap/core/SensorData.h>
#include <rtabmap/core/Signature.h>
#include <rtabmap/core/Transform.h>
#include <rtabmap/core/util2d.h>
#include <rtabmap/core/util3d.h>
#include <rtabmap/core/util3d_filtering.h>
#include <rtabmap/core/util3d_surface.h>
#include <rtabmap/core/util3d_transforms.h>
#include <rtabmap/utilite/UConversion.h>
#include <rtabmap/utilite/UDirectory.h>
#include <rtabmap/utilite/UException.h>
#include <rtabmap/utilite/UFile.h>
#include <rtabmap/utilite/ULogger.h>
#include <rtabmap/utilite/UStl.h>

#include <rtabmap/core/impl/util3d_surface.hpp>

#include <pcl/common/common.h>
#include <pcl/common/io.h>
#include <pcl/conversions.h>
#include <pcl/io/ply_io.h>
#include <pcl/point_cloud.h>
#include <pcl/point_types.h>
#include <pcl/surface/poisson.h>
#include <opencv2/imgproc.hpp>
#include <opencv2/imgcodecs.hpp>
#include <Eigen/Geometry>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include <thread>
#include <vector>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace collab {

namespace {

const float kVoxelSize = 0.02f;
const int kCloudDecimation = 8;
const float kCloudMaxDepth = 8.0f;
const uint32_t kCloudMaxPoints = 200000;
const char kCloudMagic[4] = {'C', '3', 'D', '1'};
// Match RTABMapApp live meshing: maxCloudDepth_ 2.5 m, angle 20 deg, 2 px.
// Depth beyond 2.5 m on the phone LiDAR is noisy; meshing it produces the
// flying shards that made the admin view look exploded.
const float kMeshMaxDepth = 2.5f;
const float kMeshAngleToleranceDeg = 20.0f;
const int kMeshTrianglePix = 2;
const uint32_t kMeshMaxFaces = 500000;
// Phone live-view cleanup, applied to every node mesh here. ARKit depth
// confidence: the phone's default is "High" (threshold 100), but at the
// server's budget decimation (8 px) that mask leaves too few valid samples
// per triangle (275k -> 18k faces on a 272-node room); medium+high (50)
// still drops the low-confidence flying pixels at depth edges (275k -> 188k)
// and reads far cleaner. Polygon clusters under 5% of the node's biggest
// cluster are dropped (phone NoiseFilteringRatio 0.05: the confetti).
// Triangles with an edge over 3x the expected vertex spacing at that range
// (decimation * range / fx) are dropped; organizedFastMesh's angle tolerance
// already catches nearly all of these, this is a safety net.
const unsigned char kDepthConfidenceThr = 50;
const float kMeshClusterRatio = 0.05f;
const float kMeshMaxEdgeFactor = 3.0f;

// Frames. The phone stores node poses in rtabmap world convention (x forward,
// y left, z up) and reports the start tag in ARKit/OpenGL world convention
// (x right, y up, z back); the two are related by these fixed rotations, the
// same ones the iOS app uses in postOdometryEvent. The shared demo frame G is
// the tag frame re-expressed in rtabmap convention: origin at the tag center,
// z up along the tag's up edge, x pointing away from the screen (the tag's
// normal points at the viewer, so x runs into the wall behind the monitor).
const rtabmap::Transform kRtabmapWorldFromOpenGL(
	0.0f, 0.0f, -1.0f, 0.0f,
	-1.0f, 0.0f, 0.0f, 0.0f,
	0.0f, 1.0f, 0.0f, 0.0f);
const rtabmap::Transform kOpenGLWorldFromRtabmap(
	0.0f, -1.0f, 0.0f, 0.0f,
	0.0f, 0.0f, 1.0f, 0.0f,
	-1.0f, 0.0f, 0.0f, 0.0f);

// iOS Assemble defaults from Settings.bundle / RTABMapApp::exportMesh (optimized).
// Phone Assemble defaults are voxel 0.01 m and 2.5 m depth. The periodic
// server bake uses 2 cm voxels so a room reconstructs in tens of seconds
// instead of minutes; the phone still does its own 1 cm export at stop.
const float kAssembleVoxel = 0.02f;
const float kAssembleMaxDepth = 2.5f;
const float kAssembleMinDepth = 0.0f;
const int kAssembleDensityLevel = 1;
const int kAssembleNormalK = 18;
const int kAssembleDepth = 0;
const float kAssembleColorRadius = 0.05f;
const bool kAssembleCleanMesh = true;
const int kAssembleMinCluster = 0;
const int kAssembleMaxPolygons = 200000;
const float kAssembleMaxTextureDistance = 3.0f;
// Texturing occlusion test (createTextureMesh maxDepthError). Measured on a
// 272-node room: the phone default (0 = edge length) and a fixed 15 cm both
// texture ~44k of 126k faces, because decimated faces on slanted surfaces span
// more depth than the tolerance; -1 (off) textures 81k. Faces are still only
// textured by cameras they face (winding test), so this trades some
// bleed-through at occluding edges for far better coverage. Small clusters are
// speckle.
const float kAssembleMaxDepthError = -1.0f;
const int kAssembleMinTextureCluster = 10;
// After unseen faces are dropped, textured islands smaller than this many
// polygons are floating specks, not furniture (phone: PolygonFiltering=0 keeps them).
const int kAssembleTextureIslandMin = 20;
// 4096 x 1 atlas like the phone (Settings.bundle TextureSize /
// MaximumOutputTextures); 1024 gave each camera a ~60 px tile, unreadable.
const int kAssembleTextureSize = 4096;
const int kAssembleTextureCount = 1;
const float kBilateralSigmaS = 2.0f;
const float kBilateralSigmaR = 0.075f;

bool isSqliteFile(const std::string & path)
{
	FILE * f = std::fopen(path.c_str(), "rb");
	if(!f)
	{
		return false;
	}
	char magic[16];
	size_t n = std::fread(magic, 1, 16, f);
	std::fclose(f);
	return n >= 16 && std::strncmp(magic, "SQLite format 3", 15) == 0;
}

int countLoopClosures(const std::multimap<int, rtabmap::Link> & links)
{
	std::set<std::pair<int, int> > unique;
	for(std::multimap<int, rtabmap::Link>::const_iterator it = links.begin(); it != links.end(); ++it)
	{
		const rtabmap::Link & link = it->second;
		if(link.type() == rtabmap::Link::kNeighbor ||
		   link.type() == rtabmap::Link::kNeighborMerged ||
		   link.type() == rtabmap::Link::kPosePrior ||
		   link.type() == rtabmap::Link::kGravity ||
		   link.type() == rtabmap::Link::kVirtualClosure ||
		   link.type() == rtabmap::Link::kLandmark)
		{
			continue;
		}
		int a = std::min(link.from(), link.to());
		int b = std::max(link.from(), link.to());
		unique.insert(std::make_pair(a, b));
	}
	return static_cast<int>(unique.size());
}

std::string mapIdsSummary(const rtabmap::Memory * mem)
{
	if(!mem)
	{
		return "";
	}
	std::set<int> ids = mem->getAllSignatureIds(false);
	std::map<int, int> counts;
	for(std::set<int>::const_iterator it = ids.begin(); it != ids.end(); ++it)
	{
		rtabmap::Transform odom;
		int mapId = 0;
		int weight = 0;
		std::string label;
		double stamp = 0;
		rtabmap::Transform gt;
		std::vector<float> vel;
		rtabmap::GPS gps;
		rtabmap::EnvSensors sensors;
		if(mem->getNodeInfo(*it, odom, mapId, weight, label, stamp, gt, vel, gps, sensors, true))
		{
			++counts[mapId];
		}
	}
	std::ostringstream oss;
	bool first = true;
	for(std::map<int, int>::const_iterator it = counts.begin(); it != counts.end(); ++it)
	{
		if(!first)
		{
			oss << ",";
		}
		first = false;
		oss << it->first << ":" << it->second;
	}
	return oss.str();
}

bool nodeInfo(
	const rtabmap::Memory * mem,
	int id,
	rtabmap::Transform & pose,
	int & mapId)
{
	if(!mem || id <= 0)
	{
		return false;
	}
	int weight = 0;
	std::string label;
	double stamp = 0;
	rtabmap::Transform gt;
	std::vector<float> vel;
	rtabmap::GPS gps;
	rtabmap::EnvSensors sensors;
	return mem->getNodeInfo(id, pose, mapId, weight, label, stamp, gt, vel, gps, sensors, true) && !pose.isNull();
}

int memoryLoopClosures(const rtabmap::Memory * mem)
{
	if(!mem)
	{
		return 0;
	}
	return countLoopClosures(mem->getAllLinks(true, true, false));
}

// Real inter-session LC: a non-neighbor, non-user-glue link between two map_ids.
int countInterMapLoops(const rtabmap::Memory * mem)
{
	if(!mem)
	{
		return 0;
	}
	const std::multimap<int, rtabmap::Link> links = mem->getAllLinks(true, true, false);
	std::set<std::pair<int, int> > unique;
	for(std::multimap<int, rtabmap::Link>::const_iterator it = links.begin(); it != links.end(); ++it)
	{
		const rtabmap::Link & link = it->second;
		// kUserClosure counts: detectMoreLoopClosures records its finds with
		// that type, and so does the measured start-tag constraint below.
		if(link.type() == rtabmap::Link::kNeighbor ||
		   link.type() == rtabmap::Link::kNeighborMerged ||
		   link.type() == rtabmap::Link::kPosePrior ||
		   link.type() == rtabmap::Link::kGravity ||
		   link.type() == rtabmap::Link::kVirtualClosure ||
		   link.type() == rtabmap::Link::kLandmark)
		{
			continue;
		}
		rtabmap::Transform a;
		rtabmap::Transform b;
		int fromMap = -1;
		int toMap = -1;
		if(!nodeInfo(mem, link.from(), a, fromMap) || !nodeInfo(mem, link.to(), b, toMap))
		{
			continue;
		}
		if(fromMap < 0 || toMap < 0 || fromMap == toMap)
		{
			continue;
		}
		int lo = std::min(link.from(), link.to());
		int hi = std::max(link.from(), link.to());
		unique.insert(std::make_pair(lo, hi));
	}
	return static_cast<int>(unique.size());
}

int countInterMapLoopsFromIds(
	const std::multimap<int, rtabmap::Link> & links,
	const std::map<int, int> & nodeMapId)
{
	std::set<std::pair<int, int> > unique;
	for(std::multimap<int, rtabmap::Link>::const_iterator it = links.begin(); it != links.end(); ++it)
	{
		const rtabmap::Link & link = it->second;
		if(link.type() == rtabmap::Link::kNeighbor ||
		   link.type() == rtabmap::Link::kNeighborMerged ||
		   link.type() == rtabmap::Link::kPosePrior ||
		   link.type() == rtabmap::Link::kGravity ||
		   link.type() == rtabmap::Link::kVirtualClosure ||
		   link.type() == rtabmap::Link::kLandmark)
		{
			continue;
		}
		std::map<int, int>::const_iterator fm = nodeMapId.find(link.from());
		std::map<int, int>::const_iterator tm = nodeMapId.find(link.to());
		if(fm == nodeMapId.end() || tm == nodeMapId.end() || fm->second == tm->second)
		{
			continue;
		}
		int lo = std::min(link.from(), link.to());
		int hi = std::max(link.from(), link.to());
		unique.insert(std::make_pair(lo, hi));
	}
	return static_cast<int>(unique.size());
}

int keepLoopClosures(int previousLc, int memoryLc)
{
	if(memoryLc > 0)
	{
		return memoryLc;
	}
	if(previousLc > 0)
	{
		UWARN("Keeping previous loop_closures=%d (graph currently reports 0)", previousLc);
		return previousLc;
	}
	return 0;
}

bool alreadyNeighbor(const rtabmap::Memory * mem, int fromId, int toId)
{
	if(!mem || fromId <= 0 || toId <= 0 || fromId == toId)
	{
		return false;
	}
	std::multimap<int, rtabmap::Link> links = mem->getAllLinks(true, true, false);
	for(std::multimap<int, rtabmap::Link>::const_iterator it = links.begin(); it != links.end(); ++it)
	{
		if(it->second.type() != rtabmap::Link::kNeighbor &&
		   it->second.type() != rtabmap::Link::kNeighborMerged)
		{
			continue;
		}
		const int a = it->second.from();
		const int b = it->second.to();
		if((a == fromId && b == toId) || (a == toId && b == fromId))
		{
			return true;
		}
	}
	return false;
}

int reconnectClientChain(rtabmap::Rtabmap & rtabmap, int fromId, int toId)
{
	if(fromId <= 0 || toId <= 0 || fromId == toId)
	{
		return 0;
	}
	const rtabmap::Memory * mem = rtabmap.getMemory();
	if(alreadyNeighbor(mem, fromId, toId))
	{
		UINFO("Client chain %d -> %d already has a neighbor link", fromId, toId);
		return 1;
	}
	rtabmap::Transform fromPose;
	rtabmap::Transform toPose;
	int fromMap = 0;
	int toMap = 0;
	cv::Mat inf = cv::Mat::eye(6, 6, CV_64FC1) * 10.0;
	rtabmap::Transform rel;
	if(nodeInfo(mem, fromId, fromPose, fromMap) && nodeInfo(mem, toId, toPose, toMap))
	{
		rel = fromPose.inverse() * toPose;
	}
	if(rel.isNull())
	{
		rel = rtabmap::Transform::getIdentity();
		inf = cv::Mat::eye(6, 6, CV_64FC1) * 0.01;
		UWARN("No odom-consistent pose for %d -> %d, using identity with high variance", fromId, toId);
	}
	rtabmap::Link link(fromId, toId, rtabmap::Link::kNeighbor, rel, inf);
	if(!rtabmap.addNeighborLink(link))
	{
		UWARN("addNeighborLink failed for client chain %d -> %d", fromId, toId);
		return 0;
	}
	UINFO("Neighbor continuation %d -> %d (same client, map %d -> %d)", fromId, toId, fromMap, toMap);
	return 1;
}

void fillMissingOdomPoses(const rtabmap::Memory * mem, std::map<int, rtabmap::Transform> & poses)
{
	if(!mem)
	{
		return;
	}
	std::set<int> ids = mem->getAllSignatureIds(false);
	for(std::set<int>::const_iterator it = ids.begin(); it != ids.end(); ++it)
	{
		if(poses.find(*it) != poses.end())
		{
			continue;
		}
		rtabmap::Transform pose;
		int mapId = 0;
		if(nodeInfo(mem, *it, pose, mapId))
		{
			poses[*it] = pose;
		}
	}
}

// Rtabmap::close(true) writes _optimizedPoses, which is often only the last
// connected component. Write the full pose map after close so pull/export
// keep every node.
bool persistOptimizedPoses(const std::string & dbPath, const std::map<int, rtabmap::Transform> & poses)
{
	if(dbPath.empty() || poses.empty() || !UFile::exists(dbPath))
	{
		return false;
	}
	rtabmap::DBDriver * db = rtabmap::DBDriver::create();
	if(!db->openConnection(dbPath, false, false))
	{
		delete db;
		return false;
	}
	db->saveOptimizedPoses(poses, rtabmap::Transform());
	db->closeConnection(true);
	delete db;
	return true;
}

// Minimal JSON reader for clients.json (object/array/number/string/bool/null).
struct JsonValue
{
	enum Type {kNull, kBool, kNumber, kString, kArray, kObject} type;
	bool b;
	double n;
	std::string s;
	std::vector<JsonValue> a;
	std::map<std::string, JsonValue> o;

	JsonValue() : type(kNull), b(false), n(0.0) {}
	bool has(const std::string & key) const {return type == kObject && o.find(key) != o.end();}
	const JsonValue * get(const std::string & key) const
	{
		std::map<std::string, JsonValue>::const_iterator it = o.find(key);
		return it == o.end() ? 0 : &it->second;
	}
	int asInt(int def = 0) const
	{
		if(type == kNumber) return static_cast<int>(n);
		if(type == kString) return uStr2Int(s);
		return def;
	}
	double asDouble(double def = 0.0) const
	{
		if(type == kNumber) return n;
		if(type == kString) return std::strtod(s.c_str(), 0);
		return def;
	}
	long asLong(long def = 0) const
	{
		if(type == kNumber) return static_cast<long>(n);
		if(type == kString) return std::strtol(s.c_str(), 0, 10);
		return def;
	}
	std::string asString() const {return type == kString ? s : std::string();}
};

class JsonParser
{
public:
	explicit JsonParser(const std::string & text) : text_(text), i_(0) {}

	bool parse(JsonValue & out)
	{
		skip();
		return parseValue(out) && true;
	}

private:
	void skip()
	{
		while(i_ < text_.size() && (text_[i_] == ' ' || text_[i_] == '\n' || text_[i_] == '\r' || text_[i_] == '\t'))
		{
			++i_;
		}
	}
	bool parseValue(JsonValue & out)
	{
		skip();
		if(i_ >= text_.size()) return false;
		char c = text_[i_];
		if(c == '{') return parseObject(out);
		if(c == '[') return parseArray(out);
		if(c == '"') return parseString(out);
		if(c == 't' || c == 'f') return parseBool(out);
		if(c == 'n') return parseNull(out);
		return parseNumber(out);
	}
	bool parseObject(JsonValue & out)
	{
		out.type = JsonValue::kObject;
		++i_;
		skip();
		if(i_ < text_.size() && text_[i_] == '}')
		{
			++i_;
			return true;
		}
		while(i_ < text_.size())
		{
			JsonValue key;
			if(!parseString(key)) return false;
			skip();
			if(i_ >= text_.size() || text_[i_] != ':') return false;
			++i_;
			JsonValue val;
			if(!parseValue(val)) return false;
			out.o[key.s] = val;
			skip();
			if(i_ >= text_.size()) return false;
			if(text_[i_] == ',')
			{
				++i_;
				skip();
				continue;
			}
			if(text_[i_] == '}')
			{
				++i_;
				return true;
			}
			return false;
		}
		return false;
	}
	bool parseArray(JsonValue & out)
	{
		out.type = JsonValue::kArray;
		++i_;
		skip();
		if(i_ < text_.size() && text_[i_] == ']')
		{
			++i_;
			return true;
		}
		while(i_ < text_.size())
		{
			JsonValue val;
			if(!parseValue(val)) return false;
			out.a.push_back(val);
			skip();
			if(i_ >= text_.size()) return false;
			if(text_[i_] == ',')
			{
				++i_;
				skip();
				continue;
			}
			if(text_[i_] == ']')
			{
				++i_;
				return true;
			}
			return false;
		}
		return false;
	}
	bool parseString(JsonValue & out)
	{
		skip();
		if(i_ >= text_.size() || text_[i_] != '"') return false;
		++i_;
		out.type = JsonValue::kString;
		out.s.clear();
		while(i_ < text_.size())
		{
			char c = text_[i_++];
			if(c == '"') return true;
			if(c == '\\' && i_ < text_.size())
			{
				char e = text_[i_++];
				if(e == 'n') out.s.push_back('\n');
				else if(e == 'r') out.s.push_back('\r');
				else if(e == 't') out.s.push_back('\t');
				else out.s.push_back(e);
			}
			else
			{
				out.s.push_back(c);
			}
		}
		return false;
	}
	bool parseNumber(JsonValue & out)
	{
		skip();
		size_t start = i_;
		if(i_ < text_.size() && (text_[i_] == '-' || text_[i_] == '+')) ++i_;
		while(i_ < text_.size() && ((text_[i_] >= '0' && text_[i_] <= '9') || text_[i_] == '.' || text_[i_] == 'e' || text_[i_] == 'E' || text_[i_] == '+' || text_[i_] == '-'))
		{
			++i_;
		}
		if(start == i_) return false;
		out.type = JsonValue::kNumber;
		out.n = std::strtod(text_.substr(start, i_ - start).c_str(), 0);
		return true;
	}
	bool parseBool(JsonValue & out)
	{
		if(text_.compare(i_, 4, "true") == 0)
		{
			out.type = JsonValue::kBool;
			out.b = true;
			i_ += 4;
			return true;
		}
		if(text_.compare(i_, 5, "false") == 0)
		{
			out.type = JsonValue::kBool;
			out.b = false;
			i_ += 5;
			return true;
		}
		return false;
	}
	bool parseNull(JsonValue & out)
	{
		if(text_.compare(i_, 4, "null") == 0)
		{
			out.type = JsonValue::kNull;
			i_ += 4;
			return true;
		}
		return false;
	}

	std::string text_;
	size_t i_;
};

std::string readFile(const std::string & path)
{
	std::ifstream in(path.c_str(), std::ios::in | std::ios::binary);
	if(!in)
	{
		return "";
	}
	std::ostringstream ss;
	ss << in.rdbuf();
	return ss.str();
}

bool writeFileAtomic(const std::string & path, const std::string & contents)
{
	std::string tmp = path + ".tmp";
	std::ofstream out(tmp.c_str(), std::ios::out | std::ios::binary | std::ios::trunc);
	if(!out)
	{
		return false;
	}
	out << contents;
	out.close();
	if(!out)
	{
		UFile::erase(tmp);
		return false;
	}
	UFile::erase(path);
	return UFile::rename(tmp, path) == 0;
}

pcl::PointCloud<pcl::PointXYZRGB>::Ptr nodeCloudRGB(rtabmap::SensorData & data)
{
	data.uncompressData();
	pcl::PointCloud<pcl::PointXYZRGB>::Ptr cloud = rtabmap::util3d::cloudRGBFromSensorData(
		data, kCloudDecimation, kCloudMaxDepth);
	if((!cloud || cloud->empty()) &&
	   (!data.laserScanRaw().isEmpty() || !data.laserScanCompressed().isEmpty()))
	{
		if(data.laserScanRaw().isEmpty())
		{
			data.uncompressData();
		}
		cloud = rtabmap::util3d::laserScanToPointCloudRGB(data.laserScanRaw(), rtabmap::Transform());
	}
	if(!cloud || cloud->empty())
	{
		return pcl::PointCloud<pcl::PointXYZRGB>::Ptr();
	}
	// RGB-D clouds are organized and not dense. voxelize() rejects those and
	// returns an empty cloud, which then makes savePLYFileBinary fail.
	cloud = rtabmap::util3d::removeNaNFromPointCloud(cloud);
	if(!cloud || cloud->empty())
	{
		return pcl::PointCloud<pcl::PointXYZRGB>::Ptr();
	}
	cloud->is_dense = true;
	cloud->width = static_cast<uint32_t>(cloud->size());
	cloud->height = 1;
	return cloud;
}

pcl::PointCloud<pcl::PointXYZRGB>::Ptr assembleMapCloud(
	const std::map<int, rtabmap::Transform> & poses,
	std::map<int, rtabmap::Signature> & signatures)
{
	pcl::PointCloud<pcl::PointXYZRGB>::Ptr assembled(new pcl::PointCloud<pcl::PointXYZRGB>);
	assembled->is_dense = true;
	for(std::map<int, rtabmap::Transform>::const_iterator it = poses.begin(); it != poses.end(); ++it)
	{
		if(it->first <= 0)
		{
			continue;
		}
		std::map<int, rtabmap::Signature>::iterator sit = signatures.find(it->first);
		if(sit == signatures.end())
		{
			continue;
		}
		pcl::PointCloud<pcl::PointXYZRGB>::Ptr cloud = nodeCloudRGB(sit->second.sensorData());
		if(!cloud || cloud->empty())
		{
			continue;
		}
		cloud = rtabmap::util3d::transformPointCloud(cloud, it->second);
		*assembled += *cloud;
	}
	if(assembled->empty())
	{
		return assembled;
	}
	assembled->is_dense = true;
	assembled->width = static_cast<uint32_t>(assembled->size());
	assembled->height = 1;
	assembled = rtabmap::util3d::voxelize(assembled, kVoxelSize);
	if(assembled && !assembled->empty())
	{
		assembled->is_dense = true;
		assembled->width = static_cast<uint32_t>(assembled->size());
		assembled->height = 1;
	}
	return assembled;
}

int meshDecimationForSize(int width, int height)
{
	if(width <= 1 || height <= 1)
	{
		return 1;
	}
	const int candidates[] = {4, 2, 5, 8, 10, 3, 1};
	for(size_t i = 0; i < sizeof(candidates)/sizeof(candidates[0]); ++i)
	{
		const int d = candidates[i];
		if((width % d) == 0 && (height % d) == 0)
		{
			return d;
		}
	}
	return 1;
}

// Pick the finest decimation that keeps every node under the face budget.
// A live demo must show the whole room (newest scans included); per-node
// detail is what gives way, not coverage. Starts at the phone-like value from
// meshDecimationForSize and coarsens through exact divisors of both dims.
int meshDecimationForBudget(int width, int height, int nodeCount, uint32_t maxFaces)
{
	int d = meshDecimationForSize(width, height);
	if(width <= 1 || height <= 1 || nodeCount <= 0)
	{
		return d;
	}
	for(;;)
	{
		const double cols = static_cast<double>(width / d);
		const double rows = static_cast<double>(height / d);
		// organizedFastMesh yields at most 2 triangles per cell; ~70% survive
		// depth holes and the angle tolerance in practice.
		const double estFaces = nodeCount * 2.0 * std::max(0.0, cols - 1.0) * std::max(0.0, rows - 1.0) * 0.7;
		if(estFaces <= static_cast<double>(maxFaces))
		{
			return d;
		}
		int next = 0;
		for(int cand = d + 1; cand <= std::min(width, height); ++cand)
		{
			if((width % cand) == 0 && (height % cand) == 0)
			{
				next = cand;
				break;
			}
		}
		if(next == 0 || width / next < 4 || height / next < 4)
		{
			return d;
		}
		d = next;
	}
}

// Same rules as RTABMapApp::updateMeshDecimation for PointCloudDensity=High (1).
int meshDecimationDensity(int width, int height, int densityLevel)
{
	int meshDecimation = 1;
	if(width <= 1 || height <= 1)
	{
		return 1;
	}
	if(densityLevel == 3)
	{
		if((height >= 480 || width >= 480) && width % 20 == 0 && height % 20 == 0)
		{
			meshDecimation = 20;
		}
		else if(width % 15 == 0 && height % 15 == 0)
		{
			meshDecimation = 15;
		}
		else if(width % 10 == 0 && height % 10 == 0)
		{
			meshDecimation = 10;
		}
		else if(width % 8 == 0 && height % 8 == 0)
		{
			meshDecimation = 8;
		}
	}
	else if(densityLevel == 2)
	{
		if((height >= 480 || width >= 480) && width % 10 == 0 && height % 10 == 0)
		{
			meshDecimation = 10;
		}
		else if(width % 5 == 0 && height % 5 == 0)
		{
			meshDecimation = 5;
		}
		else if(width % 4 == 0 && height % 4 == 0)
		{
			meshDecimation = 4;
		}
	}
	else if(densityLevel == 1)
	{
		if((height >= 480 || width >= 480) && width % 5 == 0 && height % 5 == 0)
		{
			meshDecimation = 5;
		}
		else if(width % 3 == 0 && height % 3 == 0)
		{
			meshDecimation = 3;
		}
		else if(width % 2 == 0 && height % 2 == 0)
		{
			meshDecimation = 2;
		}
	}
	return meshDecimation;
}

void applyTagFrameToPoses(
	const std::map<int, rtabmap::Transform> & nodeTagFromClient,
	std::map<int, rtabmap::Transform> & poses)
{
	if(nodeTagFromClient.empty())
	{
		return;
	}
	int aligned = 0;
	for(std::map<int, rtabmap::Transform>::iterator it = poses.begin(); it != poses.end(); ++it)
	{
		std::map<int, rtabmap::Transform>::const_iterator xf = nodeTagFromClient.find(it->first);
		if(xf == nodeTagFromClient.end() || xf->second.isNull() || it->second.isNull())
		{
			continue;
		}
		rtabmap::Transform world = xf->second * it->second;
		if(!world.isNull())
		{
			it->second = world;
			++aligned;
		}
	}
	UINFO("Tag-frame align applied to %d / %d poses", aligned, (int)poses.size());
}


pcl::PointCloud<pcl::PointXYZRGB>::Ptr nodeOrganizedCloudRGB(rtabmap::SensorData & data, int nodeCount = 0, int * decimationOut = 0)
{
	data.uncompressData();
	if(data.imageRaw().empty() || data.depthRaw().empty())
	{
		return pcl::PointCloud<pcl::PointXYZRGB>::Ptr();
	}
	const int decimation = nodeCount > 0 ?
		meshDecimationForBudget(data.depthRaw().cols, data.depthRaw().rows, nodeCount, kMeshMaxFaces) :
		meshDecimationForSize(data.depthRaw().cols, data.depthRaw().rows);
	if(decimationOut)
	{
		*decimationOut = decimation;
	}
	// Same mask as the phone (DepthConfidence "High" -> threshold 100): LiDAR
	// pixels ARKit marks low/medium confidence are the flying points at
	// depth edges. Nodes without a confidence image keep every pixel.
	pcl::PointCloud<pcl::PointXYZRGB>::Ptr cloud = rtabmap::util3d::cloudRGBFromSensorData(
		data, decimation, kMeshMaxDepth, 0.0f, 0, rtabmap::ParametersMap(), std::vector<float>(),
		kDepthConfidenceThr);
	if(!cloud || cloud->empty())
	{
		return pcl::PointCloud<pcl::PointXYZRGB>::Ptr();
	}
	if(!cloud->isOrganized() || cloud->width <= 1 || cloud->height <= 1)
	{
		return pcl::PointCloud<pcl::PointXYZRGB>::Ptr();
	}
	cloud->is_dense = false;
	return cloud;
}

// Cleanup the phone applies to each node mesh (RTABMapApp::filterOrganizedPolygons
// with NoiseFilteringRatio 0.05), plus a depth-edge test: organizedFastMesh
// still emits long triangles that bridge a depth discontinuity; at the
// decimated resolution a legit edge is about decimation * z / fx, so anything
// several times longer is a bridge, not a surface.
void filterNodePolygons(
	const pcl::PointCloud<pcl::PointXYZRGB> & cloud,
	std::vector<pcl::Vertices> & polygons,
	float depthFx,
	int decimation)
{
	if(polygons.empty())
	{
		return;
	}
	if(depthFx > 0.0f && decimation > 0)
	{
		std::vector<pcl::Vertices> kept;
		kept.reserve(polygons.size());
		const float k = kMeshMaxEdgeFactor * float(decimation) / depthFx;
		for(size_t i = 0; i < polygons.size(); ++i)
		{
			const pcl::Vertices & poly = polygons[i];
			if(poly.vertices.size() < 3)
			{
				continue;
			}
			bool ok = true;
			for(size_t j = 0; j < poly.vertices.size() && ok; ++j)
			{
				const uint32_t a = poly.vertices[j];
				const uint32_t b = poly.vertices[(j + 1) % poly.vertices.size()];
				if(a >= cloud.size() || b >= cloud.size())
				{
					ok = false;
					break;
				}
				const pcl::PointXYZRGB & pa = cloud[a];
				const pcl::PointXYZRGB & pb = cloud[b];
				if(!pcl::isFinite(pa) || !pcl::isFinite(pb))
				{
					ok = false;
					break;
				}
				// The cloud is in the sensor base frame (x forward, z up), so the
				// range to the camera is the point norm, not z.
				const float ra = std::sqrt(pa.x * pa.x + pa.y * pa.y + pa.z * pa.z);
				const float rb = std::sqrt(pb.x * pb.x + pb.y * pb.y + pb.z * pb.z);
				const float dx = pa.x - pb.x;
				const float dy = pa.y - pb.y;
				const float dz = pa.z - pb.z;
				const float edge2 = dx * dx + dy * dy + dz * dz;
				// allowed edge at this range (use the farther endpoint)
				const float allowed = k * std::max(ra, rb);
				if(edge2 > allowed * allowed)
				{
					ok = false;
				}
			}
			if(ok)
			{
				kept.push_back(poly);
			}
		}
		polygons.swap(kept);
	}
	if(kMeshClusterRatio > 0.0f && !polygons.empty())
	{
		std::vector<std::set<int> > neighbors;
		std::vector<std::set<int> > vertexToPolygons;
		rtabmap::util3d::createPolygonIndexes(polygons, static_cast<int>(cloud.size()), neighbors, vertexToPolygons);
		std::list<std::list<int> > clusters = rtabmap::util3d::clusterPolygons(neighbors);
		size_t biggest = 0;
		for(std::list<std::list<int> >::const_iterator it = clusters.begin(); it != clusters.end(); ++it)
		{
			biggest = std::max(biggest, it->size());
		}
		const size_t minCluster = static_cast<size_t>(float(biggest) * kMeshClusterRatio);
		std::vector<pcl::Vertices> kept;
		kept.reserve(polygons.size());
		for(std::list<std::list<int> >::const_iterator it = clusters.begin(); it != clusters.end(); ++it)
		{
			if(it->size() >= minCluster)
			{
				for(std::list<int>::const_iterator j = it->begin(); j != it->end(); ++j)
				{
					kept.push_back(polygons[*j]);
				}
			}
		}
		polygons.swap(kept);
	}
}

float depthImageFx(const rtabmap::SensorData & data)
{
	if(data.cameraModels().size() != 1 || data.depthRaw().empty())
	{
		return 0.0f;
	}
	const rtabmap::CameraModel & m = data.cameraModels()[0];
	if(m.imageWidth() <= 0)
	{
		return static_cast<float>(m.fx());
	}
	return static_cast<float>(m.fx()) * float(data.depthRaw().cols) / float(m.imageWidth());
}

template<typename PointT>
void flattenUnorganized(pcl::PointCloud<PointT> & cloud)
{
	cloud.is_dense = true;
	cloud.width = static_cast<uint32_t>(cloud.size());
	cloud.height = 1;
}

// One keyframe meshed in its own camera frame (untransformed), so it can be
// cached and re-placed whenever poses change. Same recipe as the phone.
bool buildNodeMesh(
	rtabmap::SensorData & data,
	int nodeCount,
	pcl::PointCloud<pcl::PointXYZRGB> & outCloud,
	std::vector<pcl::Vertices> & outPolygons)
{
	outCloud.clear();
	outPolygons.clear();
	int decimation = 0;
	pcl::PointCloud<pcl::PointXYZRGB>::Ptr cloud = nodeOrganizedCloudRGB(data, nodeCount, &decimation);
	if(!cloud || !cloud->isOrganized())
	{
		return false;
	}
	const double angleRad = kMeshAngleToleranceDeg * M_PI / 180.0;
	std::vector<pcl::Vertices> polygons = rtabmap::util3d::organizedFastMesh(
		cloud, angleRad, false, kMeshTrianglePix);
	if(polygons.empty())
	{
		return false;
	}
	filterNodePolygons(*cloud, polygons, depthImageFx(data), decimation);
	if(polygons.empty())
	{
		return false;
	}
	rtabmap::util3d::filterNotUsedVerticesFromMesh(*cloud, polygons, outCloud, outPolygons);
	if(outCloud.empty() || outPolygons.empty())
	{
		outCloud.clear();
		outPolygons.clear();
		return false;
	}
	flattenUnorganized(outCloud);
	return true;
}

void assembleMapMesh(
	const std::map<int, rtabmap::Transform> & poses,
	std::map<int, rtabmap::Signature> & signatures,
	pcl::PointCloud<pcl::PointXYZRGB> & outCloud,
	std::vector<pcl::Vertices> & outPolygons)
{
	outCloud.clear();
	outPolygons.clear();
	flattenUnorganized(outCloud);
	const double angleRad = kMeshAngleToleranceDeg * M_PI / 180.0;
	int meshedNodes = 0;
	int nodeCount = 0;
	for(std::map<int, rtabmap::Transform>::const_iterator it = poses.begin(); it != poses.end(); ++it)
	{
		if(it->first > 0 && signatures.find(it->first) != signatures.end())
		{
			++nodeCount;
		}
	}
	int decimationUsed = 0;
	for(std::map<int, rtabmap::Transform>::const_iterator it = poses.begin(); it != poses.end(); ++it)
	{
		if(it->first <= 0)
		{
			continue;
		}
		std::map<int, rtabmap::Signature>::iterator sit = signatures.find(it->first);
		if(sit == signatures.end())
		{
			continue;
		}
		if(decimationUsed == 0)
		{
			sit->second.sensorData().uncompressData();
			const cv::Mat & depth = sit->second.sensorData().depthRaw();
			if(!depth.empty())
			{
				decimationUsed = meshDecimationForBudget(depth.cols, depth.rows, nodeCount, kMeshMaxFaces);
			}
		}
		int nodeDecimation = 0;
		pcl::PointCloud<pcl::PointXYZRGB>::Ptr cloud = nodeOrganizedCloudRGB(sit->second.sensorData(), nodeCount, &nodeDecimation);
		if(!cloud || !cloud->isOrganized())
		{
			continue;
		}
		std::vector<pcl::Vertices> polygons = rtabmap::util3d::organizedFastMesh(
			cloud, angleRad, false, kMeshTrianglePix);
		if(polygons.empty())
		{
			continue;
		}
		filterNodePolygons(*cloud, polygons, depthImageFx(sit->second.sensorData()), nodeDecimation);
		if(polygons.empty())
		{
			continue;
		}
		pcl::PointCloud<pcl::PointXYZRGB> compact;
		std::vector<pcl::Vertices> compactPolygons;
		rtabmap::util3d::filterNotUsedVerticesFromMesh(*cloud, polygons, compact, compactPolygons);
		if(compact.empty() || compactPolygons.empty())
		{
			continue;
		}
		flattenUnorganized(compact);
		pcl::PointCloud<pcl::PointXYZRGB>::Ptr compactPtr(new pcl::PointCloud<pcl::PointXYZRGB>(compact));
		compactPtr = rtabmap::util3d::transformPointCloud(compactPtr, it->second);
		if(!compactPtr || compactPtr->empty())
		{
			continue;
		}
		flattenUnorganized(*compactPtr);
		if(outPolygons.size() + compactPolygons.size() > kMeshMaxFaces)
		{
			UWARN("Live mesh hit face cap %u, skipping remaining nodes", kMeshMaxFaces);
			break;
		}
		rtabmap::util3d::appendMesh(outCloud, outPolygons, *compactPtr, compactPolygons);
		++meshedNodes;
	}
	flattenUnorganized(outCloud);
	UINFO("Assembled live mesh nodes=%d/%d decimation=%d verts=%d faces=%d",
		meshedNodes, nodeCount, decimationUsed, (int)outCloud.size(), (int)outPolygons.size());
}

uint32_t triangleCount(const std::vector<pcl::Vertices> & polygons)
{
	uint32_t n = 0;
	for(size_t i = 0; i < polygons.size(); ++i)
	{
		const size_t v = polygons[i].vertices.size();
		if(v >= 3)
		{
			n += static_cast<uint32_t>(v - 2);
		}
	}
	return n;
}

bool plyFileHasFaces(const std::string & path)
{
	if(path.empty() || !UFile::exists(path) || UFile::length(path) < 80)
	{
		return false;
	}
	std::ifstream in(path.c_str());
	std::string line;
	while(std::getline(in, line))
	{
		if(line.compare(0, 13, "element face ") == 0)
		{
			return uStr2Int(line.substr(13)) > 0;
		}
		if(line.compare(0, 10, "end_header") == 0)
		{
			break;
		}
	}
	return false;
}


void extractRgbMesh(
	const pcl::PolygonMesh::Ptr & mesh,
	pcl::PointCloud<pcl::PointXYZRGB> & outCloud,
	std::vector<pcl::Vertices> & outPolygons)
{
	outCloud.clear();
	outPolygons.clear();
	if(!mesh || mesh->polygons.empty())
	{
		return;
	}
	pcl::fromPCLPointCloud2(mesh->cloud, outCloud);
	outPolygons = mesh->polygons;
	if(outCloud.empty())
	{
		outPolygons.clear();
		return;
	}
	pcl::PointCloud<pcl::PointXYZRGB> compact;
	std::vector<pcl::Vertices> compactPolygons;
	rtabmap::util3d::filterNotUsedVerticesFromMesh(outCloud, outPolygons, compact, compactPolygons);
	if(!compact.empty() && !compactPolygons.empty())
	{
		outCloud.swap(compact);
		outPolygons.swap(compactPolygons);
	}
	flattenUnorganized(outCloud);
}

void sampleAtlasOntoCloud(
	const pcl::TextureMesh & textureMesh,
	const cv::Mat & atlas,
	pcl::PointCloud<pcl::PointXYZRGB> & cloud)
{
	if(atlas.empty() || cloud.empty() || textureMesh.tex_polygons.empty())
	{
		return;
	}
	cv::Mat bgr;
	if(atlas.channels() == 1)
	{
		cv::cvtColor(atlas, bgr, cv::COLOR_GRAY2BGR);
	}
	else if(atlas.channels() == 4)
	{
		cv::cvtColor(atlas, bgr, cv::COLOR_BGRA2BGR);
	}
	else
	{
		bgr = atlas;
	}
	const int tileH = bgr.rows;
	const int tileW = (textureMesh.tex_polygons.size() > 0)
		? std::max(1, bgr.cols / (int)textureMesh.tex_polygons.size())
		: bgr.cols;
	if(tileH <= 0 || tileW <= 0)
	{
		return;
	}
	for(size_t t = 0; t < textureMesh.tex_polygons.size(); ++t)
	{
		if(t >= textureMesh.tex_coordinates.size())
		{
			continue;
		}
		const std::vector<pcl::Vertices> & polys = textureMesh.tex_polygons[t];
		const auto & uvs = textureMesh.tex_coordinates[t];
		const int xoff = (int)t * tileW;
		size_t uvIndex = 0;
		for(size_t p = 0; p < polys.size(); ++p)
		{
			const pcl::Vertices & poly = polys[p];
			for(size_t k = 0; k < poly.vertices.size(); ++k, ++uvIndex)
			{
				if(uvIndex >= uvs.size())
				{
					break;
				}
				const int vi = static_cast<int>(poly.vertices[k]);
				if(vi < 0 || vi >= (int)cloud.size())
				{
					continue;
				}
				const float u = uvs[uvIndex][0];
				const float v = uvs[uvIndex][1];
				int x = xoff + std::max(0, std::min(tileW - 1, (int)std::floor(u * float(tileW))));
				int y = std::max(0, std::min(tileH - 1, (int)std::floor((1.0f - v) * float(tileH))));
				x = std::max(0, std::min(bgr.cols - 1, x));
				const cv::Vec3b pix = bgr.at<cv::Vec3b>(y, x);
				cloud[vi].b = pix[0];
				cloud[vi].g = pix[1];
				cloud[vi].r = pix[2];
			}
		}
	}
}

// Textured form of the bake: vertices carry an atlas UV (welded per vertex+UV,
// so a vertex on a texture seam is split), plus the merged atlas image (BGR).
struct TexturedBake
{
	pcl::PointCloud<pcl::PointXYZRGB> cloud;
	std::vector<float> uv; // 2 per vertex, atlas-wide [0,1], v up (PLY/OBJ convention)
	std::vector<pcl::Vertices> polygons;
	cv::Mat atlasBgr;
};

// Unweld a PCL TextureMesh (per-face UVs in per-material tiles) into per-vertex
// UVs over the whole atlas. Polygons without valid UVs are dropped, like the
// phone's CleanMesh export.
void buildTexturedBake(
	const pcl::TextureMesh & textureMesh,
	const pcl::PointCloud<pcl::PointXYZRGB> & cloud,
	const cv::Mat & atlas,
	TexturedBake & out)
{
	out.cloud.clear();
	out.uv.clear();
	out.polygons.clear();
	if(atlas.empty() || textureMesh.tex_polygons.empty())
	{
		return;
	}
	cv::Mat bgr;
	if(atlas.channels() == 1)
	{
		cv::cvtColor(atlas, bgr, cv::COLOR_GRAY2BGR);
	}
	else if(atlas.channels() == 4)
	{
		cv::cvtColor(atlas, bgr, cv::COLOR_BGRA2BGR);
	}
	else
	{
		bgr = atlas;
	}
	out.atlasBgr = bgr;
	const int tiles = std::max(1, bgr.cols / std::max(1, bgr.rows));
	std::map<std::pair<int, std::pair<int, int> >, uint32_t> welded;
	size_t rejectedUv = 0;
	size_t rejectedIndex = 0;
	size_t skippedMaterials = 0;
	for(size_t t = 0; t < textureMesh.tex_polygons.size(); ++t)
	{
		if((int)t >= tiles)
		{
			skippedMaterials += textureMesh.tex_polygons[t].size();
			continue;
		}
		if(t >= textureMesh.tex_coordinates.size())
		{
			continue;
		}
		const std::vector<pcl::Vertices> & polys = textureMesh.tex_polygons[t];
		const auto & uvs = textureMesh.tex_coordinates[t];
		size_t uvIndex = 0;
		for(size_t p = 0; p < polys.size(); ++p)
		{
			const pcl::Vertices & poly = polys[p];
			const size_t n = poly.vertices.size();
			if(uvIndex + n > uvs.size())
			{
				break;
			}
			bool valid = n >= 3;
			for(size_t k = 0; k < n && valid; ++k)
			{
				const Eigen::Vector2f & uv = uvs[uvIndex + k];
				const int vi = static_cast<int>(poly.vertices[k]);
				if(vi < 0 || vi >= (int)cloud.size())
				{
					valid = false;
					++rejectedIndex;
				}
				else if(uv[0] < 0.0f || uv[1] < 0.0f || uv[0] > 1.0f || uv[1] > 1.0f)
				{
					valid = false;
					++rejectedUv;
				}
			}
			if(valid)
			{
				pcl::Vertices tri;
				tri.vertices.reserve(n);
				for(size_t k = 0; k < n; ++k)
				{
					const Eigen::Vector2f & uv = uvs[uvIndex + k];
					const int vi = static_cast<int>(poly.vertices[k]);
					// tile-local u -> atlas-wide u
					const float ua = (uv[0] + float(t)) / float(tiles);
					const float va = uv[1];
					const std::pair<int, std::pair<int, int> > key(
						vi, std::make_pair((int)std::lround(ua * 65535.0f), (int)std::lround(va * 65535.0f)));
					std::map<std::pair<int, std::pair<int, int> >, uint32_t>::const_iterator w = welded.find(key);
					uint32_t idx = 0;
					if(w == welded.end())
					{
						idx = static_cast<uint32_t>(out.cloud.size());
						out.cloud.push_back(cloud[vi]);
						out.uv.push_back(ua);
						out.uv.push_back(va);
						welded.insert(std::make_pair(key, idx));
					}
					else
					{
						idx = w->second;
					}
					tri.vertices.push_back(idx);
				}
				out.polygons.push_back(tri);
			}
			uvIndex += n;
		}
	}
	out.cloud.width = static_cast<uint32_t>(out.cloud.size());
	out.cloud.height = 1;
	out.cloud.is_dense = true;
	if(rejectedUv || rejectedIndex || skippedMaterials)
	{
		UWARN("Textured bake: atlas %dx%d tiles=%d kept=%d rejected_uv=%d rejected_index=%d skipped_materials=%d",
			bgr.cols, bgr.rows, tiles, (int)out.polygons.size(),
			(int)rejectedUv, (int)rejectedIndex, (int)skippedMaterials);
	}
}

// Optional Poisson bake. Not used for the admin live view (that is assembleMapMesh).
bool exportAssembledMesh(
	const std::map<int, rtabmap::Transform> & poses,
	std::map<int, rtabmap::Signature> & signatures,
	pcl::PointCloud<pcl::PointXYZRGB> & outCloud,
	std::vector<pcl::Vertices> & outPolygons,
	TexturedBake * textured = 0)
{
	outCloud.clear();
	outPolygons.clear();
	if(textured)
	{
		textured->cloud.clear();
		textured->uv.clear();
		textured->polygons.clear();
		textured->atlasBgr = cv::Mat();
	}
	pcl::PointCloud<pcl::PointXYZRGBNormal>::Ptr mergedClouds(new pcl::PointCloud<pcl::PointXYZRGBNormal>);
	std::map<int, rtabmap::Transform> cameraPoses;
	std::map<int, rtabmap::CameraModel> cameraModels;
	std::map<int, cv::Mat> cameraDepths;
	std::map<int, cv::Mat> cameraImages;
	int used = 0;
	for(std::map<int, rtabmap::Transform>::const_iterator it = poses.begin(); it != poses.end(); ++it)
	{
		if(it->first <= 0 || it->second.isNull())
		{
			continue;
		}
		std::map<int, rtabmap::Signature>::iterator sit = signatures.find(it->first);
		if(sit == signatures.end())
		{
			continue;
		}
		rtabmap::SensorData & data = sit->second.sensorData();
		data.uncompressData();
		if(data.imageRaw().empty() || data.depthRaw().empty() || data.cameraModels().size() != 1)
		{
			continue;
		}
		if(!data.cameraModels()[0].isValidForProjection())
		{
			continue;
		}
		cv::Mat depth = data.depthRaw();
		cv::Mat depthFiltered = depth;
		depthFiltered = rtabmap::util2d::fastBilateralFiltering(
			depthFiltered, kBilateralSigmaS, kBilateralSigmaR);
		data.setRGBDImage(data.imageRaw(), depthFiltered, data.depthConfidenceRaw(), data.cameraModels());
		pcl::IndicesPtr indices(new std::vector<int>);
		const int decimation = meshDecimationDensity(
			data.depthRaw().cols, data.depthRaw().rows, kAssembleDensityLevel);
		pcl::PointCloud<pcl::PointXYZRGB>::Ptr cloud = rtabmap::util3d::cloudRGBFromSensorData(
			data, decimation, kAssembleMaxDepth, kAssembleMinDepth, indices.get(),
			rtabmap::ParametersMap(), std::vector<float>(), kDepthConfidenceThr);
		if(!cloud || cloud->empty() || !indices || indices->empty())
		{
			continue;
		}
		pcl::PointCloud<pcl::PointXYZRGB>::Ptr transformedCloud(new pcl::PointCloud<pcl::PointXYZRGB>);
		if(kAssembleVoxel > 0.0f)
		{
			transformedCloud = rtabmap::util3d::voxelize(cloud, indices, kAssembleVoxel);
			transformedCloud = rtabmap::util3d::transformPointCloud(transformedCloud, it->second);
		}
		else
		{
			pcl::copyPointCloud(*cloud, *indices, *transformedCloud);
			transformedCloud = rtabmap::util3d::transformPointCloud(transformedCloud, it->second);
		}
		if(!transformedCloud || transformedCloud->size() < 3)
		{
			continue;
		}
		flattenUnorganized(*transformedCloud);
		const Eigen::Vector3f viewpoint(it->second.x(), it->second.y(), it->second.z());
		pcl::PointCloud<pcl::Normal>::Ptr normals = rtabmap::util3d::computeNormals(
			transformedCloud, kAssembleNormalK, 0.0f, viewpoint);
		if(!normals || normals->size() != transformedCloud->size())
		{
			continue;
		}
		pcl::PointCloud<pcl::PointXYZRGBNormal>::Ptr cloudWithNormals(new pcl::PointCloud<pcl::PointXYZRGBNormal>);
		pcl::concatenateFields(*transformedCloud, *normals, *cloudWithNormals);
		if(mergedClouds->empty())
		{
			*mergedClouds = *cloudWithNormals;
		}
		else
		{
			*mergedClouds += *cloudWithNormals;
		}
		cameraPoses.insert(std::make_pair(it->first, it->second));
		cameraModels.insert(std::make_pair(it->first, data.cameraModels()[0]));
		if(!data.depthRaw().empty())
		{
			cameraDepths.insert(std::make_pair(it->first, data.depthRaw().clone()));
		}
		if(!data.imageRaw().empty())
		{
			cameraImages.insert(std::make_pair(it->first, data.imageRaw().clone()));
		}
		++used;
	}
	UINFO("Assemble clouds nodes=%d merged_pts=%d cameras=%d (exportMesh optimized)",
		used, (int)mergedClouds->size(), (int)cameraPoses.size());
	if(mergedClouds->size() < 3)
	{
		assembleMapMesh(poses, signatures, outCloud, outPolygons);
		UINFO("Assemble fallback organizedFastMesh verts=%d faces=%d",
			(int)outCloud.size(), (int)outPolygons.size());
		return triangleCount(outPolygons) > 0;
	}

	int optimizedDepth = kAssembleDepth;
	if(optimizedDepth == 0)
	{
		Eigen::Vector4f minPt, maxPt;
		pcl::getMinMax3D(*mergedClouds, minPt, maxPt);
		const float mapLength = uMax3(maxPt[0] - minPt[0], maxPt[1] - minPt[1], maxPt[2] - minPt[2]);
		optimizedDepth = 12;
		for(int i = 6; i < 12; ++i)
		{
			if(mapLength / float(1 << i) < 0.03f)
			{
				optimizedDepth = i;
				break;
			}
		}
		UINFO("Assemble optimizedDepth=%d mapLength=%f", optimizedDepth, mapLength);
	}

	pcl::PolygonMesh::Ptr mesh(new pcl::PolygonMesh);
	try
	{
		pcl::Poisson<pcl::PointXYZRGBNormal> poisson;
		poisson.setDepth(optimizedDepth);
		poisson.setInputCloud(mergedClouds);
		poisson.reconstruct(*mesh);
	}
	catch(const std::exception & e)
	{
		UWARN("Poisson reconstruct failed: %s", e.what());
		assembleMapMesh(poses, signatures, outCloud, outPolygons);
		return triangleCount(outPolygons) > 0;
	}
	catch(...)
	{
		UWARN("Poisson reconstruct failed");
		assembleMapMesh(poses, signatures, outCloud, outPolygons);
		return triangleCount(outPolygons) > 0;
	}
	UINFO("Assemble Poisson polygons=%d", (int)mesh->polygons.size());
	if(mesh->polygons.empty())
	{
		assembleMapMesh(poses, signatures, outCloud, outPolygons);
		return triangleCount(outPolygons) > 0;
	}
	if(kAssembleMaxPolygons > 0 && (int)mesh->polygons.size() > kAssembleMaxPolygons)
	{
		// Same as RTABMapApp::exportMesh: quadric decimation to the polygon
		// budget keeps the whole surface. Subsampling triangles (the previous
		// capMeshPolygons) shredded it.
		const float factor = 1.0f - float(kAssembleMaxPolygons) / float(mesh->polygons.size());
		UTimer decimTimer;
		pcl::PolygonMesh::Ptr decimated = rtabmap::util3d::meshDecimation(mesh, factor);
		if(decimated && !decimated->polygons.empty() && decimated->polygons.size() < mesh->polygons.size())
		{
			UINFO("Assemble decimated %d -> %d polygons (factor %.3f, %.1fs)",
				(int)mesh->polygons.size(), (int)decimated->polygons.size(), factor, decimTimer.ticks());
			mesh = decimated;
		}
		else
		{
			UWARN("Assemble mesh decimation failed, keeping %d polygons", (int)mesh->polygons.size());
		}
	}

	try
	{
		rtabmap::util3d::denseMeshPostProcessing<pcl::PointXYZRGBNormal>(
			mesh,
			0.0f,
			0,
			mergedClouds,
			kAssembleColorRadius,
			true,
			kAssembleCleanMesh,
			kAssembleMinCluster);
	}
	catch(const std::exception & e)
	{
		UWARN("denseMeshPostProcessing failed: %s", e.what());
	}

	if(mesh->polygons.empty())
	{
		assembleMapMesh(poses, signatures, outCloud, outPolygons);
		return triangleCount(outPolygons) > 0;
	}

	// Texture against the mesh's own (uncompacted) cloud so polygon indices
	// match; compaction for the vertex-color fallback happens afterwards.
	if(!cameraPoses.empty() && !cameraModels.empty())
	{
		try
		{
			std::vector<std::map<int, pcl::PointXY> > vertexToPixels;
			pcl::TextureMesh::Ptr textureMesh = rtabmap::util3d::createTextureMesh(
				mesh,
				cameraPoses,
				cameraModels,
				cameraDepths,
				kAssembleMaxTextureDistance,
				kAssembleMaxDepthError,
				0.0f,
				kAssembleMinTextureCluster,
				std::vector<float>(),
				0,
				&vertexToPixels);
			if(textureMesh && !textureMesh->tex_materials.empty())
			{
				{
					const rtabmap::CameraModel & cm0 = cameraModels.begin()->second;
					size_t seen = 0;
					for(size_t i = 0; i < vertexToPixels.size(); ++i)
					{
						if(!vertexToPixels[i].empty()) ++seen;
					}
					cv::Mat d0 = cameraDepths.empty() ? cv::Mat() : cameraDepths.begin()->second;
					cv::Mat i0 = cameraImages.empty() ? cv::Mat() : cameraImages.begin()->second;
					UINFO("Assemble camera model: fx=%.1f fy=%.1f cx=%.1f cy=%.1f image=%dx%d rgb=%dx%d depth=%dx%d local=%s; vertices seen by >=1 camera: %d/%d",
						cm0.fx(), cm0.fy(), cm0.cx(), cm0.cy(), cm0.imageWidth(), cm0.imageHeight(),
						i0.cols, i0.rows, d0.cols, d0.rows, cm0.localTransform().prettyPrint().c_str(),
						(int)seen, (int)vertexToPixels.size());
					size_t texturedPolys = 0;
					int camerasUsed = 0;
					for(size_t t = 0; t + 1 < textureMesh->tex_polygons.size(); ++t)
					{
						texturedPolys += textureMesh->tex_polygons[t].size();
						if(!textureMesh->tex_polygons[t].empty()) ++camerasUsed;
					}
					const size_t untextured = textureMesh->tex_polygons.empty() ? 0 : textureMesh->tex_polygons.back().size();
					UINFO("Assemble createTextureMesh: %d polygons -> %d textured by %d cameras, %d unseen (dropped)",
						(int)mesh->polygons.size(), (int)texturedPolys, camerasUsed, (int)untextured);
				}
				if(kAssembleCleanMesh && !textureMesh->tex_coordinates.empty())
				{
					// Drop untextured (unseen) polygons and tiny textured islands.
					rtabmap::util3d::cleanTextureMesh(*textureMesh, kAssembleTextureIslandMin);
				}
				std::map<int, std::vector<rtabmap::CameraModel> > calibrations;
				for(std::map<int, rtabmap::CameraModel>::const_iterator cm = cameraModels.begin();
					cm != cameraModels.end(); ++cm)
				{
					calibrations[cm->first] = std::vector<rtabmap::CameraModel>(1, cm->second);
				}
				cv::Mat atlas = rtabmap::util3d::mergeTextures(
					*textureMesh,
					cameraImages,
					calibrations,
					0,
					0,
					kAssembleTextureSize,
					kAssembleTextureCount,
					vertexToPixels,
					true, 10.0f, true, true, 0, 0, 0, false,
					0,
					255,
					false);
				if(!atlas.empty())
				{
					// Same index space as textureMesh->tex_polygons.
					pcl::PointCloud<pcl::PointXYZRGB> meshVerts;
					pcl::fromPCLPointCloud2(textureMesh->cloud, meshVerts);
					flattenUnorganized(meshVerts);
					sampleAtlasOntoCloud(*textureMesh, atlas, meshVerts);
					UINFO("Assemble textured atlas=%dx%d sampled onto %d verts",
						atlas.cols, atlas.rows, (int)meshVerts.size());
					if(textured)
					{
						buildTexturedBake(*textureMesh, meshVerts, atlas, *textured);
						UINFO("Assemble textured mesh verts=%d faces=%d",
							(int)textured->cloud.size(), (int)triangleCount(textured->polygons));
					}
					// Vertex-color fallback carries the sampled photo colors too.
					pcl::toPCLPointCloud2(meshVerts, mesh->cloud);
				}
			}
		}
		catch(const std::exception & e)
		{
			UWARN("createTextureMesh/mergeTextures failed, keeping vertex colors: %s", e.what());
		}
		catch(...)
		{
			UWARN("createTextureMesh/mergeTextures failed, keeping vertex colors");
		}
	}

	extractRgbMesh(mesh, outCloud, outPolygons);
	if(triangleCount(outPolygons) == 0)
	{
		assembleMapMesh(poses, signatures, outCloud, outPolygons);
		return triangleCount(outPolygons) > 0;
	}
	UINFO("Assemble exportMesh verts=%d faces=%d", (int)outCloud.size(), (int)triangleCount(outPolygons));
	return triangleCount(outPolygons) > 0;
}

bool writeViewerMeshFile(
	const std::string & path,
	const pcl::PointCloud<pcl::PointXYZRGB> & cloud,
	const std::vector<pcl::Vertices> & polygons,
	const char * comment = 0)
{
	const uint32_t nVert = static_cast<uint32_t>(cloud.size());
	const uint32_t nFace = triangleCount(polygons);
	std::ostringstream header;
	header << "ply\n"
		<< "format binary_little_endian 1.0\n"
		<< "comment " << (comment ? comment : "rtabmap-collab live mesh vertex colors") << "\n"
		<< "element vertex " << nVert << "\n"
		<< "property float x\n"
		<< "property float y\n"
		<< "property float z\n"
		<< "property uchar red\n"
		<< "property uchar green\n"
		<< "property uchar blue\n"
		<< "element face " << nFace << "\n"
		<< "property list uchar int vertex_indices\n"
		<< "end_header\n";
	const std::string headerStr = header.str();
	const std::string tmp = path + ".tmp";
	FILE * out = std::fopen(tmp.c_str(), "wb");
	if(!out)
	{
		return false;
	}
	if(std::fwrite(headerStr.data(), 1, headerStr.size(), out) != headerStr.size())
	{
		std::fclose(out);
		UFile::erase(tmp);
		return false;
	}
	for(uint32_t i = 0; i < nVert; ++i)
	{
		const pcl::PointXYZRGB & p = cloud[i];
		const float xyz[3] = {p.x, p.y, p.z};
		const unsigned char rgb[3] = {p.r, p.g, p.b};
		if(std::fwrite(xyz, 4, 3, out) != 3 || std::fwrite(rgb, 1, 3, out) != 3)
		{
			std::fclose(out);
			UFile::erase(tmp);
			return false;
		}
	}
	for(size_t i = 0; i < polygons.size(); ++i)
	{
		const pcl::Vertices & poly = polygons[i];
		if(poly.vertices.size() < 3)
		{
			continue;
		}
		for(size_t t = 0; t + 2 < poly.vertices.size(); ++t)
		{
			const unsigned char n = 3;
			const int32_t tri[3] = {
				static_cast<int32_t>(poly.vertices[0]),
				static_cast<int32_t>(poly.vertices[t + 1]),
				static_cast<int32_t>(poly.vertices[t + 2])
			};
			if(std::fwrite(&n, 1, 1, out) != 1 || std::fwrite(tri, 4, 3, out) != 3)
			{
				std::fclose(out);
				UFile::erase(tmp);
				return false;
			}
		}
	}
	std::fclose(out);
	UFile::erase(path);
	return UFile::rename(tmp, path) == 0;
}

// Textured variant: x y z s t red green blue. three.js PLYLoader maps s/t to
// the uv attribute; colors stay as a fallback while the atlas downloads.
bool writeTexturedMeshFile(
	const std::string & path,
	const pcl::PointCloud<pcl::PointXYZRGB> & cloud,
	const std::vector<float> & uv,
	const std::vector<pcl::Vertices> & polygons,
	const char * comment)
{
	const uint32_t nVert = static_cast<uint32_t>(cloud.size());
	if(uv.size() != size_t(nVert) * 2)
	{
		return false;
	}
	const uint32_t nFace = triangleCount(polygons);
	std::ostringstream header;
	header << "ply\n"
		<< "format binary_little_endian 1.0\n"
		<< "comment " << (comment ? comment : "rtabmap-collab textured bake") << "\n"
		<< "comment TextureFile map.bake.jpg\n"
		<< "element vertex " << nVert << "\n"
		<< "property float x\nproperty float y\nproperty float z\n"
		<< "property float s\nproperty float t\n"
		<< "property uchar red\nproperty uchar green\nproperty uchar blue\n"
		<< "element face " << nFace << "\n"
		<< "property list uchar int vertex_indices\n"
		<< "end_header\n";
	const std::string headerStr = header.str();
	const std::string tmp = path + ".tmp";
	FILE * out = std::fopen(tmp.c_str(), "wb");
	if(!out)
	{
		return false;
	}
	bool ok = std::fwrite(headerStr.data(), 1, headerStr.size(), out) == headerStr.size();
	for(uint32_t i = 0; ok && i < nVert; ++i)
	{
		const pcl::PointXYZRGB & p = cloud[i];
		const float rec[5] = {p.x, p.y, p.z, uv[2 * i], uv[2 * i + 1]};
		const unsigned char rgb[3] = {p.r, p.g, p.b};
		ok = std::fwrite(rec, 4, 5, out) == 5 && std::fwrite(rgb, 1, 3, out) == 3;
	}
	for(size_t i = 0; ok && i < polygons.size(); ++i)
	{
		const pcl::Vertices & poly = polygons[i];
		if(poly.vertices.size() < 3)
		{
			continue;
		}
		for(size_t t = 0; ok && t + 2 < poly.vertices.size(); ++t)
		{
			const unsigned char n = 3;
			const int32_t tri[3] = {
				static_cast<int32_t>(poly.vertices[0]),
				static_cast<int32_t>(poly.vertices[t + 1]),
				static_cast<int32_t>(poly.vertices[t + 2])
			};
			ok = std::fwrite(&n, 1, 1, out) == 1 && std::fwrite(tri, 4, 3, out) == 3;
		}
	}
	std::fclose(out);
	if(!ok)
	{
		UFile::erase(tmp);
		return false;
	}
	UFile::erase(path);
	return UFile::rename(tmp, path) == 0;
}

bool writeEmptyViewerMeshFile(const std::string & path)
{
	pcl::PointCloud<pcl::PointXYZRGB> empty;
	std::vector<pcl::Vertices> none;
	return writeViewerMeshFile(path, empty, none);
}

// Same binary PLY layout as writeViewerMeshFile, but into memory (served
// directly for the "newer than the bake" overlay).
std::string serializeViewerMeshPly(
	const pcl::PointCloud<pcl::PointXYZRGB> & cloud,
	const std::vector<pcl::Vertices> & polygons,
	const char * comment)
{
	const uint32_t nVert = static_cast<uint32_t>(cloud.size());
	const uint32_t nFace = triangleCount(polygons);
	std::ostringstream oss;
	oss << "ply\n"
		<< "format binary_little_endian 1.0\n"
		<< "comment " << (comment ? comment : "rtabmap-collab live mesh vertex colors") << "\n"
		<< "element vertex " << nVert << "\n"
		<< "property float x\nproperty float y\nproperty float z\n"
		<< "property uchar red\nproperty uchar green\nproperty uchar blue\n"
		<< "element face " << nFace << "\n"
		<< "property list uchar int vertex_indices\n"
		<< "end_header\n";
	std::string out = oss.str();
	out.reserve(out.size() + nVert * 15 + nFace * 13);
	for(uint32_t i = 0; i < nVert; ++i)
	{
		const pcl::PointXYZRGB & p = cloud[i];
		const float xyz[3] = {p.x, p.y, p.z};
		const unsigned char rgb[3] = {p.r, p.g, p.b};
		out.append(reinterpret_cast<const char *>(xyz), sizeof(xyz));
		out.append(reinterpret_cast<const char *>(rgb), sizeof(rgb));
	}
	for(size_t i = 0; i < polygons.size(); ++i)
	{
		const pcl::Vertices & poly = polygons[i];
		if(poly.vertices.size() < 3)
		{
			continue;
		}
		for(size_t t = 0; t + 2 < poly.vertices.size(); ++t)
		{
			const unsigned char n = 3;
			const int32_t tri[3] = {
				static_cast<int32_t>(poly.vertices[0]),
				static_cast<int32_t>(poly.vertices[t + 1]),
				static_cast<int32_t>(poly.vertices[t + 2])
			};
			out.append(reinterpret_cast<const char *>(&n), 1);
			out.append(reinterpret_cast<const char *>(tri), sizeof(tri));
		}
	}
	return out;
}

bool writeViewerCloudFile(const std::string & path, const pcl::PointCloud<pcl::PointXYZRGB> & cloud)
{
	uint32_t n = static_cast<uint32_t>(cloud.size());
	if(n > kCloudMaxPoints)
	{
		n = kCloudMaxPoints;
	}
	const uint32_t flags = 1;
	std::string tmp = path + ".tmp";
	FILE * out = std::fopen(tmp.c_str(), "wb");
	if(!out)
	{
		return false;
	}
	if(std::fwrite(kCloudMagic, 1, 4, out) != 4 ||
	   std::fwrite(&n, 4, 1, out) != 1 ||
	   std::fwrite(&flags, 4, 1, out) != 1)
	{
		std::fclose(out);
		UFile::erase(tmp);
		return false;
	}
	const size_t total = cloud.size();
	for(uint32_t i = 0; i < n; ++i)
	{
		const size_t idx = (n == total || total == 0) ? static_cast<size_t>(i) : (static_cast<size_t>(i) * total / n);
		const pcl::PointXYZRGB & p = cloud[idx];
		const float xyz[3] = {p.x, p.y, p.z};
		const unsigned char rgba[4] = {p.r, p.g, p.b, 0};
		if(std::fwrite(xyz, 4, 3, out) != 3 || std::fwrite(rgba, 1, 4, out) != 4)
		{
			std::fclose(out);
			UFile::erase(tmp);
			return false;
		}
	}
	std::fclose(out);
	UFile::erase(path);
	return UFile::rename(tmp, path) == 0;
}

bool writeEmptyViewerCloudFile(const std::string & path)
{
	pcl::PointCloud<pcl::PointXYZRGB> empty;
	return writeViewerCloudFile(path, empty);
}

bool saveAssembledExports(
	const std::string & plyPath,
	const std::string & cloudPath,
	const std::string & meshPath,
	const pcl::PointCloud<pcl::PointXYZRGB>::Ptr & assembled,
	const std::map<int, rtabmap::Transform> & poses,
	std::map<int, rtabmap::Signature> & signatures,
	std::string & error)
{
	if(!assembled || assembled->empty())
	{
		writeEmptyViewerCloudFile(cloudPath);
		writeEmptyViewerMeshFile(meshPath);
		UINFO("Viewer cloud/mesh empty (no scans yet)");
		return true;
	}
	if(!writeViewerCloudFile(cloudPath, *assembled))
	{
		error = "write map.cloud failed";
		UWARN("%s", error.c_str());
		return false;
	}
	std::string tmpPly = plyPath + ".tmp";
	int plyRc = pcl::io::savePLYFileBinary(tmpPly, *assembled);
	if(plyRc != 0)
	{
		UWARN("savePLYFileBinary failed after writing map.cloud");
		UFile::erase(tmpPly);
	}
	else
	{
		UFile::erase(plyPath);
		UFile::rename(tmpPly, plyPath);
	}
	// The live mesh (meshPath) is owned by CollabMap::exportLiveMeshLocked,
	// which runs after every ingest from cached node meshes. Rebuilding it
	// here from raw signatures would only add seconds to the heavy pass.
	(void)meshPath;
	(void)poses;
	(void)signatures;
	UINFO("Wrote %s and %s (%d points)", cloudPath.c_str(), plyPath.c_str(), (int)assembled->size());
	return true;
}

}

// Per-node live meshes in the camera frame. Built once per node; the export
// re-places them with the latest poses. Cleared when the room is reset or the
// budget decimation changes with the node count.
struct NodeMeshCache
{
	struct Entry
	{
		pcl::PointCloud<pcl::PointXYZRGB> cloud;
		std::vector<pcl::Vertices> polygons;
	};
	std::map<int, Entry> nodes;
	int decimation;
	int depthWidth;
	int depthHeight;
	NodeMeshCache() : decimation(0), depthWidth(0), depthHeight(0) {}
};

rtabmap::ParametersMap combineParameters(const std::string & workDir);

rtabmap::Transform CollabMap::rtabmapWorldFromOpenGL()
{
	return kRtabmapWorldFromOpenGL;
}

rtabmap::Transform CollabMap::openGLWorldFromRtabmap()
{
	return kOpenGLWorldFromRtabmap;
}

rtabmap::Transform CollabMap::levelArkitTagFrame(const rtabmap::Transform & arkitWorldFromTag)
{
	if(arkitWorldFromTag.isNull())
	{
		return rtabmap::Transform();
	}
	// ARKit world is gravity-aligned (+y up). Keep the tag center and heading,
	// take up from gravity: a laptop lid leans back 10-20 deg and without this
	// the whole shared frame (floor, walls, phones) pitches by that angle.
	// columns of the rotation = tag axes expressed in the ARKit world
	const Eigen::Vector3f up(0.0f, 1.0f, 0.0f);
	const Eigen::Vector3f n(arkitWorldFromTag.r13(), arkitWorldFromTag.r23(), arkitWorldFromTag.r33()); // tag normal, toward the viewer
	Eigen::Vector3f zp = n - n.dot(up) * up;
	if(zp.norm() < 0.2f)
	{
		// Tag lying flat (normal near vertical): the reader stands at its bottom
		// edge, so "toward the viewer" is minus the up edge, projected.
		const Eigen::Vector3f e(arkitWorldFromTag.r12(), arkitWorldFromTag.r22(), arkitWorldFromTag.r32());
		zp = -(e - e.dot(up) * up);
	}
	if(zp.norm() < 1e-4f)
	{
		return arkitWorldFromTag;
	}
	zp.normalize();
	Eigen::Vector3f xp = up.cross(zp); // y x z = x for a right-handed frame
	xp.normalize();
	return rtabmap::Transform(
		xp.x(), up.x(), zp.x(), arkitWorldFromTag.x(),
		xp.y(), up.y(), zp.y(), arkitWorldFromTag.y(),
		xp.z(), up.z(), zp.z(), arkitWorldFromTag.z());
}

rtabmap::Transform CollabMap::globalFromClientWorld(const rtabmap::Transform & arkitWorldFromTag)
{
	if(arkitWorldFromTag.isNull())
	{
		return rtabmap::Transform();
	}
	const rtabmap::Transform leveled = levelArkitTagFrame(arkitWorldFromTag);
	if(leveled.isNull())
	{
		return rtabmap::Transform();
	}
	return kRtabmapWorldFromOpenGL * leveled.inverse() * kOpenGLWorldFromRtabmap;
}

rtabmap::Transform CollabMap::rtabmapPoseFromArkit(const rtabmap::Transform & arkitCamera)
{
	if(arkitCamera.isNull())
	{
		return rtabmap::Transform();
	}
	return kRtabmapWorldFromOpenGL * arkitCamera * kOpenGLWorldFromRtabmap;
}

CollabMap::CollabMap(const std::string & dataDir) :
	dataDir_(dataDir),
	nextGlobalId_(1),
	nextMapIdBase_(0),
	globalNodes_(0),
	poses_(0),
	loopClosures_(0),
	meshGen_(0),
	lastBakedNodes_(0),
	lastIngestAligned_(false),
	interMapLc_(0),
	lastHeavyPassAt_(0),
	lastIngestAt_(0),
	meshCache_(new NodeMeshCache),
	cloudStale_(true),
	bakeGen_(0),
	bakeMaxNodeId_(0),
	lastBakeAt_(0),
	bakeTextured_(false),
	roomEpoch_(0),
	roomLocked_(false),
	lockedTagId_(kDemoTagId),
	tagSizeM_(kDemoTagSizeM),
	optimizeRunning_(false),
	optimizeAgain_(false),
	bakeRunning_(false),
	bakeAgain_(false),
	bakeStop_(false)
{
	globalDbPath_ = dataDir_ + "/global.db";
	statePath_ = dataDir_ + "/clients.json";
	plyPath_ = dataDir_ + "/map.ply";
	cloudPath_ = dataDir_ + "/map.cloud";
	meshPath_ = dataDir_ + "/map.mesh.ply";
	bakedMeshPath_ = dataDir_ + "/map.mesh.baked.ply";
	bakedAtlasPath_ = dataDir_ + "/map.mesh.baked.jpg";
	// A bake survives a restart: its sidecar says which nodes it covers and
	// whether it is textured.
	if(plyFileHasFaces(bakedMeshPath_))
	{
		std::ifstream meta((bakedMeshPath_ + ".meta").c_str());
		int maxNode = 0;
		int texturedFlag = 0;
		if(meta && (meta >> maxNode) && maxNode > 0)
		{
			meta >> texturedFlag;
			bakeGen_ = 1;
			bakeMaxNodeId_ = maxNode;
			bakeTextured_ = texturedFlag == 1 && UFile::exists(bakedAtlasPath_) && UFile::length(bakedAtlasPath_) > 0;
			UINFO("Restored baked mesh covering nodes <= %d (%s)", maxNode, bakeTextured_ ? "textured" : "vertex colors");
		}
		else
		{
			UFile::erase(bakedMeshPath_);
			UFile::erase(bakedAtlasPath_);
		}
	}
}

std::string CollabMap::bakedAtlasPath() const
{
	std::lock_guard<std::mutex> lock(mutex_);
	return bakeTextured_ ? bakedAtlasPath_ : std::string();
}

CollabMap::~CollabMap()
{
	// Stop and join the maintenance thread before freeing anything it uses
	// (a heavy pass in flight touches the mesh cache and the db).
	bakeStop_.store(true);
	{
		std::lock_guard<std::mutex> lock(bakeMutex_);
		bakeCv_.notify_all();
	}
	if(bakeThread_.joinable())
	{
		bakeThread_.join();
	}
	delete meshCache_;
	meshCache_ = 0;
}

bool CollabMap::init(std::string & error)
{
	if(makeDirRecursive(dataDir_).empty())
	{
		error = "Cannot create data directory: " + dataDir_;
		return false;
	}
	loadState();
	// The alignment is a function of the raw tag pose; recompute it from the
	// persisted pose so a rule change (e.g. leveling) applies to a room that
	// was calibrated by an older binary.
	for(std::map<std::string, ClientState>::iterator it = clients_.begin(); it != clients_.end(); ++it)
	{
		ClientState & c = it->second;
		if(!c.hasTagXf)
		{
			continue;
		}
		const rtabmap::Transform raw(
			c.odomFromTag[0], c.odomFromTag[1], c.odomFromTag[2],
			c.odomFromTag[3], c.odomFromTag[4], c.odomFromTag[5], c.odomFromTag[6]);
		if(raw.isNull())
		{
			continue;
		}
		const rtabmap::Transform t = globalFromClientWorld(raw);
		if(!t.isNull())
		{
			const Eigen::Quaternionf q = t.getQuaternionf();
			c.tagFromClient[0] = t.x();
			c.tagFromClient[1] = t.y();
			c.tagFromClient[2] = t.z();
			c.tagFromClient[3] = q.x();
			c.tagFromClient[4] = q.y();
			c.tagFromClient[5] = q.z();
			c.tagFromClient[6] = q.w();
		}
	}
	// A restart in the middle of a walk must not throw the phones back to the
	// tag: keep calibrations that were real detections with a stored tag
	// transform from phones active in the last kActiveTimeoutSec, and clear
	// everything else (yesterday's state, an e2e leftover, a fixture without
	// a transform). The lock is then recomputed from what survived.
	restoreSessionLockLocked();
	if(UFile::exists(globalDbPath_))
	{
		syncIdsFromDatabase();
		if(!UFile::exists(cloudPath_) || UFile::length(cloudPath_) <= 12 ||
		   !UFile::exists(meshPath_) || UFile::length(meshPath_) <= 0)
		{
			scheduleOptimize();
		}
	}
	else
	{
		// No database: whatever clients.json claims about the map is stale.
		// Counts come from the db only, so an empty room reports 0 nodes.
		globalNodes_ = 0;
		poses_ = 0;
		loopClosures_ = 0;
		nextGlobalId_ = 1;
		nextMapIdBase_ = 0;
		for(std::map<std::string, ClientState>::iterator it = clients_.begin(); it != clients_.end(); ++it)
		{
			it->second.localToGlobal.clear();
			it->second.nodes = 0;
			it->second.lastLocalId = 0;
		}
	}
	saveState();
	if(!bakeThread_.joinable())
	{
		bakeStop_.store(false);
		bakeThread_ = std::thread(&CollabMap::bakeLoop, this);
	}
	UINFO("Collab data dir=%s next_global_id=%d clients=%d nodes=%d live_mesh=organizedFastMesh",
		dataDir_.c_str(), nextGlobalId_, (int)clients_.size(), globalNodes_);
	// Rebuild the live mesh from global.db so the admin page is not blank
	// until the next phone upload. The in-memory node cache is empty on boot.
	if(globalNodes_ > 0)
	{
		std::string meshErr;
		if(!exportLiveMeshNow(meshErr))
		{
			UWARN("Startup live mesh rebuild failed: %s", meshErr.c_str());
		}
	}
	return true;
}

SyncResult CollabMap::ingest(const std::string & clientId, int sinceId, const std::string & uploadDbPath)
{
	SyncResult result;
	result.ok = true;
	result.accepted = 0;
	result.lastLocalId = 0;
	result.globalNodes = 0;
	result.loopClosures = 0;

	bool needOptimize = false;
	{
		// dbMutex_ first so optimize and ingest never deadlock with status().
		std::lock_guard<std::mutex> db(dbMutex_);
		std::lock_guard<std::mutex> lock(mutex_);
		result.globalNodes = globalNodes_;
		result.loopClosures = loopClosures_;

		if(clientId.empty())
		{
			result.ok = false;
			result.error = "missing X-Client-Id";
			return result;
		}

		ClientState & client = clients_[clientId];
		if(client.mapIdBase < 0)
		{
			client.mapIdBase = nextMapIdBase_++;
		}
		client.lastSeen = static_cast<long>(std::time(0));
		result.lastLocalId = client.lastLocalId;

		if(uploadDbPath.empty() || !UFile::exists(uploadDbPath) || UFile::length(uploadDbPath) <= 0)
		{
			saveState();
			return result;
		}

		try
		{
			if(!ingestLocked(clientId, sinceId, uploadDbPath, result))
			{
				result.ok = false;
				if(result.error.empty())
				{
					result.error = "ingest failed";
				}
				return result;
			}
			needOptimize = result.ok && result.accepted > 0;
		}
		catch(const UException & e)
		{
			result.ok = false;
			result.error = e.what();
			UERROR("Ingest exception: %s", e.what());
			return result;
		}
		catch(const std::exception & e)
		{
			result.ok = false;
			result.error = e.what();
			UERROR("Ingest exception: %s", e.what());
			return result;
		}
		catch(...)
		{
			result.ok = false;
			result.error = "ingest failed";
			UERROR("Ingest unknown exception");
			return result;
		}
	}

	if(needOptimize)
	{
		scheduleOptimize();
	}
	return result;
}

bool CollabMap::isActiveSeen(long lastSeen, long now, long timeoutSec)
{
	return lastSeen > 0 && (now - lastSeen) < timeoutSec;
}

int CollabMap::countActiveLocked(long now, long timeoutSec) const
{
	int n = 0;
	for(std::map<std::string, ClientState>::const_iterator it = clients_.begin(); it != clients_.end(); ++it)
	{
		if(isActiveSeen(it->second.lastSeen, now, timeoutSec))
		{
			++n;
		}
	}
	return n;
}

void CollabMap::resetRoomLocked()
{
	clients_.clear();
	nextGlobalId_ = 1;
	nextMapIdBase_ = 0;
	globalNodes_ = 0;
	poses_ = 0;
	loopClosures_ = 0;
	lastIngestAligned_ = false;
	roomLocked_ = false;
	lockedTagId_ = kDemoTagId;
	UFile::erase(globalDbPath_);
	UFile::erase(plyPath_);
	UFile::erase(cloudPath_);
	UFile::erase(meshPath_);
	UFile::erase(bakedMeshPath_);
	UFile::erase(bakedMeshPath_ + ".meta");
	UFile::erase(bakedAtlasPath_);
	bakeTextured_ = false;
	++roomEpoch_;
	lastBakedNodes_ = 0;
	bakeMaxNodeId_ = 0;
	lastBakeAt_ = 0;
	++bakeGen_;
	if(meshCache_)
	{
		std::lock_guard<std::mutex> cacheLock(meshCacheMutex_);
		meshCache_->nodes.clear();
		meshCache_->decimation = 0;
	}
	livePosesG_.clear();
	++meshGen_;
	UINFO("Reset room: new global.db and empty client table");
}

void CollabMap::clearSessionCalibrationLocked()
{
	for(std::map<std::string, ClientState>::iterator it = clients_.begin(); it != clients_.end(); ++it)
	{
		it->second.calibrated = false;
		it->second.detected = false;
		it->second.tagId = -1;
		it->second.hasTagXf = false;
	}
	roomLocked_ = false;
	lockedTagId_ = kDemoTagId;
	lastIngestAligned_ = false;
}

void CollabMap::restoreSessionLockLocked()
{
	const long now = static_cast<long>(std::time(0));
	int kept = 0;
	int cleared = 0;
	for(std::map<std::string, ClientState>::iterator it = clients_.begin(); it != clients_.end(); ++it)
	{
		ClientState & c = it->second;
		const bool real = c.calibrated && c.detected && c.hasTagXf && c.tagId == kDemoTagId;
		if(real && isActiveSeen(c.lastSeen, now, kActiveTimeoutSec))
		{
			++kept;
			continue;
		}
		if(c.calibrated || c.detected || c.hasTagXf)
		{
			++cleared;
		}
		c.calibrated = false;
		c.detected = false;
		c.tagId = -1;
		c.hasTagXf = false;
	}
	const bool wasLocked = roomLocked_;
	roomLocked_ = false;
	lockedTagId_ = kDemoTagId;
	recomputeLockLocked();
	if(!roomLocked_)
	{
		lastIngestAligned_ = false;
	}
	UINFO("Startup lock: kept %d real calibration(s) from phones active in the last %ld s, cleared %d, stored locked=%d -> %s",
		kept, kActiveTimeoutSec, cleared, wasLocked ? 1 : 0, roomLocked_ ? "locked" : "unlocked");
}

void CollabMap::expireStaleLockLocked()
{
	const long now = static_cast<long>(std::time(0));
	const long timeout = roomLocked_ ? kActiveTimeoutSec : kCalibWaitTimeoutSec;
	if(countActiveLocked(now, timeout) > 0)
	{
		return;
	}
	bool dirty = roomLocked_;
	for(std::map<std::string, ClientState>::const_iterator it = clients_.begin(); it != clients_.end(); ++it)
	{
		if(it->second.calibrated)
		{
			dirty = true;
			break;
		}
	}
	if(!dirty)
	{
		return;
	}
	UINFO("Auto-unlock: no phone active in the last %ld s", timeout);
	clearSessionCalibrationLocked();
	saveState();
}

void CollabMap::touchClientLocked(const std::string & clientId, long now)
{
	ClientState & client = clients_[clientId];
	if(client.mapIdBase < 0)
	{
		client.mapIdBase = nextMapIdBase_++;
	}
	client.lastSeen = now;
}

JoinResult CollabMap::join(const std::string & clientId)
{
	std::lock_guard<std::mutex> lock(mutex_);
	JoinResult result;
	result.ok = true;
	result.mode = "new";
	result.activeClients = 0;
	result.globalNodes = globalNodes_;
	result.mustDownload = false;

	if(clientId.empty())
	{
		result.ok = false;
		result.error = "missing X-Client-Id";
		return result;
	}

	const long now = static_cast<long>(std::time(0));
	expireStaleLockLocked();
	const int active = countActiveLocked(now, kActiveTimeoutSec);
	if(active > 0)
	{
		result.mode = "join";
		// Never ask a joiner to load the room's map.db into its own session.
		// Each phone's local map is its own scan in its own frame; other users'
		// nodes arrive through GET /pull with the tag-frame transform, and the
		// merged map is downloaded at stop/save. Loading another phone's nodes
		// locally would draw them in the wrong frame and skip them on /pull.
		result.mustDownload = false;
		UINFO("Join existing room client=%s active=%d nodes=%d must_download=0",
			clientId.c_str(), active, globalNodes_);
	}
	else
	{
		result.mode = "new";
		resetRoomLocked();
		result.mustDownload = false;
		result.globalNodes = 0;
		UINFO("Start new room client=%s", clientId.c_str());
	}

	touchClientLocked(clientId, now);
	saveState();
	result.globalNodes = globalNodes_;
	result.activeClients = countActiveLocked(now, kActiveTimeoutSec);
	applyLockFieldsLocked(result);
	return result;
}

JoinResult CollabMap::heartbeat(const std::string & clientId, const std::string & jsonBody)
{
	std::lock_guard<std::mutex> lock(mutex_);
	JoinResult result;
	result.ok = true;
	result.mode = "join";
	result.activeClients = 0;
	result.globalNodes = globalNodes_;
	result.mustDownload = false;

	if(clientId.empty())
	{
		result.ok = false;
		result.error = "missing X-Client-Id";
		return result;
	}

	const long now = static_cast<long>(std::time(0));
	expireStaleLockLocked();
	touchClientLocked(clientId, now);
	float x = 0, y = 0, z = 0, qx = 0, qy = 0, qz = 0, qw = 1;
	if(parseLivePoseJson(jsonBody, x, y, z, qx, qy, qz, qw))
	{
		applyTagPoseLocked(clients_[clientId], x, y, z, qx, qy, qz, qw, true);
	}
	saveState();
	result.activeClients = countActiveLocked(now, kActiveTimeoutSec);
	result.mustDownload = false;
	if(result.activeClients <= 1 && globalNodes_ <= 0)
	{
		result.mode = "new";
	}
	applyLockFieldsLocked(result);
	return result;
}

void CollabMap::applyLockFieldsLocked(JoinResult & result) const
{
	result.locked = roomLocked_;
	result.showTag = !roomLocked_;
	result.mustWaitForLock = !roomLocked_;
	result.tagId = kDemoTagId;
}

int CollabMap::countCalibratedLocked() const
{
	int n = 0;
	for(std::map<std::string, ClientState>::const_iterator it = clients_.begin(); it != clients_.end(); ++it)
	{
		if(it->second.calibrated &&
		   it->second.detected &&
		   it->second.hasTagXf &&
		   it->second.tagId == kDemoTagId)
		{
			++n;
		}
	}
	return n;
}

void CollabMap::alignPosesToTagFrame(std::map<int, rtabmap::Transform> & poses) const
{
	std::map<int, rtabmap::Transform> nodeTagFromClient;
	// Root client: owner of the lowest global node id (map 0). If the graph
	// already has cross-map closures, the optimizer expressed every session in
	// that frame, so only the root's tag transform applies.
	int rootGid = 0;
	rtabmap::Transform rootXf;
	for(std::map<std::string, ClientState>::const_iterator it = clients_.begin(); it != clients_.end(); ++it)
	{
		const ClientState & c = it->second;
		if(!c.calibrated || !c.detected || !c.hasTagXf || c.tagId != kDemoTagId)
		{
			continue;
		}
		rtabmap::Transform xf(
			c.tagFromClient[0], c.tagFromClient[1], c.tagFromClient[2],
			c.tagFromClient[3], c.tagFromClient[4], c.tagFromClient[5], c.tagFromClient[6]);
		if(xf.isNull())
		{
			continue;
		}
		for(std::map<int, int>::const_iterator jt = c.localToGlobal.begin(); jt != c.localToGlobal.end(); ++jt)
		{
			if(jt->second > 0)
			{
				nodeTagFromClient[jt->second] = xf;
				if(rootGid == 0 || jt->second < rootGid)
				{
					rootGid = jt->second;
					rootXf = xf;
				}
			}
		}
	}
	if(interMapLc_ > 0 && !rootXf.isNull())
	{
		for(std::map<int, rtabmap::Transform>::const_iterator it = poses.begin(); it != poses.end(); ++it)
		{
			if(it->first > 0)
			{
				nodeTagFromClient[it->first] = rootXf;
			}
		}
	}
	applyTagFrameToPoses(nodeTagFromClient, poses);
}

void CollabMap::recomputeLockLocked()
{
	// Only POST /calibrate with a real MarkerDetector id=0 hit may lock.
	if(roomLocked_)
	{
		return;
	}
	const long now = static_cast<long>(std::time(0));
	int count = 0;
	int agreedTag = -1;
	bool agree = true;
	for(std::map<std::string, ClientState>::const_iterator it = clients_.begin(); it != clients_.end(); ++it)
	{
		if(!it->second.calibrated || !it->second.detected || !it->second.hasTagXf)
		{
			continue;
		}
		if(it->second.tagId != kDemoTagId)
		{
			continue;
		}
		if(!isActiveSeen(it->second.lastSeen, now, roomLocked_ ? kActiveTimeoutSec : kCalibWaitTimeoutSec))
		{
			continue;
		}
		if(agreedTag < 0)
		{
			agreedTag = it->second.tagId;
		}
		else if(it->second.tagId != agreedTag)
		{
			agree = false;
		}
		++count;
	}
	if(count >= kLockPhonesRequired && agree && agreedTag == kDemoTagId)
	{
		roomLocked_ = true;
		lockedTagId_ = agreedTag;
		lastIngestAligned_ = true;
		UINFO("Room locked: %d phones with real tag %d detect (need %d)",
			count, agreedTag, kLockPhonesRequired);
	}
}

void CollabMap::applyTagPoseLocked(
	ClientState & client,
	float x, float y, float z,
	float qx, float qy, float qz, float qw,
	bool fromLive)
{
	if(!client.hasTagXf)
	{
		return;
	}
	rtabmap::Transform tagFromClient(
		client.tagFromClient[0], client.tagFromClient[1], client.tagFromClient[2],
		client.tagFromClient[3], client.tagFromClient[4], client.tagFromClient[5], client.tagFromClient[6]);
	if(!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z) ||
	   !std::isfinite(qx) || !std::isfinite(qy) || !std::isfinite(qz) || !std::isfinite(qw))
	{
		qx = 0.0f;
		qy = 0.0f;
		qz = 0.0f;
		qw = 1.0f;
	}
	else
	{
		const float qn = std::sqrt(qx * qx + qy * qy + qz * qz + qw * qw);
		if(qn < 0.1f)
		{
			qx = 0.0f;
			qy = 0.0f;
			qz = 0.0f;
			qw = 1.0f;
		}
		else
		{
			qx /= qn;
			qy /= qn;
			qz /= qn;
			qw /= qn;
		}
	}
	rtabmap::Transform odom(x, y, z, qx, qy, qz, qw);
	if(fromLive)
	{
		// POST /pose carries the raw ARKit camera transform. Bring it into the
		// phone's rtabmap world first, like postOdometryEvent does on device.
		odom = rtabmapPoseFromArkit(odom);
	}
	rtabmap::Transform world = tagFromClient * odom;
	if(world.isNull())
	{
		return;
	}
	client.poseX = world.x();
	client.poseY = world.y();
	client.poseZ = world.z();
	Eigen::Quaternionf wq = world.getQuaternionf();
	client.poseQx = wq.x();
	client.poseQy = wq.y();
	client.poseQz = wq.z();
	client.poseQw = wq.w();
	float roll = 0.0f;
	float pitch = 0.0f;
	float yaw = 0.0f;
	world.getEulerAngles(roll, pitch, yaw);
	client.poseYaw = yaw;
	client.poseRoll = roll;
	client.posePitch = pitch;
	if(fromLive)
	{
		client.lastLivePoseAt = static_cast<long>(std::time(0));
	}
	// Ground plane in G is x,y (z is up).
	std::pair<float, float> pt(world.x(), world.y());
	if(client.trail.empty() ||
	   std::fabs(client.trail.back().first - pt.first) > 0.01f ||
	   std::fabs(client.trail.back().second - pt.second) > 0.01f)
	{
		client.trail.push_back(pt);
		if(client.trail.size() > 200)
		{
			client.trail.erase(client.trail.begin(), client.trail.begin() + static_cast<int>(client.trail.size() - 200));
		}
	}
}

void CollabMap::resetDemoRoom()
{
	std::lock_guard<std::mutex> db(dbMutex_);
	std::lock_guard<std::mutex> lock(mutex_);
	resetRoomLocked();
	saveState();
	UINFO("Reset demo room: map, lock, and clients cleared");
}

bool CollabMap::setTagSizeM(float meters)
{
	if(!std::isfinite(meters) || meters <= 0.02f || meters >= 2.0f)
	{
		return false;
	}
	std::lock_guard<std::mutex> lock(mutex_);
	if(std::fabs(tagSizeM_ - meters) > 1e-4f)
	{
		UINFO("Tag size %.3f m -> %.3f m (admin page measurement)", tagSizeM_, meters);
		tagSizeM_ = meters;
		saveState();
	}
	return true;
}

float CollabMap::tagSizeM() const
{
	std::lock_guard<std::mutex> lock(mutex_);
	return tagSizeM_;
}

bool CollabMap::isRoomLocked()
{
	std::lock_guard<std::mutex> lock(mutex_);
	expireStaleLockLocked();
	return roomLocked_;
}

namespace {

bool finite7(float tx, float ty, float tz, float qx, float qy, float qz, float qw)
{
	return std::isfinite(tx) && std::isfinite(ty) && std::isfinite(tz) &&
		std::isfinite(qx) && std::isfinite(qy) && std::isfinite(qz) && std::isfinite(qw);
}

void copy7(float dst[7], float x, float y, float z, float qx, float qy, float qz, float qw)
{
	dst[0] = x;
	dst[1] = y;
	dst[2] = z;
	dst[3] = qx;
	dst[4] = qy;
	dst[5] = qz;
	dst[6] = qw;
}

}

CalibrateResult CollabMap::calibrate(
	const std::string & clientId,
	int tagId,
	bool detected,
	float tx, float ty, float tz,
	float qx, float qy, float qz, float qw)
{
	std::lock_guard<std::mutex> lock(mutex_);
	CalibrateResult result;
	result.tagId = kDemoTagId;
	if(clientId.empty())
	{
		result.error = "missing X-Client-Id";
		return result;
	}
	if(!detected)
	{
		result.error = "tag not detected";
		UWARN("Reject fake calibrate client=%s detected=0 tag=%d", clientId.c_str(), tagId);
		return result;
	}
	if(tagId != kDemoTagId)
	{
		result.error = "unexpected tag_id";
		UWARN("Reject fake calibrate client=%s tag_id=%d", clientId.c_str(), tagId);
		return result;
	}
	if(!finite7(tx, ty, tz, qx, qy, qz, qw))
	{
		result.error = "invalid pose";
		return result;
	}
	const float qn = std::sqrt(qx * qx + qy * qy + qz * qz + qw * qw);
	if(qn < 0.1f)
	{
		result.error = "invalid quaternion";
		return result;
	}
	qx /= qn;
	qy /= qn;
	qz /= qn;
	qw /= qn;

	// Body is T_arkitWorld_from_tag. Node poses live in the phone's rtabmap
	// world, so the stored alignment is T_G_from_rtabmapWorld (see frames above).
	rtabmap::Transform odomFromTag(tx, ty, tz, qx, qy, qz, qw);
	if(odomFromTag.isNull())
	{
		result.error = "invalid pose";
		return result;
	}
	rtabmap::Transform tagFromClient = globalFromClientWorld(odomFromTag);
	if(tagFromClient.isNull())
	{
		result.error = "cannot invert tag pose";
		return result;
	}

	const long now = static_cast<long>(std::time(0));
	touchClientLocked(clientId, now);
	ClientState & client = clients_[clientId];
	client.calibrated = true;
	client.detected = true;
	client.tagId = tagId;
	client.hasTagXf = true;
	copy7(client.odomFromTag, tx, ty, tz, qx, qy, qz, qw);
	Eigen::Quaternionf q = tagFromClient.getQuaternionf();
	copy7(client.tagFromClient,
		tagFromClient.x(), tagFromClient.y(), tagFromClient.z(),
		q.x(), q.y(), q.z(), q.w());
	client.poseX = tagFromClient.x();
	client.poseY = tagFromClient.y();
	client.poseZ = tagFromClient.z();
	client.poseQx = q.x();
	client.poseQy = q.y();
	client.poseQz = q.z();
	client.poseQw = q.w();
	float roll = 0.0f;
	float pitch = 0.0f;
	float yaw = 0.0f;
	tagFromClient.getEulerAngles(roll, pitch, yaw);
	client.poseYaw = yaw;
	client.poseRoll = roll;
	client.posePitch = pitch;
	if(client.trail.empty())
	{
		client.trail.push_back(std::make_pair(client.poseX, client.poseY));
	}
	recomputeLockLocked();
	saveState();
	result.ok = true;
	result.locked = roomLocked_;
	result.showTag = !roomLocked_;
	result.calibratedCount = countCalibratedLocked();
	result.tagId = kDemoTagId;
	return result;
}

CalibrateResult CollabMap::calibrateFromJson(const std::string & clientId, const std::string & jsonBody)
{
	CalibrateResult result;
	result.tagId = kDemoTagId;
	JsonParser parser(jsonBody);
	JsonValue root;
	if(!parser.parse(root) || root.type != JsonValue::kObject)
	{
		result.error = "invalid json";
		return result;
	}
	int tagId = kDemoTagId;
	if(const JsonValue * v = root.get("tag_id"))
	{
		tagId = v->asInt(kDemoTagId);
	}
	bool detected = false;
	if(const JsonValue * v = root.get("detected"))
	{
		detected = v->type == JsonValue::kBool ? v->b : (v->asInt(0) != 0);
	}
	if(!detected)
	{
		result.error = "tag not detected";
		UWARN("Reject fake calibrate client=%s detected missing/false", clientId.c_str());
		return result;
	}
	float tx = 0, ty = 0, tz = 0, qx = 0, qy = 0, qz = 0, qw = 1;
	if(const JsonValue * v = root.get("tx")) tx = static_cast<float>(v->asDouble(0));
	if(const JsonValue * v = root.get("ty")) ty = static_cast<float>(v->asDouble(0));
	if(const JsonValue * v = root.get("tz")) tz = static_cast<float>(v->asDouble(0));
	if(const JsonValue * v = root.get("qx")) qx = static_cast<float>(v->asDouble(0));
	if(const JsonValue * v = root.get("qy")) qy = static_cast<float>(v->asDouble(0));
	if(const JsonValue * v = root.get("qz")) qz = static_cast<float>(v->asDouble(0));
	if(const JsonValue * v = root.get("qw")) qw = static_cast<float>(v->asDouble(1));
	return calibrate(clientId, tagId, true, tx, ty, tz, qx, qy, qz, qw);
}

bool CollabMap::parseLivePoseJson(
	const std::string & jsonBody,
	float & x, float & y, float & z,
	float & qx, float & qy, float & qz, float & qw) const
{
	if(jsonBody.empty())
	{
		return false;
	}
	JsonParser parser(jsonBody);
	JsonValue root;
	if(!parser.parse(root) || root.type != JsonValue::kObject)
	{
		return false;
	}
	bool have = false;
	if(const JsonValue * v = root.get("tx")) { x = static_cast<float>(v->asDouble(0)); have = true; }
	if(const JsonValue * v = root.get("ty")) { y = static_cast<float>(v->asDouble(0)); have = true; }
	if(const JsonValue * v = root.get("tz")) { z = static_cast<float>(v->asDouble(0)); have = true; }
	if(const JsonValue * v = root.get("x")) { x = static_cast<float>(v->asDouble(0)); have = true; }
	if(const JsonValue * v = root.get("y")) { y = static_cast<float>(v->asDouble(0)); have = true; }
	if(const JsonValue * v = root.get("z")) { z = static_cast<float>(v->asDouble(0)); have = true; }
	if(const JsonValue * v = root.get("qx")) qx = static_cast<float>(v->asDouble(0));
	if(const JsonValue * v = root.get("qy")) qy = static_cast<float>(v->asDouble(0));
	if(const JsonValue * v = root.get("qz")) qz = static_cast<float>(v->asDouble(0));
	if(const JsonValue * v = root.get("qw")) qw = static_cast<float>(v->asDouble(1));
	if(!have || !finite7(x, y, z, qx, qy, qz, qw))
	{
		return false;
	}
	const float qn = std::sqrt(qx * qx + qy * qy + qz * qz + qw * qw);
	if(qn < 0.1f)
	{
		return false;
	}
	qx /= qn;
	qy /= qn;
	qz /= qn;
	qw /= qn;
	return true;
}

bool CollabMap::shouldSkipGraphPoseLocked(const ClientState & client, long now) const
{
	return client.lastLivePoseAt > 0 && (now - client.lastLivePoseAt) < kLivePoseHoldSec;
}

JoinResult CollabMap::updateLivePose(const std::string & clientId, const std::string & jsonBody)
{
	std::lock_guard<std::mutex> lock(mutex_);
	JoinResult result;
	result.ok = true;
	result.mode = "pose";
	result.globalNodes = globalNodes_;
	if(clientId.empty())
	{
		result.ok = false;
		result.error = "missing X-Client-Id";
		return result;
	}
	float x = 0, y = 0, z = 0, qx = 0, qy = 0, qz = 0, qw = 1;
	if(!parseLivePoseJson(jsonBody, x, y, z, qx, qy, qz, qw))
	{
		result.ok = false;
		result.error = "invalid pose";
		return result;
	}
	const long now = static_cast<long>(std::time(0));
	expireStaleLockLocked();
	touchClientLocked(clientId, now);
	applyTagPoseLocked(clients_[clientId], x, y, z, qx, qy, qz, qw, true);
	applyLockFieldsLocked(result);
	result.activeClients = countActiveLocked(now, kActiveTimeoutSec);
	return result;
}

std::string CollabMap::calibrateJson(const CalibrateResult & result) const
{
	if(!result.ok)
	{
		return std::string("{\"ok\":false,\"error\":\"") + jsonEscape(result.error) + "\"}";
	}
	std::ostringstream oss;
	oss << "{\"ok\":true"
		<< ",\"locked\":" << (result.locked ? "true" : "false")
		<< ",\"show_tag\":" << (result.showTag ? "true" : "false")
		<< ",\"calibrated_count\":" << result.calibratedCount
		<< ",\"tag_id\":" << result.tagId
		<< ",\"tag_size_m\":" << tagSizeM_
		<< "}";
	return oss.str();
}

std::string CollabMap::demoJson(const std::string & clientId)
{
	std::lock_guard<std::mutex> lock(mutex_);
	if(!clientId.empty())
	{
		touchClientLocked(clientId, static_cast<long>(std::time(0)));
	}
	expireStaleLockLocked();
	std::ostringstream oss;
	oss << "{\"ok\":true"
		<< ",\"locked\":" << (roomLocked_ ? "true" : "false")
		<< ",\"show_tag\":" << (roomLocked_ ? "false" : "true")
		<< ",\"tag_id\":" << kDemoTagId
		<< ",\"tag_family\":\"" << kDemoTagFamily << "\""
		<< ",\"tag_size_m\":" << tagSizeM_
		<< ",\"calibrated_count\":" << countCalibratedLocked()
		<< ",\"aligned\":" << (lastIngestAligned_ ? "true" : "false")
		<< ",\"global_nodes\":" << globalNodes_
		<< ",\"mesh_gen\":" << meshGen_
		<< ",\"mesh_kind\":\"live\""
		<< ",\"mesh_baked\":" << ((bakeGen_ > 0 && bakeMaxNodeId_ > 0) ? "true" : "false")
		<< ",\"bake_gen\":" << bakeGen_
		<< ",\"bake_max_node\":" << bakeMaxNodeId_
		<< ",\"bake_textured\":" << (bakeTextured_ ? "true" : "false")
		<< ",\"bake_interval_sec\":" << kBakeMinIntervalSec
		<< ",\"pose_interval_ms\":300"
		<< ",\"server_now\":" << static_cast<long>(std::time(0))
		<< ",\"calibrated\":[";
	bool firstCal = true;
	for(std::map<std::string, ClientState>::const_iterator it = clients_.begin(); it != clients_.end(); ++it)
	{
		if(!it->second.calibrated || !it->second.detected || it->second.tagId != kDemoTagId)
		{
			continue;
		}
		if(!firstCal)
		{
			oss << ",";
		}
		firstCal = false;
		oss << "{\"id\":\"" << jsonEscape(it->first) << "\",\"locked\":true}";
	}
	oss << "],\"clients\":[";
	bool firstCl = true;
	for(std::map<std::string, ClientState>::const_iterator it = clients_.begin(); it != clients_.end(); ++it)
	{
		if(!firstCl)
		{
			oss << ",";
		}
		firstCl = false;
		float pathM = 0.0f;
		for(size_t i = 1; i < it->second.trail.size(); ++i)
		{
			const float dx = it->second.trail[i].first - it->second.trail[i - 1].first;
			const float dy = it->second.trail[i].second - it->second.trail[i - 1].second;
			pathM += std::sqrt(dx * dx + dy * dy);
		}
		const bool locked = it->second.calibrated && it->second.detected && it->second.tagId == kDemoTagId;
		oss << "{\"id\":\"" << jsonEscape(it->first) << "\""
			<< ",\"locked\":" << (locked ? "true" : "false")
			<< ",\"calibrated\":" << (it->second.calibrated ? "true" : "false")
			<< ",\"detected\":" << (it->second.detected ? "true" : "false")
			<< ",\"has_fix\":" << (it->second.hasTagXf ? "true" : "false")
			<< ",\"tag_id\":" << it->second.tagId
			<< ",\"nodes\":" << it->second.nodes
			<< ",\"last_local_id\":" << it->second.lastLocalId
			<< ",\"session_map_id\":" << it->second.sessionMapId
			<< ",\"map_id_base\":" << it->second.mapIdBase
			<< ",\"last_seen\":" << it->second.lastSeen
			<< ",\"last_pose_at\":" << it->second.lastLivePoseAt
			<< ",\"x\":" << it->second.poseX
			<< ",\"y\":" << it->second.poseY
			<< ",\"z\":" << it->second.poseZ
			<< ",\"qx\":" << it->second.poseQx
			<< ",\"qy\":" << it->second.poseQy
			<< ",\"qz\":" << it->second.poseQz
			<< ",\"qw\":" << it->second.poseQw
			<< ",\"yaw\":" << it->second.poseYaw
			<< ",\"roll\":" << it->second.poseRoll
			<< ",\"pitch\":" << it->second.posePitch
			<< ",\"path_m\":" << pathM
			<< ",\"trail_n\":" << it->second.trail.size()
			<< ",\"trail\":[";
		for(size_t i = 0; i < it->second.trail.size(); ++i)
		{
			if(i)
			{
				oss << ",";
			}
			oss << "[" << it->second.trail[i].first << "," << it->second.trail[i].second << "]";
		}
		oss << "]}";
	}
	oss << "]}";
	return oss.str();
}

bool CollabMap::lastIngestAligned() const
{
	std::lock_guard<std::mutex> lock(mutex_);
	return lastIngestAligned_;
}

bool CollabMap::bakeNow(std::string & error)
{
	// The maintenance thread may be in its heavy pass or its own bake; wait
	// for it (bounded) instead of failing a manual POST /bake.
	UTimer waitTimer;
	bool expected = false;
	while(!bakeRunning_.compare_exchange_strong(expected, true))
	{
		expected = false;
		if(waitTimer.elapsed() > 600.0)
		{
			error = "a bake is already running (waited 10 min)";
			return false;
		}
		uSleep(100);
	}
	bool ok = false;
	try
	{
		ok = bakeAndExport(error);
	}
	catch(const UException & e)
	{
		error = e.what();
	}
	catch(const std::exception & e)
	{
		error = e.what();
	}
	bakeRunning_.store(false);
	return ok;
}

bool CollabMap::optimizeNow(std::string & error)
{
	std::lock_guard<std::mutex> db(dbMutex_);
	const bool ok = optimizeAndExport(error);
	std::lock_guard<std::mutex> lock(mutex_);
	lastHeavyPassAt_ = static_cast<long>(std::time(0));
	lastBakedNodes_ = globalNodes_;
	return ok;
}

bool CollabMap::exportViewerCloudLocked(std::string & error)
{
	if(!UFile::exists(globalDbPath_))
	{
		writeEmptyViewerCloudFile(cloudPath_);
		writeEmptyViewerMeshFile(meshPath_);
		{
			std::lock_guard<std::mutex> lock(mutex_);
			++meshGen_;
		}
		return true;
	}
	rtabmap::Rtabmap rtabmap;
	try
	{
		rtabmap.init(combineParameters(dataDir_), globalDbPath_, false);
	}
	catch(const UException & e)
	{
		error = e.what();
		return false;
	}
	std::map<int, rtabmap::Transform> poses;
	std::multimap<int, rtabmap::Link> constraints;
	std::map<int, rtabmap::Signature> signatures;
	rtabmap.getGraph(poses, constraints, true, true, &signatures, true, true, false, false, false, false);
	fillMissingOdomPoses(rtabmap.getMemory(), poses);
	{
		std::lock_guard<std::mutex> lock(mutex_);
		alignPosesToTagFrame(poses);
	}
	pcl::PointCloud<pcl::PointXYZRGB>::Ptr assembled = assembleMapCloud(poses, signatures);
	const bool ok = saveAssembledExports(plyPath_, cloudPath_, meshPath_, assembled, poses, signatures, error);
	if(ok)
	{
		std::lock_guard<std::mutex> lock(mutex_);
		++meshGen_;
	}
	rtabmap.close(false);
	return ok;
}

int CollabMap::meshGeneration() const
{
	std::lock_guard<std::mutex> lock(mutex_);
	return meshGen_;
}

bool CollabMap::ensureViewerCloud(std::string & error)
{
	bool stale = false;
	{
		std::lock_guard<std::mutex> lock(mutex_);
		stale = cloudStale_;
	}
	const bool haveCloud = UFile::exists(cloudPath_) && UFile::length(cloudPath_) > 12;
	const bool haveMesh = UFile::exists(meshPath_) && UFile::length(meshPath_) > 0;
	if(haveCloud && haveMesh && !stale)
	{
		return true;
	}
	std::lock_guard<std::mutex> db(dbMutex_);
	{
		std::lock_guard<std::mutex> lock(mutex_);
		stale = cloudStale_;
	}
	const bool haveCloud2 = UFile::exists(cloudPath_) && UFile::length(cloudPath_) > 12;
	const bool haveMesh2 = UFile::exists(meshPath_) && UFile::length(meshPath_) > 0;
	if(haveCloud2 && haveMesh2 && !stale)
	{
		return true;
	}
	const bool ok = exportViewerCloudLocked(error);
	if(ok)
	{
		std::lock_guard<std::mutex> lock(mutex_);
		cloudStale_ = false;
	}
	return ok;
}

bool CollabMap::exportLiveMeshNow(std::string & error)
{
	std::lock_guard<std::mutex> db(dbMutex_);
	return exportLiveMeshLocked(error);
}

int CollabMap::liveMeshNodeCount() const
{
	std::lock_guard<std::mutex> cacheLock(meshCacheMutex_);
	int n = 0;
	for(std::map<int, NodeMeshCache::Entry>::const_iterator it = meshCache_->nodes.begin(); it != meshCache_->nodes.end(); ++it)
	{
		if(!it->second.cloud.empty() && !it->second.polygons.empty())
		{
			++n;
		}
	}
	return n;
}

std::string CollabMap::liveMeshSince(int sinceNode, int & nodesOut) const
{
	nodesOut = 0;
	std::map<int, rtabmap::Transform> poses;
	{
		std::lock_guard<std::mutex> lock(mutex_);
		poses = livePosesG_;
	}
	pcl::PointCloud<pcl::PointXYZRGB> meshCloud;
	std::vector<pcl::Vertices> meshPolygons;
	flattenUnorganized(meshCloud);
	{
		std::lock_guard<std::mutex> cacheLock(meshCacheMutex_);
		const NodeMeshCache & cache = *meshCache_;
		for(std::map<int, rtabmap::Transform>::const_iterator it = poses.upper_bound(sinceNode); it != poses.end(); ++it)
		{
			if(it->first <= 0 || it->second.isNull())
			{
				continue;
			}
			std::map<int, NodeMeshCache::Entry>::const_iterator ce = cache.nodes.find(it->first);
			if(ce == cache.nodes.end() || ce->second.cloud.empty() || ce->second.polygons.empty())
			{
				continue;
			}
			if(meshPolygons.size() + ce->second.polygons.size() > kMeshMaxFaces)
			{
				break;
			}
			pcl::PointCloud<pcl::PointXYZRGB>::Ptr placedCloud(new pcl::PointCloud<pcl::PointXYZRGB>(ce->second.cloud));
			placedCloud = rtabmap::util3d::transformPointCloud(placedCloud, it->second);
			if(!placedCloud || placedCloud->empty())
			{
				continue;
			}
			flattenUnorganized(*placedCloud);
			rtabmap::util3d::appendMesh(meshCloud, meshPolygons, *placedCloud, ce->second.polygons);
			++nodesOut;
		}
	}
	flattenUnorganized(meshCloud);
	if(nodesOut == 0)
	{
		return std::string();
	}
	return serializeViewerMeshPly(meshCloud, meshPolygons, "rtabmap-collab live organizedFastMesh since bake");
}

bool CollabMap::exportLiveMeshLocked(std::string & error)
{
	if(!UFile::exists(globalDbPath_) || UFile::length(globalDbPath_) <= 0)
	{
		writeEmptyViewerMeshFile(meshPath_);
		std::lock_guard<std::mutex> lock(mutex_);
		++meshGen_;
		return true;
	}
	UTimer timer;
	// Plain DBDriver read: poses for every node, node data only for nodes not
	// yet in the mesh cache. No Rtabmap::init (that loads the whole vocabulary
	// and every image) on this path, so the cost stays flat as the map grows.
	rtabmap::DBDriver * db = rtabmap::DBDriver::create();
	if(!db->openConnection(globalDbPath_, false, true))
	{
		error = "cannot open global.db for the live mesh";
		delete db;
		return false;
	}
	std::set<int> ids;
	db->getAllNodeIds(ids, false, false, false);
	std::map<int, rtabmap::Transform> poses = db->loadOptimizedPoses();
	{
		std::map<int, rtabmap::Transform> odom;
		db->getAllOdomPoses(odom, false, false);
		for(std::set<int>::const_iterator it = ids.begin(); it != ids.end(); ++it)
		{
			if(poses.find(*it) == poses.end())
			{
				std::map<int, rtabmap::Transform>::const_iterator ot = odom.find(*it);
				if(ot != odom.end() && !ot->second.isNull())
				{
					poses[*it] = ot->second;
				}
			}
		}
	}
	const int nodeCount = static_cast<int>(ids.size());
	// Tag-frame poses first (state mutex), then the cache (cache mutex). The
	// two are never held together, so /map.mesh?since_node and room resets
	// cannot deadlock against this export.
	std::map<int, rtabmap::Transform> posesG = poses;
	{
		std::lock_guard<std::mutex> lock(mutex_);
		alignPosesToTagFrame(posesG);
		livePosesG_ = posesG;
	}
	std::lock_guard<std::mutex> cacheLock(meshCacheMutex_);
	NodeMeshCache & cache = *meshCache_;
	// Budget decimation depends on the node count; when it changes every
	// cached node must be rebuilt at the new resolution.
	if(cache.depthWidth > 0)
	{
		const int d = meshDecimationForBudget(cache.depthWidth, cache.depthHeight, nodeCount, kMeshMaxFaces);
		if(cache.decimation != 0 && d != cache.decimation)
		{
			UINFO("Live mesh decimation %d -> %d for %d nodes, rebuilding cache", cache.decimation, d, nodeCount);
			cache.nodes.clear();
		}
		cache.decimation = d;
	}
	std::list<int> missing;
	for(std::set<int>::const_iterator it = ids.begin(); it != ids.end(); ++it)
	{
		if(*it > 0 && cache.nodes.find(*it) == cache.nodes.end())
		{
			missing.push_back(*it);
		}
	}
	int built = 0;
	if(!missing.empty())
	{
		std::list<rtabmap::Signature *> signatures;
		db->loadSignatures(missing, signatures);
		if(!signatures.empty())
		{
			db->loadNodeData(signatures, true, false, false, false);
		}
		for(std::list<rtabmap::Signature *>::iterator it = signatures.begin(); it != signatures.end(); ++it)
		{
			rtabmap::Signature * sig = *it;
			if(!sig)
			{
				continue;
			}
			rtabmap::SensorData & data = sig->sensorData();
			if(cache.depthWidth <= 0)
			{
				data.uncompressData();
				if(!data.depthRaw().empty())
				{
					cache.depthWidth = data.depthRaw().cols;
					cache.depthHeight = data.depthRaw().rows;
					cache.decimation = meshDecimationForBudget(cache.depthWidth, cache.depthHeight, nodeCount, kMeshMaxFaces);
				}
			}
			NodeMeshCache::Entry & entry = cache.nodes[sig->id()];
			if(buildNodeMesh(data, nodeCount, entry.cloud, entry.polygons))
			{
				++built;
			}
			// An empty entry stays cached so a node without depth is not retried every cycle.
			delete sig;
		}
	}
	db->closeConnection(false);
	delete db;

	pcl::PointCloud<pcl::PointXYZRGB> meshCloud;
	std::vector<pcl::Vertices> meshPolygons;
	flattenUnorganized(meshCloud);
	int placed = 0;
	for(std::map<int, rtabmap::Transform>::const_iterator it = posesG.begin(); it != posesG.end(); ++it)
	{
		if(it->first <= 0 || it->second.isNull())
		{
			continue;
		}
		std::map<int, NodeMeshCache::Entry>::const_iterator ce = cache.nodes.find(it->first);
		if(ce == cache.nodes.end() || ce->second.cloud.empty() || ce->second.polygons.empty())
		{
			continue;
		}
		if(meshPolygons.size() + ce->second.polygons.size() > kMeshMaxFaces)
		{
			UWARN("Live mesh hit face cap %u, skipping remaining nodes", kMeshMaxFaces);
			break;
		}
		pcl::PointCloud<pcl::PointXYZRGB>::Ptr placedCloud(new pcl::PointCloud<pcl::PointXYZRGB>(ce->second.cloud));
		placedCloud = rtabmap::util3d::transformPointCloud(placedCloud, it->second);
		if(!placedCloud || placedCloud->empty())
		{
			continue;
		}
		flattenUnorganized(*placedCloud);
		rtabmap::util3d::appendMesh(meshCloud, meshPolygons, *placedCloud, ce->second.polygons);
		++placed;
	}
	flattenUnorganized(meshCloud);
	if(!writeViewerMeshFile(
		meshPath_, meshCloud, meshPolygons,
		"rtabmap-collab live organizedFastMesh"))
	{
		error = "write live mesh failed";
		writeEmptyViewerMeshFile(meshPath_);
		return false;
	}
	{
		std::lock_guard<std::mutex> lock(mutex_);
		++meshGen_;
	}
	UINFO("Wrote live organizedFastMesh %s nodes=%d/%d built=%d decimation=%d verts=%d faces=%d in %.2fs",
		meshPath_.c_str(), placed, nodeCount, built, cache.decimation, (int)meshCloud.size(), (int)meshPolygons.size(), timer.ticks());
	return true;
}

ServerStatus CollabMap::status() const
{
	std::lock_guard<std::mutex> lock(mutex_);
	ServerStatus s;
	s.globalNodes = globalNodes_;
	s.poses = poses_;
	s.loopClosures = loopClosures_;
	s.activeClients = countActiveLocked(static_cast<long>(std::time(0)), kActiveTimeoutSec);
	for(std::map<std::string, ClientState>::const_iterator it = clients_.begin(); it != clients_.end(); ++it)
	{
		ClientStatus c;
		c.id = it->first;
		c.lastLocalId = it->second.lastLocalId;
		c.nodes = it->second.nodes;
		c.lastSeen = it->second.lastSeen;
		s.clients.push_back(c);
	}
	return s;
}

std::string CollabMap::statusJson() const
{
	ServerStatus s = status();
	std::ostringstream oss;
	oss << "{\"ok\":true,\"global_nodes\":" << s.globalNodes
		<< ",\"clients\":[";
	for(size_t i = 0; i < s.clients.size(); ++i)
	{
		if(i) oss << ",";
		oss << "{\"id\":\"" << jsonEscape(s.clients[i].id) << "\""
			<< ",\"last_local_id\":" << s.clients[i].lastLocalId
			<< ",\"nodes\":" << s.clients[i].nodes
			<< ",\"last_seen\":" << s.clients[i].lastSeen
			<< "}";
	}
	bool locked = false;
	bool aligned = false;
	int calibratedCount = 0;
	{
		std::lock_guard<std::mutex> lock(mutex_);
		locked = roomLocked_;
		aligned = lastIngestAligned_;
		calibratedCount = countCalibratedLocked();
	}
	oss << "],\"poses\":" << s.poses
		<< ",\"loop_closures\":" << s.loopClosures
		<< ",\"active_clients\":" << s.activeClients
		<< ",\"locked\":" << (locked ? "true" : "false")
		<< ",\"aligned\":" << (aligned ? "true" : "false")
		<< ",\"calibrated_count\":" << calibratedCount
		<< "}";
	return oss.str();
}

std::string CollabMap::joinJson(const JoinResult & result) const
{
	if(!result.ok)
	{
		return std::string("{\"ok\":false,\"error\":\"") + jsonEscape(result.error) + "\"}";
	}
	std::ostringstream oss;
	oss << "{\"ok\":true"
		<< ",\"mode\":\"" << jsonEscape(result.mode) << "\""
		<< ",\"active_clients\":" << result.activeClients
		<< ",\"global_nodes\":" << result.globalNodes
		<< ",\"must_download\":" << (result.mustDownload ? "true" : "false")
		<< ",\"locked\":" << (result.locked ? "true" : "false")
		<< ",\"show_tag\":" << (result.showTag ? "true" : "false")
		<< ",\"must_wait_for_lock\":" << (result.mustWaitForLock ? "true" : "false")
		<< ",\"tag_id\":" << result.tagId
		<< ",\"tag_size_m\":" << tagSizeM_
		<< "}";
	return oss.str();
}

std::string CollabMap::syncJson(const SyncResult & result) const
{
	if(!result.ok)
	{
		return std::string("{\"ok\":false,\"error\":\"") + jsonEscape(result.error) + "\"}";
	}
	std::ostringstream oss;
	oss << "{\"ok\":true"
		<< ",\"accepted\":" << result.accepted
		<< ",\"last_local_id\":" << result.lastLocalId
		<< ",\"global_nodes\":" << result.globalNodes
		<< ",\"loop_closures\":" << result.loopClosures
		<< "}";
	return oss.str();
}

bool CollabMap::loadState()
{
	if(!UFile::exists(statePath_))
	{
		return true;
	}
	std::string text = readFile(statePath_);
	if(text.empty())
	{
		return true;
	}
	JsonParser parser(text);
	JsonValue root;
	if(!parser.parse(root) || root.type != JsonValue::kObject)
	{
		UWARN("Could not parse %s, starting with empty client table", statePath_.c_str());
		return false;
	}
	if(const JsonValue * v = root.get("next_global_id")) nextGlobalId_ = std::max(1, v->asInt(1));
	if(const JsonValue * v = root.get("next_map_id_base")) nextMapIdBase_ = std::max(0, v->asInt(0));
	if(const JsonValue * v = root.get("global_nodes")) globalNodes_ = std::max(0, v->asInt(0));
	if(const JsonValue * v = root.get("poses")) poses_ = std::max(0, v->asInt(0));
	if(const JsonValue * v = root.get("loop_closures")) loopClosures_ = std::max(0, v->asInt(0));
	// Never restore last_ingest_aligned from leftover clients.json.
	lastIngestAligned_ = false;
	// Do not restore room_locked from disk. A leftover lock from a prior
	// walk or sim is not a current-session lock.
	if(const JsonValue * v = root.get("locked_tag_id")) lockedTagId_ = v->asInt(kDemoTagId);
	if(const JsonValue * v = root.get("tag_size_m"))
	{
		const float m = static_cast<float>(v->asDouble(kDemoTagSizeM));
		if(m > 0.02f && m < 2.0f)
		{
			tagSizeM_ = m;
		}
	}
	const JsonValue * clients = root.get("clients");
	if(clients && clients->type == JsonValue::kObject)
	{
		for(std::map<std::string, JsonValue>::const_iterator it = clients->o.begin(); it != clients->o.end(); ++it)
		{
			ClientState c;
			c.lastLocalId = 0;
			c.nodes = 0;
			c.lastSeen = 0;
			c.mapIdBase = 0;
			c.sessionMapId = -1;
			const JsonValue & obj = it->second;
			if(const JsonValue * v = obj.get("last_local_id")) c.lastLocalId = v->asInt(0);
			if(const JsonValue * v = obj.get("nodes")) c.nodes = v->asInt(0);
			if(const JsonValue * v = obj.get("last_seen")) c.lastSeen = v->asLong(0);
			if(const JsonValue * v = obj.get("map_id_base")) c.mapIdBase = v->asInt(0);
			if(const JsonValue * v = obj.get("session_map_id")) c.sessionMapId = v->asInt(-1);
			if(const JsonValue * v = obj.get("calibrated")) c.calibrated = v->type == JsonValue::kBool ? v->b : (v->asInt(0) != 0);
			if(const JsonValue * v = obj.get("detected")) c.detected = v->type == JsonValue::kBool ? v->b : (v->asInt(0) != 0);
			if(const JsonValue * v = obj.get("tag_id")) c.tagId = v->asInt(-1);
			if(const JsonValue * v = obj.get("has_tag_xf")) c.hasTagXf = v->type == JsonValue::kBool ? v->b : (v->asInt(0) != 0);
			if(const JsonValue * v = obj.get("pose_x")) c.poseX = static_cast<float>(v->asDouble(0));
			if(const JsonValue * v = obj.get("pose_y")) c.poseY = static_cast<float>(v->asDouble(0));
			if(const JsonValue * v = obj.get("pose_z")) c.poseZ = static_cast<float>(v->asDouble(0));
			if(const JsonValue * v = obj.get("pose_qx")) c.poseQx = static_cast<float>(v->asDouble(0));
			if(const JsonValue * v = obj.get("pose_qy")) c.poseQy = static_cast<float>(v->asDouble(0));
			if(const JsonValue * v = obj.get("pose_qz")) c.poseQz = static_cast<float>(v->asDouble(0));
			if(const JsonValue * v = obj.get("pose_qw")) c.poseQw = static_cast<float>(v->asDouble(1));
			if(const JsonValue * v = obj.get("pose_yaw")) c.poseYaw = static_cast<float>(v->asDouble(0));
			const JsonValue * odom = obj.get("odom_from_tag");
			if(odom && odom->type == JsonValue::kArray && odom->a.size() >= 7)
			{
				for(int i = 0; i < 7; ++i)
				{
					c.odomFromTag[i] = static_cast<float>(odom->a[i].asDouble(i == 6 ? 1.0 : 0.0));
				}
			}
			const JsonValue * tagXf = obj.get("tag_from_client");
			if(tagXf && tagXf->type == JsonValue::kArray && tagXf->a.size() >= 7)
			{
				for(int i = 0; i < 7; ++i)
				{
					c.tagFromClient[i] = static_cast<float>(tagXf->a[i].asDouble(i == 6 ? 1.0 : 0.0));
				}
			}
			if(!obj.get("pose_qx") && !obj.get("pose_qw") && c.hasTagXf)
			{
				c.poseQx = c.tagFromClient[3];
				c.poseQy = c.tagFromClient[4];
				c.poseQz = c.tagFromClient[5];
				c.poseQw = c.tagFromClient[6];
			}
			const JsonValue * trail = obj.get("trail");
			if(trail && trail->type == JsonValue::kArray)
			{
				for(size_t i = 0; i < trail->a.size(); ++i)
				{
					if(trail->a[i].type == JsonValue::kArray && trail->a[i].a.size() >= 2)
					{
						c.trail.push_back(std::make_pair(
							static_cast<float>(trail->a[i].a[0].asDouble(0)),
							static_cast<float>(trail->a[i].a[1].asDouble(0))));
					}
				}
			}
			const JsonValue * idMap = obj.get("id_map");
			if(idMap && idMap->type == JsonValue::kObject)
			{
				for(std::map<std::string, JsonValue>::const_iterator jt = idMap->o.begin(); jt != idMap->o.end(); ++jt)
				{
					int localId = uStr2Int(jt->first);
					int globalId = jt->second.asInt(0);
					if(localId > 0 && globalId > 0)
					{
						c.localToGlobal[localId] = globalId;
					}
				}
			}
			c.nodes = static_cast<int>(c.localToGlobal.size());
			if(c.mapIdBase < 0)
			{
				c.mapIdBase = nextMapIdBase_++;
			}
			if(c.mapIdBase + 1 > nextMapIdBase_)
			{
				nextMapIdBase_ = c.mapIdBase + 1;
			}
			clients_[it->first] = c;
		}
	}
	return true;
}

bool CollabMap::saveState() const
{
	std::ostringstream oss;
	oss << "{\n";
	oss << "  \"next_global_id\": " << nextGlobalId_ << ",\n";
	oss << "  \"next_map_id_base\": " << nextMapIdBase_ << ",\n";
	oss << "  \"global_nodes\": " << globalNodes_ << ",\n";
	oss << "  \"poses\": " << poses_ << ",\n";
	oss << "  \"loop_closures\": " << loopClosures_ << ",\n";
	oss << "  \"last_ingest_aligned\": " << (lastIngestAligned_ ? "true" : "false") << ",\n";
	oss << "  \"room_locked\": " << (roomLocked_ ? "true" : "false") << ",\n";
	oss << "  \"locked_tag_id\": " << lockedTagId_ << ",\n";
	oss << "  \"tag_size_m\": " << tagSizeM_ << ",\n";
	oss << "  \"clients\": {\n";
	size_t ci = 0;
	for(std::map<std::string, ClientState>::const_iterator it = clients_.begin(); it != clients_.end(); ++it, ++ci)
	{
		if(ci) oss << ",\n";
		oss << "    \"" << jsonEscape(it->first) << "\": {\n";
		oss << "      \"last_local_id\": " << it->second.lastLocalId << ",\n";
		oss << "      \"nodes\": " << it->second.nodes << ",\n";
		oss << "      \"last_seen\": " << it->second.lastSeen << ",\n";
		oss << "      \"map_id_base\": " << it->second.mapIdBase << ",\n";
		oss << "      \"session_map_id\": " << it->second.sessionMapId << ",\n";
		oss << "      \"calibrated\": " << (it->second.calibrated ? "true" : "false") << ",\n";
		oss << "      \"detected\": " << (it->second.detected ? "true" : "false") << ",\n";
		oss << "      \"tag_id\": " << it->second.tagId << ",\n";
		oss << "      \"has_tag_xf\": " << (it->second.hasTagXf ? "true" : "false") << ",\n";
		oss << "      \"pose_x\": " << it->second.poseX << ",\n";
		oss << "      \"pose_y\": " << it->second.poseY << ",\n";
		oss << "      \"pose_z\": " << it->second.poseZ << ",\n";
		oss << "      \"pose_qx\": " << it->second.poseQx << ",\n";
		oss << "      \"pose_qy\": " << it->second.poseQy << ",\n";
		oss << "      \"pose_qz\": " << it->second.poseQz << ",\n";
		oss << "      \"pose_qw\": " << it->second.poseQw << ",\n";
		oss << "      \"pose_yaw\": " << it->second.poseYaw << ",\n";
		oss << "      \"odom_from_tag\": [";
		for(int i = 0; i < 7; ++i)
		{
			if(i) oss << ", ";
			oss << it->second.odomFromTag[i];
		}
		oss << "],\n";
		oss << "      \"tag_from_client\": [";
		for(int i = 0; i < 7; ++i)
		{
			if(i) oss << ", ";
			oss << it->second.tagFromClient[i];
		}
		oss << "],\n";
		oss << "      \"trail\": [";
		for(size_t i = 0; i < it->second.trail.size(); ++i)
		{
			if(i) oss << ", ";
			oss << "[" << it->second.trail[i].first << ", " << it->second.trail[i].second << "]";
		}
		oss << "],\n";
		oss << "      \"id_map\": {";
		size_t mi = 0;
		for(std::map<int, int>::const_iterator jt = it->second.localToGlobal.begin(); jt != it->second.localToGlobal.end(); ++jt, ++mi)
		{
			if(mi) oss << ", ";
			oss << "\"" << jt->first << "\": " << jt->second;
		}
		oss << "}\n";
		oss << "    }";
	}
	oss << "\n  }\n}\n";
	if(!writeFileAtomic(statePath_, oss.str()))
	{
		UERROR("Failed to write %s", statePath_.c_str());
		return false;
	}
	return true;
}

void CollabMap::syncIdsFromDatabase()
{
	rtabmap::DBDriver * db = rtabmap::DBDriver::create();
	if(!db->openConnection(globalDbPath_, false, true))
	{
		UWARN("Could not open %s to sync ids", globalDbPath_.c_str());
		delete db;
		return;
	}
	int lastId = 0;
	db->getLastNodeId(lastId);
	if(lastId + 1 > nextGlobalId_)
	{
		nextGlobalId_ = lastId + 1;
	}
	std::set<int> ids;
	db->getAllNodeIds(ids, false, false, false);
	globalNodes_ = static_cast<int>(ids.size());
	std::multimap<int, rtabmap::Link> links;
	db->getAllLinks(links, true, false);
	loopClosures_ = countLoopClosures(links);
	std::map<int, int> nodeMapId;
	for(std::set<int>::const_iterator it = ids.begin(); it != ids.end(); ++it)
	{
		int mapId = 0, weight = 0;
		std::string label;
		double stamp = 0.0;
		rtabmap::Transform odom, gt;
		std::vector<float> velocity;
		rtabmap::GPS gps;
		rtabmap::EnvSensors sensors;
		if(db->getNodeInfo(*it, odom, mapId, weight, label, stamp, gt, velocity, gps, sensors))
		{
			nodeMapId[*it] = mapId;
		}
	}
	interMapLc_ = countInterMapLoopsFromIds(links, nodeMapId);
	std::map<int, rtabmap::Transform> opt = db->loadOptimizedPoses();
	poses_ = opt.empty() ? globalNodes_ : static_cast<int>(opt.size());
	db->closeConnection(false);
	delete db;
}

rtabmap::ParametersMap combineParameters(const std::string & workDir)
{
	rtabmap::ParametersMap params;
	params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kMemIncrementalMemory(), "true"));
	params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kMemInitWMWithAllNodes(), "true"));
	params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kMemGenerateIds(), "true"));
	params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kMemUseOdomFeatures(), "false"));
	params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kMemRehearsalSimilarity(), "1.0"));
	params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kMemNotLinkedNodesKept(), "true"));
	params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kRGBDEnabled(), "true"));
	params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kRGBDLinearUpdate(), "0"));
	params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kRGBDAngularUpdate(), "0"));
	params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kRGBDOptimizeFromGraphEnd(), "false"));
	params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kRGBDNewMapOdomChangeDistance(), "0"));
	params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kRtabmapStartNewMapOnLoopClosure(), "false"));
	params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kRtabmapDetectionRate(), "0"));
	params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kRtabmapWorkingDirectory(), workDir));
	if(rtabmap::Optimizer::isAvailable(rtabmap::Optimizer::kTypeGTSAM))
	{
		params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kOptimizerStrategy(), "2"));
		params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kOptimizerGravitySigma(), "0.3"));
	}
	else if(rtabmap::Optimizer::isAvailable(rtabmap::Optimizer::kTypeG2O))
	{
		params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kOptimizerStrategy(), "1"));
		params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kOptimizerGravitySigma(), "0.3"));
	}
	return params;
}

bool CollabMap::ingestLocked(
	const std::string & clientId,
	int sinceId,
	const std::string & uploadDbPath,
	SyncResult & result)
{
	if(!isSqliteFile(uploadDbPath))
	{
		result.error = "upload is not a SQLite rtabmap database";
		return false;
	}

	ClientState & client = clients_[clientId];
	const int prevLastGlobal = client.localToGlobal.empty() ? 0 : client.localToGlobal.rbegin()->second;
	const int previousLc = loopClosures_;
	const bool firstAppearance = prevLastGlobal <= 0;

	rtabmap::Rtabmap rtabmap;
	try
	{
		rtabmap.init(combineParameters(dataDir_), globalDbPath_, false);
	}
	catch(const UException & e)
	{
		result.error = e.what();
		return false;
	}

	const rtabmap::Memory * mem = rtabmap.getMemory();
	std::map<int, rtabmap::Transform> prevOpt;
	if(mem)
	{
		rtabmap::Transform lastLoc;
		prevOpt = mem->loadOptimizedPoses(&lastLoc);
	}
	int lastWmId = 0;
	if(mem && mem->getLastWorkingSignature(false))
	{
		lastWmId = mem->getLastWorkingSignature(false)->id();
	}

	int continueMapId = client.sessionMapId;
	if(continueMapId < 0 && prevLastGlobal > 0)
	{
		rtabmap::Transform dummy;
		nodeInfo(mem, prevLastGlobal, dummy, continueMapId);
	}
	if(!firstAppearance && continueMapId >= 0)
	{
		rtabmap.setCurrentMapId(continueMapId);
		UINFO("Continue client map_id=%d client=%s prev_global=%d last_wm=%d (no triggerNewMap)",
			continueMapId, clientId.c_str(), prevLastGlobal, lastWmId);
	}
	else if(firstAppearance && globalNodes_ > 0)
	{
		UINFO("First appearance client=%s new map_id=%d last_wm=%d (no triggerNewMap)",
			clientId.c_str(), rtabmap.getCurrentMapId(), lastWmId);
	}

	// Official combine path used by rtabmap-reprocess: DBReader + Rtabmap::process.
	rtabmap::DBReader reader(
		uploadDbPath,
		0.0f,
		false,
		true,
		true,
		0,
		std::vector<unsigned int>(),
		0,
		false,
		false,
		true);
	if(!reader.init())
	{
		rtabmap.close(false);
		result.error = "cannot open uploaded database with DBReader";
		return false;
	}

	int accepted = 0;
	int firstNewGlobal = 0;
	std::ostringstream remapLog;
	while(true)
	{
		rtabmap::SensorCaptureInfo info;
		rtabmap::SensorData data = reader.takeImage(&info);
		if(data.id() <= 0)
		{
			break;
		}
		const int localId = data.id();
		if(localId <= sinceId && client.localToGlobal.find(localId) != client.localToGlobal.end())
		{
			continue;
		}
		if(client.localToGlobal.find(localId) != client.localToGlobal.end())
		{
			continue;
		}

		cv::Mat cov = info.odomCovariance;
		if(cov.empty())
		{
			cov = cv::Mat::eye(6, 6, CV_64FC1);
		}
		if(!rtabmap.process(data, info.odomPose, cov, info.odomVelocity))
		{
			UWARN("Rtabmap::process skipped local id %d from %s", localId, clientId.c_str());
			continue;
		}

		const int globalId = rtabmap.getLastLocationId();
		if(globalId <= 0)
		{
			continue;
		}
		client.localToGlobal[localId] = globalId;
		if(localId > client.lastLocalId)
		{
			client.lastLocalId = localId;
		}
		if(globalId + 1 > nextGlobalId_)
		{
			nextGlobalId_ = globalId + 1;
		}
		if(firstNewGlobal == 0)
		{
			firstNewGlobal = globalId;
		}
		if(accepted)
		{
			remapLog << ",";
		}
		remapLog << localId << "->" << globalId;
		++accepted;
	}

	int reconnects = 0;
	if(prevLastGlobal > 0 && firstNewGlobal > 0)
	{
		reconnects = reconnectClientChain(rtabmap, prevLastGlobal, firstNewGlobal);
	}

	// No detectMoreLoopClosures here: on a few hundred nodes it costs 3 to 13 s
	// per upload and made the 2 s phone cadence pile up. Rtabmap::process
	// already ran loop-closure detection for each new node; the wider search
	// runs in the throttled background pass (optimizeWorker). What must be
	// immediate is the start-tag constraint, so the first upload after a lock
	// already lands in the shared graph.
	int addedLc = 0;
	const int tagLinks = addTagConstraintsLocked(rtabmap);
	if(tagLinks > 0)
	{
		UINFO("Ingest added %d start-tag constraint link(s)", tagLinks);
	}

	if(firstAppearance && firstNewGlobal > 0 && globalNodes_ > 0)
	{
		UINFO("Skip identity first-appearance snap client=%s (tag frame or real LC only)",
			clientId.c_str());
	}

	const int memoryLc = memoryLoopClosures(rtabmap.getMemory());
	const int interMapLc = countInterMapLoops(rtabmap.getMemory());
	std::map<int, rtabmap::Transform> poses;
	std::multimap<int, rtabmap::Link> constraints;
	rtabmap.getGraph(poses, constraints, true, true, 0, false, false, false, false, false, false);
	fillMissingOdomPoses(rtabmap.getMemory(), poses);

	const bool keepPrevGraph = (memoryLc == 0 && previousLc > 0);
	if(keepPrevGraph)
	{
		for(std::map<int, rtabmap::Transform>::const_iterator it = prevOpt.begin(); it != prevOpt.end(); ++it)
		{
			if(!it->second.isNull())
			{
				poses[it->first] = it->second;
			}
		}
		fillMissingOdomPoses(rtabmap.getMemory(), poses);
		UWARN("Ingest kept previous optimized poses (%d) after lc drop %d -> 0",
			(int)prevOpt.size(), previousLc);
	}
	if(rtabmap.getMemory() && !poses.empty() && !keepPrevGraph)
	{
		rtabmap.getMemory()->saveOptimizedPoses(poses, rtabmap::Transform());
	}
	else if(rtabmap.getMemory() && keepPrevGraph && !prevOpt.empty())
	{
		std::map<int, rtabmap::Transform> merged = prevOpt;
		fillMissingOdomPoses(rtabmap.getMemory(), merged);
		rtabmap.getMemory()->saveOptimizedPoses(merged, rtabmap::Transform());
		poses = merged;
	}

	if(firstNewGlobal > 0)
	{
		rtabmap::Transform dummy;
		int usedMap = -1;
		if(nodeInfo(rtabmap.getMemory(), firstNewGlobal, dummy, usedMap) && usedMap >= 0)
		{
			client.sessionMapId = usedMap;
		}
	}
	else if(continueMapId >= 0)
	{
		client.sessionMapId = continueMapId;
	}

	const std::string mapIds = mapIdsSummary(rtabmap.getMemory());
	const bool tagLock = roomLocked_ && countCalibratedLocked() >= kLockPhonesRequired;
	const bool aligned = tagLock || interMapLc > 0;

	rtabmap.close(true);
	if(!poses.empty() && !persistOptimizedPoses(globalDbPath_, poses))
	{
		UWARN("Failed to persist %d optimized poses after ingest", (int)poses.size());
	}

	client.nodes = static_cast<int>(client.localToGlobal.size());
	client.lastSeen = static_cast<long>(std::time(0));
	if(client.hasTagXf && !client.localToGlobal.empty() &&
	   !shouldSkipGraphPoseLocked(client, static_cast<long>(std::time(0))))
	{
		const int gid = client.localToGlobal.rbegin()->second;
		std::map<int, rtabmap::Transform>::const_iterator pit = poses.find(gid);
		if(pit != poses.end() && !pit->second.isNull())
		{
			Eigen::Quaternionf pq = pit->second.getQuaternionf();
			applyTagPoseLocked(
				client,
				pit->second.x(), pit->second.y(), pit->second.z(),
				pq.x(), pq.y(), pq.z(), pq.w());
		}
	}
	globalNodes_ += accepted;
	cloudStale_ = true;
	lastIngestAt_ = static_cast<long>(std::time(0));
	if(static_cast<int>(poses.size()) > poses_)
	{
		poses_ = static_cast<int>(poses.size());
	}
	loopClosures_ = keepLoopClosures(previousLc, memoryLc);
	lastIngestAligned_ = aligned;
	interMapLc_ = interMapLc;
	result.accepted = accepted;
	result.lastLocalId = client.lastLocalId;
	result.globalNodes = globalNodes_;
	result.loopClosures = loopClosures_;
	saveState();

	UINFO("Ingest official DBReader+process client=%s accepted=%d remap=[%s] last_local=%d global_nodes=%d poses=%d lc=%d inter_map_lc=%d detectMore=%d reconnect=%d aligned=%d tag_lock=%d map_ids={%s}",
		clientId.c_str(), accepted, remapLog.str().c_str(), client.lastLocalId, globalNodes_,
		poses_, loopClosures_, interMapLc, addedLc, reconnects, aligned ? 1 : 0, tagLock ? 1 : 0, mapIds.c_str());
	return true;
}

void CollabMap::scheduleOptimize()
{
	optimizeAgain_.store(true);
	bool expected = false;
	if(!optimizeRunning_.compare_exchange_strong(expected, true))
	{
		return;
	}
	std::thread([this]() {
		optimizeWorker();
	}).detach();
}

void CollabMap::optimizeWorker()
{
	do
	{
		optimizeAgain_.store(false);
		std::string err;
		try
		{
			std::lock_guard<std::mutex> db(dbMutex_);
			// Fast path, every cycle: the live mesh from the poses ingest just
			// saved. This is what keeps the admin map within a couple of seconds
			// of the phones.
			std::string meshErr;
			if(!exportLiveMeshLocked(meshErr))
			{
				UWARN("Live organizedFastMesh export failed: %s", meshErr.c_str());
			}
			// The wider loop-closure search and pose refresh live in the
			// maintenance thread (bakeLoop / bakeOnce), which waits for a quiet
			// moment so it never stalls the next upload.
			(void)err;
		}
		catch(const UException & e)
		{
			UERROR("Background optimize exception: %s", e.what());
		}
		catch(const std::exception & e)
		{
			UERROR("Background optimize exception: %s", e.what());
		}
		catch(...)
		{
			UERROR("Background optimize unknown exception");
		}
		std::fflush(stdout);
		std::fflush(stderr);
	}
	while(optimizeAgain_.exchange(false));

	optimizeRunning_.store(false);
	if(optimizeAgain_.load())
	{
		bool expected = false;
		if(optimizeRunning_.compare_exchange_strong(expected, true))
		{
			optimizeWorker();
		}
	}
}

bool CollabMap::hasBakedMesh() const
{
	return plyFileHasFaces(bakedMeshPath_);
}

void CollabMap::scheduleBake()
{
	bakeAgain_.store(true);
	std::lock_guard<std::mutex> lock(bakeMutex_);
	bakeCv_.notify_one();
}

// Maintenance thread: the heavy pass (wider loop-closure search, pose refresh)
// holds the database lock for seconds on a few hundred nodes, so it must not
// sit in the ingest path. Run it when the phones have gone quiet for a moment,
// and otherwise at most once per kHeavyPassMaxIntervalSec so a long continuous
// walk still gets the wider search.
void CollabMap::bakeLoop()
{
	while(!bakeStop_.load())
	{
		bool forced = false;
		{
			std::unique_lock<std::mutex> lock(bakeMutex_);
			bakeCv_.wait_for(lock, std::chrono::seconds(2), [this]() {
				return bakeStop_.load() || bakeAgain_.load();
			});
			forced = bakeAgain_.exchange(false);
		}
		if(bakeStop_.load())
		{
			break;
		}
		bakeOnce(forced);
	}
}

void CollabMap::bakeOnce(bool forced)
{
	int nodes = 0;
	long lastIngest = 0;
	long lastHeavy = 0;
	int lastHeavyNodes = 0;
	{
		std::lock_guard<std::mutex> lock(mutex_);
		nodes = globalNodes_;
		lastIngest = lastIngestAt_;
		lastHeavy = lastHeavyPassAt_;
		lastHeavyNodes = lastBakedNodes_;
	}
	if(nodes <= 0)
	{
		return;
	}
	long lastBake = 0;
	int bakeMaxNode = 0;
	int maxNodeNow = 0;
	{
		std::lock_guard<std::mutex> lock(mutex_);
		lastBake = lastBakeAt_;
		bakeMaxNode = bakeMaxNodeId_;
		maxNodeNow = nextGlobalId_ - 1;
	}
	const long now = static_cast<long>(std::time(0));
	const bool newNodes = nodes != lastHeavyNodes;
	const bool idle = (now - lastIngest) >= kHeavyIdleSec;
	const bool minGap = (now - lastHeavy) >= kHeavyPassMinIntervalSec;
	const bool overdue = (now - lastHeavy) >= kHeavyPassMaxIntervalSec;
	const bool runHeavy = forced || (newNodes && ((idle && minGap) || overdue));

	// Pretty bake: same idea, slower cadence. Only when there is something new
	// since the last bake, the phones have paused a moment (or it is long
	// overdue), and never twice within kBakeMinIntervalSec.
	const bool bakeNew = maxNodeNow > bakeMaxNode;
	const bool bakeIdle = (now - lastIngest) >= kBakeIdleSec;
	const bool bakeGap = (now - lastBake) >= kBakeMinIntervalSec;
	const bool bakeOverdue = (now - lastBake) >= kBakeMaxIntervalSec;
	const bool runBake = bakeNew && bakeGap && (bakeIdle || bakeOverdue);
	if(!runHeavy && !runBake)
	{
		return;
	}
	bool expected = false;
	if(!bakeRunning_.compare_exchange_strong(expected, true))
	{
		return;
	}
	std::string err;
	try
	{
		if(runHeavy)
		{
			UTimer timer;
			{
				std::lock_guard<std::mutex> db(dbMutex_);
				if(!optimizeAndExport(err))
				{
					UWARN("Background optimize/export failed: %s", err.empty() ? "unknown" : err.c_str());
				}
			}
			{
				std::lock_guard<std::mutex> lock(mutex_);
				lastHeavyPassAt_ = static_cast<long>(std::time(0));
				lastBakedNodes_ = globalNodes_;
			}
			UINFO("Heavy pass done in %.2fs (idle=%d overdue=%d forced=%d nodes=%d)",
				timer.ticks(), idle ? 1 : 0, overdue ? 1 : 0, forced ? 1 : 0, nodes);
		}
		if(runBake)
		{
			std::string bakeErr;
			if(!bakeAndExport(bakeErr))
			{
				UWARN("Background bake failed: %s", bakeErr.empty() ? "unknown" : bakeErr.c_str());
				std::lock_guard<std::mutex> lock(mutex_);
				lastBakeAt_ = static_cast<long>(std::time(0));
			}
		}
	}
	catch(const UException & e)
	{
		UERROR("Heavy pass exception: %s", e.what());
	}
	catch(const std::exception & e)
	{
		UERROR("Heavy pass exception: %s", e.what());
	}
	catch(...)
	{
		UERROR("Heavy pass unknown exception");
	}
	std::fflush(stdout);
	std::fflush(stderr);
	bakeRunning_.store(false);
}

// The phone's post-stop "Assemble" (RTABMapApp::exportMesh optimized): voxel,
// viewpoint normals, Poisson, quadric decimation, color radius + clean, texture
// atlas sampled to vertices. Run periodically here so the admin view gets the
// same smooth surface the phone shows after a scan; the live per-node meshes
// stay on top for anything newer than the bake.
bool CollabMap::bakeAndExport(std::string & error)
{
	UTimer timer;
	std::map<int, rtabmap::Transform> poses;
	std::map<int, rtabmap::Signature> signatures;
	int maxNodeId = 0;
	int epoch = 0;
	{
		// Plain DBDriver read (no Rtabmap::init): poses plus node data, then
		// release the lock so uploads continue while Poisson runs.
		std::lock_guard<std::mutex> db(dbMutex_);
		{
			std::lock_guard<std::mutex> lock(mutex_);
			epoch = roomEpoch_;
		}
		if(!UFile::exists(globalDbPath_) || UFile::length(globalDbPath_) <= 0)
		{
			error = "no global.db";
			return false;
		}
		rtabmap::DBDriver * dbd = rtabmap::DBDriver::create();
		if(!dbd->openConnection(globalDbPath_, false, true))
		{
			error = "cannot open global.db for the bake";
			delete dbd;
			return false;
		}
		std::set<int> ids;
		dbd->getAllNodeIds(ids, false, false, false);
		poses = dbd->loadOptimizedPoses();
		std::map<int, rtabmap::Transform> odom;
		dbd->getAllOdomPoses(odom, false, false);
		std::list<int> idList;
		for(std::set<int>::const_iterator it = ids.begin(); it != ids.end(); ++it)
		{
			if(*it <= 0)
			{
				continue;
			}
			if(poses.find(*it) == poses.end())
			{
				std::map<int, rtabmap::Transform>::const_iterator ot = odom.find(*it);
				if(ot != odom.end() && !ot->second.isNull())
				{
					poses[*it] = ot->second;
				}
			}
			idList.push_back(*it);
			maxNodeId = std::max(maxNodeId, *it);
		}
		std::list<rtabmap::Signature *> loaded;
		dbd->loadSignatures(idList, loaded);
		if(!loaded.empty())
		{
			dbd->loadNodeData(loaded, true, false, false, false);
		}
		for(std::list<rtabmap::Signature *>::iterator it = loaded.begin(); it != loaded.end(); ++it)
		{
			if(*it)
			{
				signatures.insert(std::make_pair((*it)->id(), **it));
				delete *it;
			}
		}
		dbd->closeConnection(false);
		delete dbd;
		{
			std::lock_guard<std::mutex> lock(mutex_);
			alignPosesToTagFrame(poses);
		}
	}
	UINFO("Bake: loaded %d nodes in %.1fs, assembling", (int)signatures.size(), timer.ticks());

	pcl::PointCloud<pcl::PointXYZRGB> meshCloud;
	std::vector<pcl::Vertices> meshPolygons;
	TexturedBake textured;
	if(!exportAssembledMesh(poses, signatures, meshCloud, meshPolygons, &textured) ||
	   triangleCount(meshPolygons) == 0)
	{
		error = "assemble produced no faces";
		return false;
	}
	// Photo texture like the phone's Assemble when the atlas came out; vertex
	// colors otherwise.
	const bool useTexture = !textured.atlasBgr.empty() && triangleCount(textured.polygons) > 0;
	std::vector<unsigned char> jpeg;
	if(useTexture)
	{
		std::vector<int> jpegParams;
		jpegParams.push_back(cv::IMWRITE_JPEG_QUALITY);
		jpegParams.push_back(88);
		if(!cv::imencode(".jpg", textured.atlasBgr, jpeg, jpegParams))
		{
			jpeg.clear();
		}
	}
	const bool texturedOut = useTexture && !jpeg.empty();
	{
		// Publish under the db lock so a reset cannot interleave with the write.
		std::lock_guard<std::mutex> db(dbMutex_);
		std::lock_guard<std::mutex> lock(mutex_);
		if(epoch != roomEpoch_)
		{
			error = "room was reset during the bake; result dropped";
			return false;
		}
		bool wrote = false;
		if(texturedOut)
		{
			const std::string tmpJpg = bakedAtlasPath_ + ".tmp";
			FILE * jf = std::fopen(tmpJpg.c_str(), "wb");
			bool jpgOk = jf != 0;
			if(jf)
			{
				jpgOk = std::fwrite(jpeg.data(), 1, jpeg.size(), jf) == jpeg.size();
				std::fclose(jf);
			}
			if(jpgOk)
			{
				UFile::erase(bakedAtlasPath_);
				jpgOk = UFile::rename(tmpJpg, bakedAtlasPath_) == 0;
			}
			else
			{
				UFile::erase(tmpJpg);
			}
			wrote = jpgOk && writeTexturedMeshFile(
				bakedMeshPath_, textured.cloud, textured.uv, textured.polygons,
				"rtabmap-collab exportMesh assemble textured");
		}
		if(!wrote)
		{
			UFile::erase(bakedAtlasPath_);
			wrote = writeViewerMeshFile(
				bakedMeshPath_, meshCloud, meshPolygons,
				"rtabmap-collab exportMesh assemble");
		}
		if(!wrote)
		{
			error = "write baked mesh failed";
			return false;
		}
		bakeTextured_ = texturedOut && UFile::exists(bakedAtlasPath_);
		std::ofstream meta((bakedMeshPath_ + ".meta").c_str(), std::ios::trunc);
		meta << maxNodeId << " " << (bakeTextured_ ? 1 : 0) << "\n";
		++bakeGen_;
		bakeMaxNodeId_ = maxNodeId;
		lastBakeAt_ = static_cast<long>(std::time(0));
	}
	if(texturedOut)
	{
		UINFO("Bake: wrote textured %s verts=%d faces=%d atlas=%dx%d jpeg=%dKB up to node %d in %.1fs",
			bakedMeshPath_.c_str(), (int)textured.cloud.size(), (int)triangleCount(textured.polygons),
			textured.atlasBgr.cols, textured.atlasBgr.rows, (int)(jpeg.size() / 1024), maxNodeId, timer.elapsed());
	}
	else
	{
		UINFO("Bake: wrote %s verts=%d faces=%d (vertex colors) up to node %d in %.1fs",
			bakedMeshPath_.c_str(), (int)meshCloud.size(), (int)meshPolygons.size(), maxNodeId, timer.elapsed());
	}
	return true;
}

int CollabMap::addTagConstraints(rtabmap::Rtabmap & rtabmap)
{
	std::lock_guard<std::mutex> lock(mutex_);
	return addTagConstraintsLocked(rtabmap);
}

int CollabMap::addTagConstraintsLocked(rtabmap::Rtabmap & rtabmap)
{
	if(!rtabmap.getMemory())
	{
		return 0;
	}
	struct Locked
	{
		std::string id;
		int firstGid;
		rtabmap::Transform gFromWorld;
	};
	std::vector<Locked> locked;
	if(!roomLocked_)
	{
		return 0;
	}
	for(std::map<std::string, ClientState>::const_iterator it = clients_.begin(); it != clients_.end(); ++it)
	{
		const ClientState & c = it->second;
		if(!c.calibrated || !c.detected || !c.hasTagXf || c.tagId != kDemoTagId || c.localToGlobal.empty())
		{
			continue;
		}
		rtabmap::Transform xf(
			c.tagFromClient[0], c.tagFromClient[1], c.tagFromClient[2],
			c.tagFromClient[3], c.tagFromClient[4], c.tagFromClient[5], c.tagFromClient[6]);
		if(xf.isNull())
		{
			continue;
		}
		int firstGid = 0;
		for(std::map<int, int>::const_iterator jt = c.localToGlobal.begin(); jt != c.localToGlobal.end(); ++jt)
		{
			if(jt->second > 0 && (firstGid == 0 || jt->second < firstGid))
			{
				firstGid = jt->second;
			}
		}
		if(firstGid <= 0)
		{
			continue;
		}
		Locked l;
		l.id = it->first;
		l.firstGid = firstGid;
		l.gFromWorld = xf;
		locked.push_back(l);
	}
	if(locked.size() < 2)
	{
		return 0;
	}
	const int existingInter = countInterMapLoops(rtabmap.getMemory());
	if(existingInter > 0)
	{
		// Already connected (visual closure or an earlier tag link).
		return 0;
	}
	// Root: the session that owns the lowest global node id.
	size_t rootIdx = 0;
	for(size_t i = 1; i < locked.size(); ++i)
	{
		if(locked[i].firstGid < locked[rootIdx].firstGid)
		{
			rootIdx = i;
		}
	}
	// Both sessions are still in their own frames, so a node's graph pose is
	// its odometry pose (up to intra-session optimization) and each client's
	// T_G_from_world applies directly. Prefer the optimized pose, fall back to
	// the stored odometry pose.
	const std::map<int, rtabmap::Transform> & optimized = rtabmap.getLocalOptimizedPoses();
	const rtabmap::Memory * mem = rtabmap.getMemory();
	auto poseOf = [&](int id, rtabmap::Transform & out) -> bool
	{
		std::map<int, rtabmap::Transform>::const_iterator it = optimized.find(id);
		if(it != optimized.end() && !it->second.isNull())
		{
			out = it->second;
			return true;
		}
		int mapId = -1;
		return nodeInfo(mem, id, out, mapId) && !out.isNull();
	};
	rtabmap::Transform rootPose;
	if(!poseOf(locked[rootIdx].firstGid, rootPose))
	{
		UWARN("Tag constraint: root node %d has no pose", locked[rootIdx].firstGid);
		return 0;
	}
	const rtabmap::Transform rootInG = locked[rootIdx].gFromWorld * rootPose;
	// Tag pose noise: a few cm and a couple of degrees at 1 m.
	cv::Mat information = cv::Mat::eye(6, 6, CV_64FC1);
	information.at<double>(0, 0) = information.at<double>(1, 1) = information.at<double>(2, 2) = 1.0 / (0.05 * 0.05);
	information.at<double>(3, 3) = information.at<double>(4, 4) = information.at<double>(5, 5) = 1.0 / (0.05 * 0.05);
	// Rtabmap::addLink rejects a link when the worst residual anywhere in the
	// graph exceeds RGBD/OptimizeMaxError. That guards hypothesized visual
	// closures; it also trips on residuals that already exist inside a session
	// and have nothing to do with this measured link. Disable it for the tag
	// link only, then restore so detectMoreLoopClosures keeps the guard.
	std::string previousMaxError = uNumber2Str(rtabmap::Parameters::defaultRGBDOptimizeMaxError());
	{
		rtabmap::ParametersMap::const_iterator it = rtabmap.getParameters().find(rtabmap::Parameters::kRGBDOptimizeMaxError());
		if(it != rtabmap.getParameters().end())
		{
			previousMaxError = it->second;
		}
	}
	{
		rtabmap::ParametersMap relax;
		relax.insert(rtabmap::ParametersPair(rtabmap::Parameters::kRGBDOptimizeMaxError(), "0"));
		rtabmap.parseParameters(relax);
	}
	int accepted = 0;
	for(size_t i = 0; i < locked.size(); ++i)
	{
		if(i == rootIdx)
		{
			continue;
		}
		rtabmap::Transform otherPose;
		if(!poseOf(locked[i].firstGid, otherPose))
		{
			UWARN("Tag constraint: node %d has no pose", locked[i].firstGid);
			continue;
		}
		const rtabmap::Transform otherInG = locked[i].gFromWorld * otherPose;
		const rtabmap::Transform rel = rootInG.inverse() * otherInG;
		if(rel.isNull())
		{
			continue;
		}
		rtabmap::Link link(locked[rootIdx].firstGid, locked[i].firstGid, rtabmap::Link::kUserClosure, rel, information);
		bool ok = false;
		try
		{
			ok = rtabmap.addLink(link);
		}
		catch(const UException & e)
		{
			UWARN("Tag constraint %d -> %d threw: %s", link.from(), link.to(), e.what());
			ok = false;
		}
		if(ok)
		{
			++accepted;
			UINFO("Tag constraint accepted %d -> %d (%s -> %s) rel=%s",
				link.from(), link.to(), locked[rootIdx].id.c_str(), locked[i].id.c_str(), rel.prettyPrint().c_str());
		}
		else
		{
			UWARN("Tag constraint rejected %d -> %d (%s -> %s); sessions stay separate in the graph",
				link.from(), link.to(), locked[rootIdx].id.c_str(), locked[i].id.c_str());
		}
	}
	{
		rtabmap::ParametersMap restore;
		restore.insert(rtabmap::ParametersPair(rtabmap::Parameters::kRGBDOptimizeMaxError(), previousMaxError));
		rtabmap.parseParameters(restore);
	}
	return accepted;
}

bool CollabMap::optimizeAndExport(std::string & error)
{
	rtabmap::Rtabmap rtabmap;
	try
	{
		rtabmap.init(combineParameters(dataDir_), globalDbPath_, false);
	}
	catch(const UException & e)
	{
		error = e.what();
		return false;
	}

	int previousLc = 0;
	{
		std::lock_guard<std::mutex> lock(mutex_);
		previousLc = loopClosures_;
	}
	std::map<int, rtabmap::Transform> prevOpt;
	if(rtabmap.getMemory())
	{
		rtabmap::Transform lastLoc;
		prevOpt = rtabmap.getMemory()->loadOptimizedPoses(&lastLoc);
	}

	// Start-tag constraint: with both phones locked on the tag the server
	// knows the measured relative pose between their sessions. Feed it into
	// the graph as a real link (Rtabmap::addLink optimizes and rejects on max
	// error) so the merged map.db, /pull poses, and the live mesh all share
	// one frame, and detectMoreLoopClosures can test cross-session pairs that
	// are now physically adjacent. Only when no cross-map link exists yet.
	const int tagLinks = addTagConstraints(rtabmap);
	if(tagLinks > 0)
	{
		UINFO("Added %d start-tag constraint link(s) between sessions", tagLinks);
	}

	int added = 0;
	try
	{
		// One iteration: this runs in the throttled background pass while
		// uploads wait on the database lock, and it re-optimizes the whole graph.
		added = rtabmap.detectMoreLoopClosures(5.0f, static_cast<float>(M_PI / 6.0), 1, true, true);
	}
	catch(const UException & e)
	{
		error = e.what();
		UERROR("detectMoreLoopClosures exception: %s", e.what());
		rtabmap.close(false);
		return false;
	}
	if(added < 0)
	{
		UWARN("detectMoreLoopClosures returned %d", added);
	}
	else
	{
		UINFO("detectMoreLoopClosures added %d constraint(s)", added);
	}

	const int memoryLc = memoryLoopClosures(rtabmap.getMemory());
	const int interMapLc = countInterMapLoops(rtabmap.getMemory());
	std::map<int, rtabmap::Transform> poses;
	std::multimap<int, rtabmap::Link> constraints;
	// Poses and links only. Node data is not needed here: the live mesh comes
	// from the node cache and the cloud / PLY downloads are built on demand.
	rtabmap.getGraph(poses, constraints, true, true, 0, false, false, false, false, false, false);
	fillMissingOdomPoses(rtabmap.getMemory(), poses);

	const bool keepPrevGraph = (memoryLc == 0 && previousLc > 0);
	if(keepPrevGraph)
	{
		poses = prevOpt;
		fillMissingOdomPoses(rtabmap.getMemory(), poses);
		UWARN("optimizeAndExport kept previous poses/LCs (reported lc=0, stored lc=%d)", previousLc);
	}
	if(rtabmap.getMemory() && !poses.empty())
	{
		rtabmap.getMemory()->saveOptimizedPoses(poses, rtabmap::Transform());
	}
	UINFO("optimizeAndExport detectMore=%d memory_lc=%d inter_map_lc=%d poses=%d map_ids={%s}",
		added, memoryLc, interMapLc, (int)poses.size(), mapIdsSummary(rtabmap.getMemory()).c_str());

	const int newPoses = static_cast<int>(poses.size());
	const int persistLc = keepLoopClosures(previousLc, memoryLc);
	std::map<int, rtabmap::Transform> assemblePoses = poses;
	{
		std::lock_guard<std::mutex> lock(mutex_);
		lastIngestAligned_ = (roomLocked_ && countCalibratedLocked() >= kLockPhonesRequired) || interMapLc > 0;
		interMapLc_ = interMapLc;
		alignPosesToTagFrame(assemblePoses);
		poses_ = newPoses;
		loopClosures_ = persistLc;
		if(newPoses > globalNodes_)
		{
			globalNodes_ = newPoses;
		}
		const long poseNow = static_cast<long>(std::time(0));
		for(std::map<std::string, ClientState>::iterator it = clients_.begin(); it != clients_.end(); ++it)
		{
			ClientState & client = it->second;
			if(!client.hasTagXf || client.localToGlobal.empty() ||
			   shouldSkipGraphPoseLocked(client, poseNow))
			{
				continue;
			}
			const int gid = client.localToGlobal.rbegin()->second;
			std::map<int, rtabmap::Transform>::const_iterator pit = poses.find(gid);
			if(pit != poses.end() && !pit->second.isNull())
			{
				Eigen::Quaternionf pq = pit->second.getQuaternionf();
				applyTagPoseLocked(
					client,
					pit->second.x(), pit->second.y(), pit->second.z(),
					pq.x(), pq.y(), pq.z(), pq.w());
			}
		}
		saveState();
	}

	rtabmap.close(true);
	if(!poses.empty() && !persistOptimizedPoses(globalDbPath_, poses))
	{
		UWARN("Failed to persist %d optimized poses after optimizeAndExport", (int)poses.size());
	}
	// Poses may have moved: re-place the cached node meshes (fast) and mark the
	// downloadable cloud / PLY stale so GET /map.ply rebuilds them on demand.
	{
		std::string meshErr;
		if(!exportLiveMeshLocked(meshErr))
		{
			UWARN("Live mesh refresh after optimize failed: %s", meshErr.c_str());
		}
	}
	{
		std::lock_guard<std::mutex> lock(mutex_);
		cloudStale_ = true;
	}
	(void)assemblePoses;
	return error.empty();
}

namespace {

void fillXyzQuat(const rtabmap::Transform & t, float out[7])
{
	Eigen::Quaternionf q = t.getQuaternionf();
	out[0] = t.x();
	out[1] = t.y();
	out[2] = t.z();
	out[3] = q.x();
	out[4] = q.y();
	out[5] = q.z();
	out[6] = q.w();
}

}

PullResult CollabMap::exportPull(const std::string & clientId, int sinceGlobalId, const std::string & destDbPath)
{
	PullResult result;
	ClientState clientCopy;
	bool haveClient = false;
	bool roomLocked = false;
	{
		std::lock_guard<std::mutex> lock(mutex_);
		result.maxGlobalId = std::max(0, nextGlobalId_ - 1);
		result.loopClosures = loopClosures_;
		roomLocked = roomLocked_;
		std::map<std::string, ClientState>::const_iterator it = clients_.find(clientId);
		if(it != clients_.end())
		{
			clientCopy = it->second;
			haveClient = true;
		}
	}

	if(destDbPath.empty())
	{
		result.ok = false;
		result.error = "missing pull dest path";
		return result;
	}

	if(!UFile::exists(globalDbPath_) || UFile::length(globalDbPath_) <= 0)
	{
		result.ok = true;
		result.maxGlobalId = 0;
		return result;
	}

	std::lock_guard<std::mutex> db(dbMutex_);

	rtabmap::DBDriver * src = rtabmap::DBDriver::create();
	if(!src->openConnection(globalDbPath_, false, true))
	{
		delete src;
		result.ok = false;
		result.error = "cannot open global.db";
		return result;
	}

	std::set<int> allIds;
	src->getAllNodeIds(allIds, false, false, false);
	int lastId = 0;
	src->getLastNodeId(lastId);
	if(lastId > result.maxGlobalId)
	{
		result.maxGlobalId = lastId;
	}

	std::set<int> ownGlobal;
	if(haveClient)
	{
		for(std::map<int, int>::const_iterator it = clientCopy.localToGlobal.begin(); it != clientCopy.localToGlobal.end(); ++it)
		{
			if(it->second > 0)
			{
				ownGlobal.insert(it->second);
			}
		}
	}

	std::list<int> newIds;
	for(std::set<int>::const_iterator it = allIds.begin(); it != allIds.end(); ++it)
	{
		if(*it > sinceGlobalId && ownGlobal.find(*it) == ownGlobal.end())
		{
			newIds.push_back(*it);
		}
	}

	std::map<int, rtabmap::Transform> optPoses = src->loadOptimizedPoses();
	result.posesCount = optPoses.empty() ? static_cast<int>(allIds.size()) : static_cast<int>(optPoses.size());

	std::multimap<int, rtabmap::Link> links;
	src->getAllLinks(links, true, false);
	result.loopClosures = countLoopClosures(links);
	std::map<int, int> nodeMapId;
	{
		std::lock_guard<std::mutex> lock(mutex_);
		for(std::map<std::string, ClientState>::const_iterator it = clients_.begin(); it != clients_.end(); ++it)
		{
			if(it->second.sessionMapId < 0)
			{
				continue;
			}
			for(std::map<int, int>::const_iterator jt = it->second.localToGlobal.begin();
				jt != it->second.localToGlobal.end(); ++jt)
			{
				if(jt->second > 0)
				{
					nodeMapId[jt->second] = it->second.sessionMapId;
				}
			}
		}
	}
	const int interMapLc = countInterMapLoopsFromIds(links, nodeMapId);
	const bool tagLock = roomLocked && haveClient && clientCopy.detected &&
		clientCopy.hasTagXf && clientCopy.tagId == kDemoTagId;
	result.aligned = interMapLc > 0 || tagLock;

	if(haveClient && !clientCopy.localToGlobal.empty())
	{
		int localId = clientCopy.lastLocalId;
		std::map<int, int>::const_iterator mapIt = clientCopy.localToGlobal.find(localId);
		if(mapIt == clientCopy.localToGlobal.end())
		{
			mapIt = clientCopy.localToGlobal.end();
			--mapIt;
			localId = mapIt->first;
		}
		const int globalId = mapIt->second;
		rtabmap::Transform pLocal;
		rtabmap::Transform pOpt;
		std::map<int, rtabmap::Transform>::const_iterator poseIt = optPoses.find(globalId);
		if(poseIt != optPoses.end() && !poseIt->second.isNull())
		{
			pOpt = poseIt->second;
		}

		std::list<int> oneId;
		oneId.push_back(globalId);
		std::list<rtabmap::Signature *> oneSig;
		src->loadSignatures(oneId, oneSig);
		if(!oneSig.empty() && oneSig.front())
		{
			pLocal = oneSig.front()->getPose();
			delete oneSig.front();
		}
		if(!pLocal.isNull() && !pOpt.isNull())
		{
			rtabmap::Transform localFromGlobal = pLocal * pOpt.inverse();
			if(!localFromGlobal.isNull())
			{
				fillXyzQuat(localFromGlobal, result.localFromGlobal);
				result.hasTransform = true;
			}
		}
		else if(!pLocal.isNull())
		{
			fillXyzQuat(rtabmap::Transform::getIdentity(), result.localFromGlobal);
			result.hasTransform = true;
		}
	}

	if(haveClient && clientCopy.detected && clientCopy.hasTagXf && clientCopy.tagId == kDemoTagId)
	{
		// The pull db poses are in G. The phone composes localFromGlobal * pose
		// with its own rtabmap-world poses, so send T_clientRtabmapWorld_from_G.
		rtabmap::Transform tagFromClient(
			clientCopy.tagFromClient[0], clientCopy.tagFromClient[1], clientCopy.tagFromClient[2],
			clientCopy.tagFromClient[3], clientCopy.tagFromClient[4], clientCopy.tagFromClient[5], clientCopy.tagFromClient[6]);
		if(!tagFromClient.isNull())
		{
			fillXyzQuat(tagFromClient.inverse(), result.localFromGlobal);
			result.hasTransform = true;
		}
	}

	{
		std::lock_guard<std::mutex> lock(mutex_);
		alignPosesToTagFrame(optPoses);
	}

	UFile::erase(destDbPath);
	rtabmap::DBDriver * dst = rtabmap::DBDriver::create();
	if(!dst->openConnection(destDbPath, true, false))
	{
		src->closeConnection(false);
		delete src;
		delete dst;
		result.ok = false;
		result.error = "cannot create pull delta db";
		return result;
	}

	if(!newIds.empty())
	{
		std::list<rtabmap::Signature *> signatures;
		src->loadSignatures(newIds, signatures);
		if(!signatures.empty())
		{
			src->loadNodeData(signatures, true, true, true, true);
		}
		int accepted = 0;
		for(std::list<rtabmap::Signature *>::iterator it = signatures.begin(); it != signatures.end(); ++it)
		{
			if(*it == 0)
			{
				continue;
			}
			(*it)->setSaved(false);
			(*it)->setModified(true);
			dst->asyncSave(*it);
			++accepted;
		}
		dst->emptyTrashes(false);
		result.nodesCount = accepted;
	}

	if(!optPoses.empty())
	{
		dst->saveOptimizedPoses(optPoses, rtabmap::Transform());
	}
	else if(!allIds.empty())
	{
		std::map<int, rtabmap::Transform> fallback;
		std::list<int> idList(allIds.begin(), allIds.end());
		std::list<rtabmap::Signature *> poseSigs;
		src->loadSignatures(idList, poseSigs);
		for(std::list<rtabmap::Signature *>::iterator it = poseSigs.begin(); it != poseSigs.end(); ++it)
		{
			if(*it)
			{
				if(!(*it)->getPose().isNull())
				{
					fallback[(*it)->id()] = (*it)->getPose();
				}
				delete *it;
			}
		}
		if(!fallback.empty())
		{
			dst->saveOptimizedPoses(fallback, rtabmap::Transform());
			result.posesCount = static_cast<int>(fallback.size());
		}
	}

	dst->closeConnection(true);
	delete dst;
	src->closeConnection(false);
	delete src;

	if(!result.aligned && result.nodesCount > 0)
	{
		UINFO("GET /pull: remote nodes=%d max_id=%d aligned=0 (need inter-session loop closure)",
			result.nodesCount, result.maxGlobalId);
	}
	else
	{
		UINFO("GET /pull: remote nodes=%d poses=%d max_id=%d aligned=%d",
			result.nodesCount, result.posesCount, result.maxGlobalId, result.aligned ? 1 : 0);
	}
	std::fflush(stdout);
	return result;
}

bool CollabMap::writeDemoDeltaDb(
	const std::string & path,
	int localId,
	float x, float y, float z,
	std::string & error)
{
	if(path.empty())
	{
		error = "missing path";
		return false;
	}
	UFile::erase(path);
	rtabmap::ParametersMap params;
	params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kMemIncrementalMemory(), "true"));
	params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kMemGenerateIds(), "false"));
	params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kRGBDEnabled(), "true"));
	params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kRtabmapWorkingDirectory(), UDirectory::getDir(path)));
	rtabmap::Rtabmap rtabmap;
	try
	{
		rtabmap.init(params, path, false);
	}
	catch(const UException & e)
	{
		error = e.what();
		return false;
	}
	// A frame that meshes: 128x96, a wall ~0.8 m away tilted so depth varies,
	// checkerboard colors. Small enough to sync in one request, big enough for
	// organizedFastMesh and the Poisson bake to produce faces in the tests.
	const int w = 128;
	const int h = 96;
	cv::Mat rgb(h, w, CV_8UC3);
	cv::Mat depth(h, w, CV_16UC1);
	for(int v = 0; v < h; ++v)
	{
		for(int u = 0; u < w; ++u)
		{
			const bool light = ((u / 16) + (v / 16)) % 2 == 0;
			rgb.at<cv::Vec3b>(v, u) = light ? cv::Vec3b(200, 190, 170) : cv::Vec3b(70, 90, 120);
			// 0.7 m at the left edge to 0.95 m at the right edge (mm).
			depth.at<unsigned short>(v, u) = static_cast<unsigned short>(700 + (250 * u) / (w - 1));
		}
	}
	rtabmap::CameraModel model(100.0, 100.0, w / 2.0, h / 2.0, rtabmap::Transform::getIdentity(), 0, cv::Size(w, h));
	rtabmap::SensorData data(rgb, depth, model, localId > 0 ? localId : 1, 1.0);
	if(!rtabmap.process(data, rtabmap::Transform(x, y, z, 0, 0, 0, 1)))
	{
		rtabmap.close(false);
		error = "process failed";
		return false;
	}
	rtabmap.close(true);
	return true;
}

std::string CollabMap::makeDirRecursive(const std::string & path)
{
	if(path.empty())
	{
		return "";
	}
	if(UDirectory::exists(path))
	{
		return path;
	}
	std::string parent = UDirectory::getDir(path);
	if(!parent.empty() && parent != path && parent != "." && !UDirectory::exists(parent))
	{
		if(makeDirRecursive(parent).empty())
		{
			return "";
		}
	}
	if(!UDirectory::makeDir(path) && !UDirectory::exists(path))
	{
		return "";
	}
	return path;
}

}
