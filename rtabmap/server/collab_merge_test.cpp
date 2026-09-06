// Server-side collab merge harness.
//
// Proves CollabMap ingest + official DBReader+Rtabmap::process + same-client
// continuation + inter-session merge on a FRESH temp room. Never writes the
// live LaunchAgent data dir.
//
// Re-run (from repo root, after a collab-server build):
//   cmake --build build --target rtabmap-collab-merge-test
//   ./build/bin/rtabmap-collab-merge-test \
//       --source ./collab-data \
//       --server ./build/bin/rtabmap-collab-server
//
// Optional: --skip-http   --port 18765   --work /tmp/collab-merge-test

#include "CollabMap.h"

#include <rtabmap/core/DBDriver.h>
#include <rtabmap/core/EnvSensor.h>
#include <rtabmap/core/GPS.h>
#include <rtabmap/core/Link.h>
#include <rtabmap/core/Transform.h>
#include <rtabmap/utilite/UDirectory.h>
#include <rtabmap/utilite/UFile.h>
#include <rtabmap/utilite/ULogger.h>

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

namespace {

int gPass = 0;
int gFail = 0;
int gSkip = 0;
bool gVisualLcProven = false;
std::string gVisualLcNote;

void check(bool cond, const std::string & name, const std::string & detail)
{
	if(cond)
	{
		++gPass;
		std::cout << "PASS  " << name;
	}
	else
	{
		++gFail;
		std::cout << "FAIL  " << name;
	}
	if(!detail.empty())
	{
		std::cout << "  (" << detail << ")";
	}
	std::cout << "\n";
}

void skip(const std::string & name, const std::string & detail)
{
	++gSkip;
	std::cout << "SKIP  " << name;
	if(!detail.empty())
	{
		std::cout << "  (" << detail << ")";
	}
	std::cout << "\n";
}

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

int runCmd(const std::string & cmd)
{
	std::cout << "+ " << cmd << "\n";
	std::cout.flush();
	return std::system(cmd.c_str());
}

std::string runOut(const std::string & cmd)
{
	std::string wrapped = cmd + " 2>/dev/null";
	FILE * p = popen(wrapped.c_str(), "r");
	if(!p)
	{
		return "";
	}
	std::string out;
	char buf[4096];
	while(fgets(buf, sizeof(buf), p))
	{
		out += buf;
	}
	pclose(p);
	return out;
}

bool sqliteOk(const std::string & db, const std::string & sql)
{
	std::ostringstream cmd;
	cmd << "sqlite3 \"" << db << "\" \"" << sql << "\"";
	return runCmd(cmd.str()) == 0;
}

std::string sqliteScalar(const std::string & db, const std::string & sql)
{
	std::ostringstream cmd;
	cmd << "sqlite3 \"" << db << "\" \"" << sql << "\"";
	std::string out = runOut(cmd.str());
	while(!out.empty() && (out.back() == '\n' || out.back() == '\r'))
	{
		out.pop_back();
	}
	return out;
}

int sqliteInt(const std::string & db, const std::string & sql, int def = 0)
{
	std::string s = sqliteScalar(db, sql);
	if(s.empty())
	{
		return def;
	}
	return std::atoi(s.c_str());
}

std::vector<int> parseIntList(const std::string & text)
{
	std::vector<int> ids;
	std::string cur;
	for(size_t i = 0; i <= text.size(); ++i)
	{
		const char c = i < text.size() ? text[i] : ',';
		if(c >= '0' && c <= '9')
		{
			cur.push_back(c);
		}
		else if(!cur.empty())
		{
			ids.push_back(std::atoi(cur.c_str()));
			cur.clear();
		}
	}
	std::sort(ids.begin(), ids.end());
	ids.erase(std::unique(ids.begin(), ids.end()), ids.end());
	return ids;
}

struct ClientFixture
{
	std::string id;
	std::vector<int> nodeIds;
};

bool looksLikeClientId(const std::string & name)
{
	// Phone UUIDs are 8-4-4-4-12. Reject ordinary JSON keys.
	int dashes = 0;
	for(size_t i = 0; i < name.size(); ++i)
	{
		if(name[i] == '-')
		{
			++dashes;
		}
	}
	return dashes >= 2 && name.size() >= 16;
}

std::vector<int> parseIdMapGlobals(const std::string & body)
{
	std::vector<int> globals;
	size_t i = 0;
	while(i < body.size())
	{
		size_t colon = body.find(':', i);
		if(colon == std::string::npos)
		{
			break;
		}
		size_t j = colon + 1;
		while(j < body.size() && (body[j] == ' ' || body[j] == '\t'))
		{
			++j;
		}
		int v = 0;
		bool any = false;
		while(j < body.size() && body[j] >= '0' && body[j] <= '9')
		{
			any = true;
			v = v * 10 + (body[j] - '0');
			++j;
		}
		if(any)
		{
			globals.push_back(v);
		}
		i = j;
	}
	std::sort(globals.begin(), globals.end());
	globals.erase(std::unique(globals.begin(), globals.end()), globals.end());
	return globals;
}

std::vector<ClientFixture> parseClientsJson(const std::string & text)
{
	std::vector<ClientFixture> clients;
	size_t pos = 0;
	while(true)
	{
		size_t key = text.find('"', pos);
		if(key == std::string::npos)
		{
			break;
		}
		size_t keyEnd = text.find('"', key + 1);
		if(keyEnd == std::string::npos)
		{
			break;
		}
		const std::string name = text.substr(key + 1, keyEnd - key - 1);
		if(!looksLikeClientId(name))
		{
			pos = keyEnd + 1;
			continue;
		}
		size_t mapPos = text.find("\"id_map\"", keyEnd);
		if(mapPos == std::string::npos)
		{
			break;
		}
		size_t brace = text.find('{', mapPos);
		size_t close = brace == std::string::npos ? std::string::npos : text.find('}', brace);
		if(close == std::string::npos)
		{
			break;
		}
		ClientFixture c;
		c.id = name;
		c.nodeIds = parseIdMapGlobals(text.substr(brace, close - brace + 1));
		if(!c.nodeIds.empty())
		{
			clients.push_back(c);
		}
		pos = close + 1;
	}
	std::sort(clients.begin(), clients.end(), [](const ClientFixture & a, const ClientFixture & b) {
		return a.nodeIds.front() < b.nodeIds.front();
	});
	return clients;
}

std::string joinIds(const std::vector<int> & ids)
{
	std::ostringstream oss;
	for(size_t i = 0; i < ids.size(); ++i)
	{
		if(i)
		{
			oss << ",";
		}
		oss << ids[i];
	}
	return oss.str();
}

bool extractSubsetDb(const std::string & src, const std::string & dest, const std::vector<int> & ids)
{
	if(ids.empty())
	{
		return false;
	}
	UFile::erase(dest);
	std::ostringstream backup;
	backup << "sqlite3 \"" << src << "\" \".backup '" << dest << "'\"";
	if(runCmd(backup.str()) != 0)
	{
		return false;
	}
	const std::string list = joinIds(ids);
	std::ostringstream sql;
	sql << "DELETE FROM Feature WHERE node_id NOT IN (" << list << ");"
		<< "DELETE FROM GlobalDescriptor WHERE node_id NOT IN (" << list << ");"
		<< "DELETE FROM Statistics WHERE id NOT IN (" << list << ");"
		<< "DELETE FROM Data WHERE id NOT IN (" << list << ");"
		<< "DELETE FROM Link WHERE from_id NOT IN (" << list << ") OR to_id NOT IN (" << list << ");"
		<< "DELETE FROM Node WHERE id NOT IN (" << list << ");"
		<< "DELETE FROM Word WHERE id NOT IN (SELECT DISTINCT word_id FROM Feature);"
		<< "UPDATE Node SET map_id = 0;"
		<< "UPDATE Admin SET opt_cloud=NULL, opt_ids=NULL, opt_poses=NULL, opt_last_localization=NULL;"
		<< "VACUUM;";
	if(!sqliteOk(dest, sql.str()))
	{
		return false;
	}
	const int n = sqliteInt(dest, "SELECT COUNT(*) FROM Node;");
	return n == static_cast<int>(ids.size());
}

void splitHalves(const std::vector<int> & ids, std::vector<int> & a, std::vector<int> & b)
{
	a.clear();
	b.clear();
	if(ids.size() < 2)
	{
		a = ids;
		return;
	}
	const size_t mid = ids.size() / 2;
	a.assign(ids.begin(), ids.begin() + mid);
	b.assign(ids.begin() + mid, ids.end());
}

int clientSessionMapId(const std::string & statePath, const std::string & clientId)
{
	const std::string text = readFile(statePath);
	const std::string needle = "\"" + clientId + "\"";
	size_t p = text.find(needle);
	if(p == std::string::npos)
	{
		return -999;
	}
	size_t s = text.find("\"session_map_id\"", p);
	if(s == std::string::npos)
	{
		return -999;
	}
	s = text.find(':', s);
	if(s == std::string::npos)
	{
		return -999;
	}
	return std::atoi(text.c_str() + s + 1);
}

int clientLastLocal(const std::string & statePath, const std::string & clientId)
{
	const std::string text = readFile(statePath);
	const std::string needle = "\"" + clientId + "\"";
	size_t p = text.find(needle);
	if(p == std::string::npos)
	{
		return 0;
	}
	size_t s = text.find("\"last_local_id\"", p);
	if(s == std::string::npos)
	{
		return 0;
	}
	s = text.find(':', s);
	if(s == std::string::npos)
	{
		return 0;
	}
	return std::atoi(text.c_str() + s + 1);
}

std::map<int, int> clientIdMap(const std::string & statePath, const std::string & clientId)
{
	std::map<int, int> out;
	const std::string text = readFile(statePath);
	const std::string needle = "\"" + clientId + "\"";
	size_t p = text.find(needle);
	if(p == std::string::npos)
	{
		return out;
	}
	size_t s = text.find("\"id_map\"", p);
	if(s == std::string::npos)
	{
		return out;
	}
	size_t brace = text.find('{', s);
	size_t close = text.find('}', brace);
	if(brace == std::string::npos || close == std::string::npos)
	{
		return out;
	}
	const std::string body = text.substr(brace, close - brace + 1);
	size_t i = 0;
	while(i < body.size())
	{
		size_t q1 = body.find('"', i);
		if(q1 == std::string::npos || q1 > close - brace)
		{
			break;
		}
		size_t q2 = body.find('"', q1 + 1);
		if(q2 == std::string::npos)
		{
			break;
		}
		const int localId = std::atoi(body.substr(q1 + 1, q2 - q1 - 1).c_str());
		size_t colon = body.find(':', q2);
		if(colon == std::string::npos)
		{
			break;
		}
		const int globalId = std::atoi(body.c_str() + colon + 1);
		if(localId > 0 && globalId > 0)
		{
			out[localId] = globalId;
		}
		i = colon + 1;
	}
	return out;
}

struct GraphInfo
{
	int nodes;
	int poses;
	int loopClosures;
	int neighborLinks;
	int interSessionLc;
	int userClosures;
	std::map<int, int> mapCounts;
	std::set<std::pair<int, int> > neighbors;
};

GraphInfo inspectGraph(const std::string & dbPath)
{
	GraphInfo g;
	g.nodes = 0;
	g.poses = 0;
	g.loopClosures = 0;
	g.neighborLinks = 0;
	g.interSessionLc = 0;
	g.userClosures = 0;
	if(!UFile::exists(dbPath))
	{
		return g;
	}

	rtabmap::DBDriver * db = rtabmap::DBDriver::create();
	if(!db->openConnection(dbPath, false, true))
	{
		delete db;
		return g;
	}
	std::set<int> ids;
	db->getAllNodeIds(ids, false, false, false);
	g.nodes = static_cast<int>(ids.size());
	std::map<int, rtabmap::Transform> opt = db->loadOptimizedPoses();
	g.poses = static_cast<int>(opt.size());
	std::multimap<int, rtabmap::Link> links;
	db->getAllLinks(links, true, false);

	std::map<int, int> nodeMap;
	for(std::set<int>::const_iterator it = ids.begin(); it != ids.end(); ++it)
	{
		rtabmap::Transform pose;
		int mapId = 0;
		int weight = 0;
		std::string label;
		double stamp = 0;
		rtabmap::Transform gt;
		std::vector<float> vel;
		rtabmap::GPS gps;
		rtabmap::EnvSensors sensors;
		if(db->getNodeInfo(*it, pose, mapId, weight, label, stamp, gt, vel, gps, sensors))
		{
			nodeMap[*it] = mapId;
			++g.mapCounts[mapId];
		}
	}

	std::set<std::pair<int, int> > uniqueLc;
	for(std::multimap<int, rtabmap::Link>::const_iterator it = links.begin(); it != links.end(); ++it)
	{
		const rtabmap::Link & link = it->second;
		const int a = std::min(link.from(), link.to());
		const int b = std::max(link.from(), link.to());
		if(link.type() == rtabmap::Link::kNeighbor || link.type() == rtabmap::Link::kNeighborMerged)
		{
			++g.neighborLinks;
			g.neighbors.insert(std::make_pair(a, b));
			continue;
		}
		if(link.type() == rtabmap::Link::kPosePrior ||
		   link.type() == rtabmap::Link::kGravity ||
		   link.type() == rtabmap::Link::kVirtualClosure ||
		   link.type() == rtabmap::Link::kLandmark)
		{
			continue;
		}
		// A loop closure between prevLast and newFirst also joins the chain.
		// Rtabmap::process can close that loop itself (consecutive frames look
		// alike) before the server's neighbor glue runs; then addNeighborLink
		// correctly declines to add a duplicate.
		g.neighbors.insert(std::make_pair(a, b));
		uniqueLc.insert(std::make_pair(a, b));
		if(link.type() == rtabmap::Link::kUserClosure)
		{
			++g.userClosures;
		}
		std::map<int, int>::const_iterator ma = nodeMap.find(link.from());
		std::map<int, int>::const_iterator mb = nodeMap.find(link.to());
		if(ma != nodeMap.end() && mb != nodeMap.end() && ma->second != mb->second)
		{
			++g.interSessionLc;
		}
	}
	g.loopClosures = static_cast<int>(uniqueLc.size());
	db->closeConnection(false);
	delete db;
	return g;
}

std::string mapSummary(const std::map<int, int> & counts)
{
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

bool hasNeighbor(const GraphInfo & g, int a, int b)
{
	if(a <= 0 || b <= 0)
	{
		return false;
	}
	const int lo = std::min(a, b);
	const int hi = std::max(a, b);
	return g.neighbors.find(std::make_pair(lo, hi)) != g.neighbors.end();
}

int waitListen(int port, int seconds)
{
	for(int i = 0; i < seconds * 2; ++i)
	{
		std::ostringstream cmd;
		cmd << "lsof -nP -iTCP:" << port << " -sTCP:LISTEN >/dev/null 2>&1";
		if(std::system(cmd.str().c_str()) == 0)
		{
			return 0;
		}
		usleep(500000);
	}
	return 1;
}

pid_t startServer(const std::string & bin, int port, const std::string & dataDir, const std::string & logPath)
{
	pid_t pid = fork();
	if(pid == 0)
	{
		FILE * log = std::fopen(logPath.c_str(), "w");
		if(log)
		{
			dup2(fileno(log), STDOUT_FILENO);
			dup2(fileno(log), STDERR_FILENO);
			std::fclose(log);
		}
		std::ostringstream portStr;
		portStr << port;
		execl(bin.c_str(), bin.c_str(), "--port", portStr.str().c_str(), "--data", dataDir.c_str(), (char *)0);
		_exit(127);
	}
	return pid;
}

void stopServer(pid_t pid)
{
	if(pid <= 0)
	{
		return;
	}
	kill(pid, SIGTERM);
	int status = 0;
	for(int i = 0; i < 20; ++i)
	{
		if(waitpid(pid, &status, WNOHANG) == pid)
		{
			return;
		}
		usleep(100000);
	}
	kill(pid, SIGKILL);
	waitpid(pid, &status, 0);
}

std::string curlHeaders(const std::string & url, const std::string & extra)
{
	std::ostringstream cmd;
	cmd << "curl -sS -D - -o /dev/null --max-time 30 " << extra << " \"" << url << "\"";
	return runOut(cmd.str());
}

std::string curlBody(const std::string & args)
{
	std::ostringstream cmd;
	cmd << "curl -sS --max-time 300 " << args;
	return runOut(cmd.str());
}

std::string headerLine(const std::string & headers, const std::string & name)
{
	std::string lowerName = name;
	std::transform(lowerName.begin(), lowerName.end(), lowerName.begin(), ::tolower);
	std::istringstream in(headers);
	std::string line;
	while(std::getline(in, line))
	{
		if(!line.empty() && line.back() == '\r')
		{
			line.pop_back();
		}
		std::string lower = line;
		std::transform(lower.begin(), lower.end(), lower.begin(), ::tolower);
		if(lower.compare(0, lowerName.size(), lowerName) == 0 &&
		   lower.size() > lowerName.size() &&
		   lower[lowerName.size()] == ':')
		{
			std::string v = line.substr(name.size() + 1);
			while(!v.empty() && (v[0] == ' ' || v[0] == '\t'))
			{
				v.erase(v.begin());
			}
			return v;
		}
	}
	return "";
}

void usage()
{
	std::cout
		<< "Usage: rtabmap-collab-merge-test [--source DIR] [--work DIR] [--server BIN] [--port N] [--skip-http]\n"
		<< "  --source   Live collab-data dir used only as a read-only fixture (default ./collab-data)\n"
		<< "  --work     Temp room (default /tmp/rtabmap-collab-merge-test)\n"
		<< "  --server   rtabmap-collab-server binary for the HTTP path\n"
		<< "  --port     Temp HTTP port (default 18765)\n";
}

}

int main(int argc, char * argv[])
{
	std::string sourceDir = "./collab-data";
	std::string workDir = "/tmp/rtabmap-collab-merge-test";
	std::string serverBin;
	int httpPort = 18765;
	bool skipHttp = false;

	for(int i = 1; i < argc; ++i)
	{
		std::string arg = argv[i];
		if(arg == "-h" || arg == "--help")
		{
			usage();
			return 0;
		}
		else if(arg == "--source" && i + 1 < argc)
		{
			sourceDir = argv[++i];
		}
		else if(arg == "--work" && i + 1 < argc)
		{
			workDir = argv[++i];
		}
		else if(arg == "--server" && i + 1 < argc)
		{
			serverBin = argv[++i];
		}
		else if(arg == "--port" && i + 1 < argc)
		{
			httpPort = std::atoi(argv[++i]);
		}
		else if(arg == "--skip-http")
		{
			skipHttp = true;
		}
		else
		{
			std::cerr << "Unknown argument: " << arg << "\n";
			usage();
			return 2;
		}
	}

	if(serverBin.empty())
	{
		std::string self = argv[0];
		size_t slash = self.find_last_of('/');
		if(slash != std::string::npos)
		{
			serverBin = self.substr(0, slash) + "/rtabmap-collab-server";
		}
		else
		{
			serverBin = "./rtabmap-collab-server";
		}
	}

	ULogger::setType(ULogger::kTypeConsole);
	ULogger::setLevel(ULogger::kError);

	std::cout << "=== collab merge test ===\n";
	std::cout << "source=" << sourceDir << "\n";
	std::cout << "work=" << workDir << "\n";
	std::cout << "server=" << serverBin << "\n";

	const std::string liveDb = sourceDir + "/global.db";
	const std::string liveState = sourceDir + "/clients.json";
	if(!UFile::exists(liveDb))
	{
		std::cerr << "Missing fixture database: " << liveDb << "\n";
		return 2;
	}

	UDirectory::makeDir(workDir);
	const std::string fixtures = workDir + "/fixtures";
	const std::string room = workDir + "/room";
	const std::string httpRoom = workDir + "/http-room";
	UDirectory::makeDir(fixtures);
	// Fresh rooms: delete previous test leftovers only under --work.
	runCmd("rm -rf \"" + room + "\" \"" + httpRoom + "\"");
	UDirectory::makeDir(room);
	UDirectory::makeDir(httpRoom);

	const std::string snapshot = fixtures + "/source.db";
	UFile::erase(snapshot);
	std::cout << "Snapshotting live global.db via sqlite backup (read-only)...\n";
	{
		std::ostringstream cmd;
		cmd << "sqlite3 \"" << liveDb << "\" \".backup '" << snapshot << "'\"";
		if(runCmd(cmd.str()) != 0 || !UFile::exists(snapshot))
		{
			std::cerr << "Failed to snapshot " << liveDb << "\n";
			return 2;
		}
	}

	std::vector<ClientFixture> clients = parseClientsJson(readFile(liveState));
	if(clients.size() < 2 && UFile::exists(liveState))
	{
		const std::string pyFile = workDir + "/parse_clients.py";
		{
			std::ofstream py(pyFile.c_str());
			py << "import json,sys\n"
			   << "d=json.load(open(sys.argv[1]))\n"
			   << "for cid, info in d.get('clients', {}).items():\n"
			   << "    ids=sorted(int(x) for x in info.get('id_map', {}).values())\n"
			   << "    print(cid + ' ' + ','.join(str(i) for i in ids))\n";
		}
		const std::string pyOut = runOut("python3 \"" + pyFile + "\" \"" + liveState + "\"");
		std::istringstream pin(pyOut);
		std::string line;
		clients.clear();
		while(std::getline(pin, line))
		{
			if(line.empty())
			{
				continue;
			}
			size_t sp = line.find(' ');
			if(sp == std::string::npos)
			{
				continue;
			}
			ClientFixture c;
			c.id = line.substr(0, sp);
			c.nodeIds = parseIntList(line.substr(sp + 1));
			if(!c.nodeIds.empty())
			{
				clients.push_back(c);
			}
		}
		std::sort(clients.begin(), clients.end(), [](const ClientFixture & a, const ClientFixture & b) {
			return a.nodeIds.front() < b.nodeIds.front();
		});
		if(!clients.empty())
		{
			std::cout << "Parsed " << clients.size() << " client(s) from clients.json via python.\n";
		}
	}
	if(clients.size() < 2)
	{
		std::cout << "clients.json did not yield two clients; splitting snapshot by map_id.\n";
		clients.clear();
		const std::string maps = sqliteScalar(snapshot, "SELECT GROUP_CONCAT(map_id) FROM (SELECT DISTINCT map_id FROM Node ORDER BY map_id);");
		std::vector<int> mapIds = parseIntList(maps);
		if(mapIds.size() < 2)
		{
			std::cerr << "Need two clients or two map_ids in the fixture.\n";
			return 2;
		}
		const int midMap = mapIds[mapIds.size() / 2];
		ClientFixture a;
		a.id = "fixture-client-a";
		ClientFixture b;
		b.id = "fixture-client-b";
		const std::string aIds = sqliteScalar(snapshot, "SELECT GROUP_CONCAT(id) FROM Node WHERE map_id < " + std::to_string(midMap) + ";");
		const std::string bIds = sqliteScalar(snapshot, "SELECT GROUP_CONCAT(id) FROM Node WHERE map_id >= " + std::to_string(midMap) + ";");
		a.nodeIds = parseIntList(aIds);
		b.nodeIds = parseIntList(bIds);
		clients.push_back(a);
		clients.push_back(b);
	}
	if(clients.size() > 2)
	{
		clients.resize(2);
	}

	std::cout << "Clients:\n";
	for(size_t i = 0; i < clients.size(); ++i)
	{
		std::cout << "  " << clients[i].id << " nodes=" << clients[i].nodeIds.size()
			<< " range=" << clients[i].nodeIds.front() << "-" << clients[i].nodeIds.back() << "\n";
	}

	const std::string srcMaps = sqliteScalar(snapshot, "SELECT GROUP_CONCAT(map_id || ':' || c) FROM (SELECT map_id, COUNT(*) AS c FROM Node GROUP BY map_id);");
	const int srcLc = sqliteInt(snapshot,
		"SELECT COUNT(*) FROM (SELECT MIN(from_id,to_id), MAX(from_id,to_id) FROM Link "
		"WHERE type NOT IN (0,5,6,7,8,9) GROUP BY 1,2);");
	const int srcImages = sqliteInt(snapshot, "SELECT COUNT(*) FROM Data WHERE image IS NOT NULL AND length(image)>0;");
	std::cout << "Fixture snapshot: maps={" << srcMaps << "} unique_lc=" << srcLc
		<< " images=" << srcImages << "\n";

	struct Delta
	{
		std::string path;
		std::vector<int> localIds;
		int sinceId;
	};
	std::vector<std::vector<Delta> > deltas(clients.size());
	for(size_t ci = 0; ci < clients.size(); ++ci)
	{
		std::vector<int> first;
		std::vector<int> second;
		splitHalves(clients[ci].nodeIds, first, second);
		if(second.empty())
		{
			std::cerr << "Client " << clients[ci].id << " has too few nodes to split.\n";
			return 2;
		}
		Delta d1;
		d1.path = fixtures + "/client" + std::to_string(ci) + "_d1.db";
		d1.localIds = first;
		d1.sinceId = 0;
		Delta d2;
		d2.path = fixtures + "/client" + std::to_string(ci) + "_d2.db";
		d2.localIds = second;
		d2.sinceId = first.back();
		std::cout << "Extract " << clients[ci].id << " delta1 nodes=" << first.size()
			<< " ids=" << first.front() << "-" << first.back() << "\n";
		if(!extractSubsetDb(snapshot, d1.path, first))
		{
			std::cerr << "Failed to extract " << d1.path << "\n";
			return 2;
		}
		std::cout << "Extract " << clients[ci].id << " delta2 nodes=" << second.size()
			<< " ids=" << second.front() << "-" << second.back() << "\n";
		if(!extractSubsetDb(snapshot, d2.path, second))
		{
			std::cerr << "Failed to extract " << d2.path << "\n";
			return 2;
		}
		deltas[ci].push_back(d1);
		deltas[ci].push_back(d2);
	}

	collab::CollabMap map(room);
	std::string error;
	if(!map.init(error))
	{
		std::cerr << "CollabMap init failed: " << error << "\n";
		return 2;
	}

	const std::string statePath = room + "/clients.json";
	const std::string globalDb = room + "/global.db";

	std::cout << "\n--- API ingest: same client continuation ---\n";
	collab::SyncResult a1 = map.ingest(clients[0].id, deltas[0][0].sinceId, deltas[0][0].path);
	check(a1.ok && a1.accepted > 0, "A delta1 ingest",
		"ok=" + std::to_string(a1.ok) + " accepted=" + std::to_string(a1.accepted) +
		" nodes=" + std::to_string(a1.globalNodes) + " lc=" + std::to_string(a1.loopClosures) +
		(a1.error.empty() ? "" : " err=" + a1.error));
	const int sessionAfterA1 = clientSessionMapId(statePath, clients[0].id);
	const int lcAfterA1 = a1.loopClosures;
	{
		std::string optErr;
		if(!map.optimizeNow(optErr) && optErr.find("savePLY") == std::string::npos && !optErr.empty())
		{
			std::cout << "WARN  optimize after A1: " << optErr << "\n";
		}
	}

	collab::SyncResult a2 = map.ingest(clients[0].id, deltas[0][1].sinceId, deltas[0][1].path);
	check(a2.ok && a2.accepted > 0, "A delta2 ingest",
		"ok=" + std::to_string(a2.ok) + " accepted=" + std::to_string(a2.accepted) +
		" nodes=" + std::to_string(a2.globalNodes) + " lc=" + std::to_string(a2.loopClosures) +
		(a2.error.empty() ? "" : " err=" + a2.error));
	const int sessionAfterA2 = clientSessionMapId(statePath, clients[0].id);
	check(sessionAfterA1 >= 0 && sessionAfterA1 == sessionAfterA2,
		"A delta2 continues same session_map_id",
		"after_d1=" + std::to_string(sessionAfterA1) + " after_d2=" + std::to_string(sessionAfterA2));
	{
		std::string optErr;
		if(!map.optimizeNow(optErr) && optErr.find("savePLY") == std::string::npos && !optErr.empty())
		{
			std::cout << "WARN  optimize after A2: " << optErr << "\n";
		}
	}

	GraphInfo afterA = inspectGraph(globalDb);
	std::map<int, int> idMapA = clientIdMap(statePath, clients[0].id);
	const int prevLastLocal = deltas[0][0].localIds.back();
	const int newFirstLocal = deltas[0][1].localIds.front();
	const int prevLastGlobal = idMapA.count(prevLastLocal) ? idMapA[prevLastLocal] : 0;
	const int newFirstGlobal = idMapA.count(newFirstLocal) ? idMapA[newFirstLocal] : 0;
	check(hasNeighbor(afterA, prevLastGlobal, newFirstGlobal),
		"A chain link prevLast->newFirst (neighbor or closure)",
		"local " + std::to_string(prevLastLocal) + "->" + std::to_string(newFirstLocal) +
		" global " + std::to_string(prevLastGlobal) + "->" + std::to_string(newFirstGlobal));
	check(afterA.mapCounts.size() == 1,
		"A is not a new orphan map (single map_id after two deltas)",
		"map_ids={" + mapSummary(afterA.mapCounts) + "} nodes=" + std::to_string(afterA.nodes));
	check(static_cast<int>(idMapA.size()) == static_cast<int>(clients[0].nodeIds.size()),
		"A all local nodes remapped",
		"id_map=" + std::to_string(idMapA.size()) + " expected=" + std::to_string(clients[0].nodeIds.size()));
	if(lcAfterA1 > 0)
	{
		check(a2.loopClosures > 0, "A loop_closures not wiped to 0 after delta2",
			"after_d1=" + std::to_string(lcAfterA1) + " after_d2=" + std::to_string(a2.loopClosures) +
			" graph_lc=" + std::to_string(afterA.loopClosures));
	}
	else
	{
		std::cout << "NOTE  A delta1 produced lc=0; persistence check waits for later ingest.\n";
	}

	std::cout << "\n--- API ingest: second client ---\n";
	collab::SyncResult b1 = map.ingest(clients[1].id, deltas[1][0].sinceId, deltas[1][0].path);
	check(b1.ok && b1.accepted > 0, "B delta1 ingest",
		"ok=" + std::to_string(b1.ok) + " accepted=" + std::to_string(b1.accepted) +
		" nodes=" + std::to_string(b1.globalNodes) + " lc=" + std::to_string(b1.loopClosures) +
		" aligned=" + std::to_string(map.lastIngestAligned() ? 1 : 0) +
		(b1.error.empty() ? "" : " err=" + b1.error));
	const int lcAfterB1 = b1.loopClosures;
	const int sessionB1 = clientSessionMapId(statePath, clients[1].id);
	{
		std::string optErr;
		if(!map.optimizeNow(optErr) && optErr.find("savePLY") == std::string::npos && !optErr.empty())
		{
			std::cout << "WARN  optimize after B1: " << optErr << "\n";
		}
	}

	collab::SyncResult b2 = map.ingest(clients[1].id, deltas[1][1].sinceId, deltas[1][1].path);
	check(b2.ok && b2.accepted > 0, "B delta2 ingest",
		"ok=" + std::to_string(b2.ok) + " accepted=" + std::to_string(b2.accepted) +
		" nodes=" + std::to_string(b2.globalNodes) + " lc=" + std::to_string(b2.loopClosures) +
		(b2.error.empty() ? "" : " err=" + b2.error));
	const int sessionB2 = clientSessionMapId(statePath, clients[1].id);
	check(sessionB1 >= 0 && sessionB1 == sessionB2,
		"B delta2 continues same session_map_id",
		"after_d1=" + std::to_string(sessionB1) + " after_d2=" + std::to_string(sessionB2));
	{
		std::string optErr;
		const bool optOk = map.optimizeNow(optErr);
		if(!optOk && optErr.find("savePLY") == std::string::npos && !optErr.empty())
		{
			std::cout << "WARN  optimize after B2: " << optErr << "\n";
		}
		else if(!optOk)
		{
			std::cout << "NOTE  optimizeAndExport ply failed (poses still saved): " << optErr << "\n";
		}
	}

	GraphInfo afterBoth = inspectGraph(globalDb);
	std::map<int, int> idMapB = clientIdMap(statePath, clients[1].id);
	const int bPrevLocal = deltas[1][0].localIds.back();
	const int bNewLocal = deltas[1][1].localIds.front();
	const int bPrevGlobal = idMapB.count(bPrevLocal) ? idMapB[bPrevLocal] : 0;
	const int bNewGlobal = idMapB.count(bNewLocal) ? idMapB[bNewLocal] : 0;
	check(hasNeighbor(afterBoth, bPrevGlobal, bNewGlobal),
		"B chain link prevLast->newFirst (neighbor or closure)",
		"global " + std::to_string(bPrevGlobal) + "->" + std::to_string(bNewGlobal));

	collab::ServerStatus st = map.status();
	check(st.clients.size() == 2, "Two clients in one room",
		"clients=" + std::to_string(st.clients.size()));
	check(static_cast<int>(idMapA.size()) > 0 && static_cast<int>(idMapB.size()) > 0 &&
		st.globalNodes >= static_cast<int>(idMapA.size() + idMapB.size()),
		"Both client node sets present in global.db",
		"A=" + std::to_string(idMapA.size()) + " B=" + std::to_string(idMapB.size()) +
		" global_nodes=" + std::to_string(st.globalNodes) +
		" graph_nodes=" + std::to_string(afterBoth.nodes) +
		" map_ids={" + mapSummary(afterBoth.mapCounts) + "}");
	check(afterBoth.mapCounts.size() == 2,
		"Exactly two session maps (one per client)",
		"map_ids={" + mapSummary(afterBoth.mapCounts) + "}");

	const int persistBaseline = std::max(lcAfterA1, lcAfterB1);
	check(persistBaseline == 0 || b2.loopClosures > 0,
		"loop_closures not wiped to 0 after later ingest",
		"after_A1=" + std::to_string(lcAfterA1) +
		" after_B1=" + std::to_string(lcAfterB1) +
		" after_B2=" + std::to_string(b2.loopClosures) +
		" graph_lc=" + std::to_string(afterBoth.loopClosures) +
		" status_lc=" + std::to_string(st.loopClosures));
	if(persistBaseline > 0 && afterBoth.loopClosures == 0 && b2.loopClosures > 0)
	{
		std::cout << "NOTE  clients.json kept loop_closures=" << b2.loopClosures
			<< " but the graph Link table currently has 0 non-neighbor closures.\n";
	}

	// Honest alignment semantics: aligned is true only when the graph holds a
	// real cross-map closure, or when both phones locked the start tag. Type-4
	// links here are the closures detectMoreLoopClosures found (it records
	// them as kUserClosure); intra-map ones do not align two sessions.
	const bool alignedFlag = map.lastIngestAligned();
	const bool haveInter = afterBoth.interSessionLc > 0;
	if(haveInter)
	{
		gVisualLcProven = true;
		gVisualLcNote = "inter-session closures in graph=" + std::to_string(afterBoth.interSessionLc);
		check(alignedFlag, "Inter-session merge aligned (graph has cross-map closures)", gVisualLcNote);
	}
	else
	{
		gVisualLcNote = "no cross-map Link rows after replay (intra-map closures=" +
			std::to_string(afterBoth.userClosures) + "); without a tag lock the sessions share no frame";
		std::cout << "NOTE  " << gVisualLcNote << "\n";
		check(!alignedFlag, "Merge report: aligned=false without cross-map constraint", gVisualLcNote);
	}

	check(afterBoth.poses >= afterBoth.nodes && afterBoth.nodes > 0,
		"optimizeAndExport keeps poses for all nodes",
		"poses=" + std::to_string(afterBoth.poses) + " nodes=" + std::to_string(afterBoth.nodes) +
		" status_poses=" + std::to_string(st.poses));

	std::cout << "\n--- exportPull ---\n";
	const std::string pullPath = workDir + "/pull-a.db";
	collab::PullResult pull = map.exportPull(clients[0].id, 0, pullPath);
	check(pull.ok, "exportPull ok", pull.error);
	check(pull.aligned == alignedFlag, "GET /pull X-Aligned matches last ingest",
		"pull.aligned=" + std::to_string(pull.aligned ? 1 : 0) +
		" last_ingest_aligned=" + std::to_string(alignedFlag ? 1 : 0) +
		" pull_lc=" + std::to_string(pull.loopClosures));

	std::cout << "\n--- start-tag lock ---\n";
	// A fake calibrate (no real detect) must never lock or align.
	collab::CalibrateResult fake = map.calibrate(clients[0].id, 0, false, 0.05f, 0.0f, 0.45f, 0.0f, 0.0f, 0.0f, 1.0f);
	check(!fake.ok && !map.isRoomLocked(), "calibrate without detected flag rejected", fake.error);
	check(!map.lastIngestAligned(), "still not aligned after rejected calibrate", "");
	// Two real ArUco id-0 detections (one per phone) lock the room and define
	// the shared tag frame, so pull becomes aligned with a transform.
	collab::CalibrateResult calA = map.calibrate(clients[0].id, 0, true, 0.04f, 0.0f, 0.42f, 0.0f, 0.0f, 0.0f, 1.0f);
	check(calA.ok && !calA.locked, "first real detect does not lock alone",
		"ok=" + std::to_string(calA.ok ? 1 : 0) + " locked=" + std::to_string(calA.locked ? 1 : 0));
	collab::CalibrateResult calB = map.calibrate(clients[1].id, 0, true, -0.03f, 0.0f, 0.40f, 0.0f, 0.0f, 0.0f, 1.0f);
	check(calB.ok && calB.locked && map.isRoomLocked(), "second real detect locks the room",
		"ok=" + std::to_string(calB.ok ? 1 : 0) + " locked=" + std::to_string(calB.locked ? 1 : 0));
	check(map.lastIngestAligned(), "aligned=true after tag lock", "");
	const std::string pullLockedPath = workDir + "/pull-a-locked.db";
	collab::PullResult pullLocked = map.exportPull(clients[0].id, 0, pullLockedPath);
	check(pullLocked.ok && pullLocked.aligned && pullLocked.hasTransform,
		"GET /pull aligned with X-Client-To-Global after tag lock",
		"aligned=" + std::to_string(pullLocked.aligned ? 1 : 0) +
		" transform=" + std::to_string(pullLocked.hasTransform ? 1 : 0));
	map.resetDemoRoom();
	check(!map.isRoomLocked() && !map.lastIngestAligned(), "reset unlocks and clears aligned", "");

	if(skipHttp)
	{
		skip("HTTP /sync /status /pull", " --skip-http");
	}
	else if(!UFile::exists(serverBin))
	{
		skip("HTTP /sync /status /pull", "server binary not found: " + serverBin);
	}
	else
	{
		std::cout << "\n--- HTTP path on temp port " << httpPort << " ---\n";
		std::ostringstream liveCheck;
		liveCheck << "lsof -nP -iTCP:" << httpPort << " -sTCP:LISTEN >/dev/null 2>&1";
		if(std::system(liveCheck.str().c_str()) == 0)
		{
			skip("HTTP path", "port " + std::to_string(httpPort) + " already in use (refusing to steal it)");
		}
		else
		{
			const std::string httpLog = workDir + "/http-server.log";
			pid_t httpPid = startServer(serverBin, httpPort, httpRoom, httpLog);
			if(httpPid <= 0 || waitListen(httpPort, 10) != 0)
			{
				check(false, "HTTP server start", "port=" + std::to_string(httpPort) + " log=" + httpLog);
				stopServer(httpPid);
			}
			else
			{
				const std::string base = "http://127.0.0.1:" + std::to_string(httpPort);
				bool httpOk = true;
				int lastSinceA = 0;
				int lastSinceB = 0;
				for(int d = 0; d < 2; ++d)
				{
					std::ostringstream args;
					args << "-H \"X-Client-Id: " << clients[0].id << "\" "
						<< "-H \"X-Since-Id: " << lastSinceA << "\" "
						<< "-H \"Content-Type: application/octet-stream\" "
						<< "--data-binary @" << deltas[0][d].path << " "
						<< "\"" << base << "/sync\"";
					const std::string body = curlBody(args.str());
					const bool ok = body.find("\"ok\":true") != std::string::npos;
					httpOk = httpOk && ok;
					check(ok, std::string("HTTP POST /sync A d") + std::to_string(d + 1), body.substr(0, 180));
					lastSinceA = clientLastLocal(httpRoom + "/clients.json", clients[0].id);
				}
				// Keep A active so a later /join would not reset. We only /sync here.
				runOut("curl -sS --max-time 10 -X POST -H \"X-Client-Id: " + clients[0].id + "\" \"" + base + "/heartbeat\"");
				for(int d = 0; d < 2; ++d)
				{
					std::ostringstream args;
					args << "-H \"X-Client-Id: " << clients[1].id << "\" "
						<< "-H \"X-Since-Id: " << lastSinceB << "\" "
						<< "-H \"Content-Type: application/octet-stream\" "
						<< "--data-binary @" << deltas[1][d].path << " "
						<< "\"" << base << "/sync\"";
					const std::string body = curlBody(args.str());
					const bool ok = body.find("\"ok\":true") != std::string::npos;
					httpOk = httpOk && ok;
					check(ok, std::string("HTTP POST /sync B d") + std::to_string(d + 1), body.substr(0, 180));
					lastSinceB = clientLastLocal(httpRoom + "/clients.json", clients[1].id);
				}
				const std::string statusBody = curlBody("\"" + base + "/status\"");
				check(statusBody.find("\"ok\":true") != std::string::npos &&
					statusBody.find(clients[0].id) != std::string::npos &&
					statusBody.find(clients[1].id) != std::string::npos,
					"HTTP GET /status has both clients", statusBody.substr(0, 240));

				const std::string pullHeaders = curlHeaders(base + "/pull",
					"-H \"X-Client-Id: " + clients[0].id + "\"");
				const std::string xAligned = headerLine(pullHeaders, "X-Aligned");
				const std::string httpState = readFile(httpRoom + "/clients.json");
				const bool httpAligned = httpState.find("\"last_ingest_aligned\": true") != std::string::npos;
				check(!xAligned.empty() && (xAligned == "1") == httpAligned,
					"HTTP GET /pull X-Aligned matches last ingest",
					"X-Aligned=" + xAligned + " last_ingest_aligned=" + std::to_string(httpAligned ? 1 : 0));
				stopServer(httpPid);
				check(httpOk, "HTTP path completed without touching :8080",
					"temp_port=" + std::to_string(httpPort) + " pid_stopped");
			}
		}
	}

	std::cout << "\n=== summary ===\n";
	std::cout << "pass=" << gPass << " fail=" << gFail << " skip=" << gSkip << "\n";
	std::cout << "visual_lc_proven=" << (gVisualLcProven ? "yes" : "no") << "\n";
	if(!gVisualLcNote.empty())
	{
		std::cout << "visual_lc_note=" << gVisualLcNote << "\n";
	}
	if(gFail == 0)
	{
		std::cout << "VERDICT: merge mechanics pass (same-client continuation, both clients in one graph, "
			"LC counter persistence, honest aligned flag, start-tag lock aligns pull).\n";
		if(!gVisualLcProven)
		{
			std::cout << "VERDICT caveat: no visual inter-session loop closure in these fixtures; "
				"the shared frame comes from the start-tag lock only.\n";
		}
	}
	else
	{
		std::cout << "VERDICT: not safe yet. Fix the FAIL rows before relying on a live two-phone walk.\n";
	}
	return gFail == 0 ? 0 : 1;
}
