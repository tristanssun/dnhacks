#include "CollabMap.h"
#include "DemoTag.h"
#include "HttpServer.h"

#include <rtabmap/utilite/UConversion.h>
#include <rtabmap/utilite/UFile.h>
#include <rtabmap/utilite/ULogger.h>

#include <atomic>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <unistd.h>
#include <execinfo.h>

namespace {

collab::HttpServer * gServer = 0;
volatile sig_atomic_t gStopSignal = 0;

// Graceful stop. The signal number is recorded and logged from main so an
// externally triggered exit is visible in server.log (the LaunchAgent
// restarts us silently otherwise).
void handleSignal(int sig)
{
	gStopSignal = sig;
	if(gServer)
	{
		gServer->stop();
	}
}

// Fatal signals: write a backtrace to the log (async-signal-safe calls only),
// then re-raise with the default action so a crash report is still produced.
void handleFatalSignal(int sig)
{
	static const char prefix[] = "\n[collab] FATAL signal ";
	char num[16];
	int n = 0;
	int v = sig;
	if(v == 0)
	{
		num[n++] = '0';
	}
	while(v > 0 && n < 15)
	{
		num[n++] = static_cast<char>('0' + (v % 10));
		v /= 10;
	}
	for(int i = 0; i < n / 2; ++i)
	{
		char t = num[i];
		num[i] = num[n - 1 - i];
		num[n - 1 - i] = t;
	}
	(void)!::write(STDERR_FILENO, prefix, sizeof(prefix) - 1);
	(void)!::write(STDERR_FILENO, num, static_cast<size_t>(n));
	(void)!::write(STDERR_FILENO, ", backtrace:\n", 13);
	void * frames[64];
	int count = ::backtrace(frames, 64);
	::backtrace_symbols_fd(frames, count, STDERR_FILENO);
	std::signal(sig, SIG_DFL);
	::raise(sig);
}

// Uncaught exception anywhere (including detached threads): log it before abort.
void handleTerminate()
{
	std::exception_ptr ex = std::current_exception();
	if(ex)
	{
		try
		{
			std::rethrow_exception(ex);
		}
		catch(const std::exception & e)
		{
			std::fprintf(stderr, "\n[collab] FATAL uncaught exception: %s\n", e.what());
		}
		catch(...)
		{
			std::fprintf(stderr, "\n[collab] FATAL uncaught non-std exception\n");
		}
	}
	else
	{
		std::fprintf(stderr, "\n[collab] FATAL std::terminate without active exception\n");
	}
	void * frames[64];
	int count = ::backtrace(frames, 64);
	::backtrace_symbols_fd(frames, count, STDERR_FILENO);
	std::fflush(stderr);
	std::abort();
}

void usage(const char * argv0)
{
	std::cout
		<< "Usage: " << argv0 << " [--port 8080] [--data ./collab-data]\n"
		<< "\n"
		<< "Headless collaborative mapping server. Ingests rtabmap .db node\n"
		<< "deltas from iOS clients on POST /sync, runs inter-session loop\n"
		<< "closure, and serves the merged map.\n"
		<< "\n"
		<< "  --port N    Listen address 0.0.0.0:N (default 8080)\n"
		<< "  --data DIR  Working directory for global.db and clients.json\n"
		<< "              (default ./collab-data)\n"
		<< "  --write-delta PATH  Write a one-node demo .db and exit\n"
		<< "  --delta-id N --delta-x X --delta-y Y --delta-z Z\n";
}

std::string readWholeFile(const std::string & path)
{
	if(path.empty())
	{
		return "";
	}
	std::ifstream in(path.c_str(), std::ios::in | std::ios::binary);
	if(!in)
	{
		return "";
	}
	std::ostringstream ss;
	ss << in.rdbuf();
	return ss.str();
}

}

int main(int argc, char * argv[])
{
	int port = 8080;
	std::string dataDir = "./collab-data";
	std::string writeDeltaPath;
	int deltaId = 1;
	float deltaX = 0.0f;
	float deltaY = 0.0f;
	float deltaZ = 0.0f;

	for(int i = 1; i < argc; ++i)
	{
		std::string arg = argv[i];
		if(arg == "-h" || arg == "--help")
		{
			usage(argv[0]);
			return 0;
		}
		else if(arg == "--port" && i + 1 < argc)
		{
			port = uStr2Int(argv[++i]);
		}
		else if(arg.compare(0, 7, "--port=") == 0)
		{
			port = uStr2Int(arg.substr(7));
		}
		else if(arg == "--data" && i + 1 < argc)
		{
			dataDir = argv[++i];
		}
		else if(arg.compare(0, 7, "--data=") == 0)
		{
			dataDir = arg.substr(7);
		}
		else if(arg == "--write-delta" && i + 1 < argc)
		{
			writeDeltaPath = argv[++i];
		}
		else if(arg == "--delta-id" && i + 1 < argc)
		{
			deltaId = uStr2Int(argv[++i]);
		}
		else if(arg == "--delta-x" && i + 1 < argc)
		{
			deltaX = uStr2Float(argv[++i]);
		}
		else if(arg == "--delta-y" && i + 1 < argc)
		{
			deltaY = uStr2Float(argv[++i]);
		}
		else if(arg == "--delta-z" && i + 1 < argc)
		{
			deltaZ = uStr2Float(argv[++i]);
		}
		else
		{
			std::cerr << "Unknown argument: " << arg << "\n";
			usage(argv[0]);
			return 1;
		}
	}

	if(!writeDeltaPath.empty())
	{
		std::string error;
		if(!collab::CollabMap::writeDemoDeltaDb(writeDeltaPath, deltaId, deltaX, deltaY, deltaZ, error))
		{
			std::cerr << "write-delta failed: " << error << "\n";
			return 1;
		}
		std::cout << "Wrote demo delta " << writeDeltaPath << "\n";
		return 0;
	}

	if(port <= 0 || port > 65535)
	{
		std::cerr << "Invalid --port " << port << "\n";
		return 1;
	}

	ULogger::setType(ULogger::kTypeConsole);
	ULogger::setLevel(ULogger::kInfo);

	collab::CollabMap map(dataDir);
	std::string error;
	if(!map.init(error))
	{
		UERROR("%s", error.c_str());
		return 1;
	}

	collab::HttpServer::Handler handler = [&](const collab::HttpRequest & req) -> collab::HttpResponse
	{
		if(req.method == "GET" && (req.path == "/" || req.path == "/admin"))
		{
			if(collab::queryValue(req, "reset") == "1")
			{
				map.resetDemoRoom();
			}
			collab::HttpResponse res = collab::HttpResponse::text(200, "text/html; charset=utf-8", collab::adminPageHtml());
			res.extraHeaders["Cache-Control"] = "no-store";
			return res;
		}
		if(req.method == "GET" && req.path == "/tag.svg")
		{
			collab::HttpResponse res = collab::HttpResponse::text(200, "image/svg+xml", collab::demoTagSvg());
			res.extraHeaders["Cache-Control"] = "no-store";
			return res;
		}
		if(req.method == "GET" && req.path == "/tag.png")
		{
			std::string png = collab::demoTagPng();
			if(png.empty())
			{
				return collab::HttpResponse::error(500, "tag png");
			}
			collab::HttpResponse res = collab::HttpResponse::text(200, "image/png", png);
			res.extraHeaders["Cache-Control"] = "no-store";
			return res;
		}
		if(req.method == "GET" && req.path == "/demo")
		{
			collab::HttpResponse res = collab::HttpResponse::json(
				200, map.demoJson(collab::headerValue(req, "X-Client-Id")));
			res.extraHeaders["Cache-Control"] = "no-store";
			return res;
		}
		if(req.method == "POST" && req.path == "/calibrate")
		{
			std::string clientId = collab::headerValue(req, "X-Client-Id");
			std::string body = readWholeFile(req.bodyPath);
			collab::CalibrateResult result = map.calibrateFromJson(clientId, body);
			int status = result.ok ? 200 : 400;
			if(!result.ok)
			{
				std::printf("[collab] POST /calibrate REJECT client=%s error=%s\n",
					clientId.c_str(), result.error.c_str());
			}
			else
			{
				std::printf("[collab] POST /calibrate client=%s ok=1 locked=%d tag=%d count=%d\n",
					clientId.c_str(), result.locked ? 1 : 0, result.tagId, result.calibratedCount);
			}
			std::fflush(stdout);
			return collab::HttpResponse::json(status, map.calibrateJson(result));
		}
		if(req.method == "POST" && req.path == "/reset")
		{
			map.resetDemoRoom();
			return collab::HttpResponse::json(200, "{\"ok\":true,\"reset\":true}");
		}
		if(req.method == "GET" && req.path == "/status")
		{
			return collab::HttpResponse::json(200, map.statusJson());
		}
		if(req.method == "POST" && req.path == "/optimize")
		{
			// Run the optimize/export pass now (tag constraints, detectMore,
			// poses, live mesh). Blocks this request only; other requests keep
			// their own threads.
			std::string optErr;
			const bool ok = map.optimizeNow(optErr);
			std::string meshErr;
			map.exportLiveMeshNow(meshErr);
			std::printf("[collab] POST /optimize ok=%d error=%s\n", ok ? 1 : 0, optErr.c_str());
			std::fflush(stdout);
			if(!ok)
			{
				return collab::HttpResponse::error(500, optErr.empty() ? "optimize failed" : optErr);
			}
			return collab::HttpResponse::json(200, map.statusJson());
		}
		if(req.method == "GET" && req.path == "/map.db")
		{
			if(!UFile::exists(map.mapDbPath()))
			{
				return collab::HttpResponse::error(404, "global.db not created yet");
			}
			return collab::HttpResponse::file(200, map.mapDbPath(), "application/octet-stream", "map.db");
		}
		if(req.method == "GET" && req.path == "/map.ply")
		{
			std::string plyErr;
			map.ensureViewerCloud(plyErr);
			if(!UFile::exists(map.mapPlyPath()))
			{
				return collab::HttpResponse::error(404, "map.ply not created yet");
			}
			collab::HttpResponse res = collab::HttpResponse::file(200, map.mapPlyPath(), "application/octet-stream", "map.ply");
			res.extraHeaders["Cache-Control"] = "no-store";
			return res;
		}
		if(req.method == "GET" && req.path == "/map.cloud")
		{
			if(!map.isRoomLocked())
			{
				const char emptyCloud[] = {'C','3','D','1',0,0,0,0,1,0,0,0};
				collab::HttpResponse res = collab::HttpResponse::text(
					200, "application/octet-stream", std::string(emptyCloud, 12));
				res.extraHeaders["Cache-Control"] = "no-store";
				res.extraHeaders["X-Point-Count"] = "0";
				return res;
			}
			std::string cloudErr;
			map.ensureViewerCloud(cloudErr);
			if(!UFile::exists(map.mapCloudPath()))
			{
				const char emptyCloud[] = {'C','3','D','1',0,0,0,0,1,0,0,0};
				collab::HttpResponse res = collab::HttpResponse::text(
					200, "application/octet-stream", std::string(emptyCloud, 12));
				res.extraHeaders["Cache-Control"] = "no-store";
				res.extraHeaders["X-Point-Count"] = "0";
				return res;
			}
			collab::HttpResponse res = collab::HttpResponse::file(
				200, map.mapCloudPath(), "application/octet-stream", "");
			res.extraHeaders["Cache-Control"] = "no-store";
			return res;
		}
		if((req.method == "GET" || req.method == "HEAD") && req.path == "/map.mesh")
		{
			const std::string emptyMesh =
				"ply\n"
				"format binary_little_endian 1.0\n"
				"comment rtabmap-collab live mesh vertex colors\n"
				"element vertex 0\n"
				"property float x\n"
				"property float y\n"
				"property float z\n"
				"property uchar red\n"
				"property uchar green\n"
				"property uchar blue\n"
				"element face 0\n"
				"property list uchar int vertex_indices\n"
				"end_header\n";
			const bool wantBake = collab::queryValue(req, "bake") == "1";
			auto meshHeaders = [&](collab::HttpResponse & res, int verts, int faces, bool baked)
			{
				res.extraHeaders["Cache-Control"] = "no-store";
				res.extraHeaders["X-Vertex-Count"] = uNumber2Str(verts);
				res.extraHeaders["X-Face-Count"] = uNumber2Str(faces);
				res.extraHeaders["X-Mesh-Shaded"] = "vertex-color";
				res.extraHeaders["X-Mesh-Kind"] = baked ? "baked" : "live";
				res.extraHeaders["X-Mesh-Refresh-Sec"] = "0";
			};
			// The live mesh file is maintained by the ingest worker; never trigger
			// the (slow, on-demand) cloud export from the admin page's 2 s poll.
			const bool useBaked = wantBake && map.hasBakedMesh();
			const std::string meshPath = useBaked ? map.mapBakedMeshPath() : map.mapLiveMeshPath();
			if(!UFile::exists(meshPath) || UFile::length(meshPath) <= 0)
			{
				collab::HttpResponse res = collab::HttpResponse::text(200, "model/ply", emptyMesh);
				meshHeaders(res, 0, 0, false);
				return res;
			}
			int verts = 0;
			int faces = 0;
			{
				std::ifstream in(meshPath.c_str());
				std::string line;
				while(std::getline(in, line))
				{
					if(line.compare(0, 15, "element vertex ") == 0)
					{
						verts = uStr2Int(line.substr(15));
					}
					else if(line.compare(0, 13, "element face ") == 0)
					{
						faces = uStr2Int(line.substr(13));
					}
					else if(line.compare(0, 10, "end_header") == 0)
					{
						break;
					}
				}
			}
			// Inline fetch for the admin viewer. Do not send Content-Disposition
			// attachment; some browsers then treat the PLY as a download.
			collab::HttpResponse res = collab::HttpResponse::file(
				200, meshPath, "model/ply", "");
			meshHeaders(res, verts, faces, useBaked);
			return res;
		}
		if(req.method == "GET" && req.path == "/pull")
		{
			std::string clientId = collab::headerValue(req, "X-Client-Id");
			int sinceId = 0;
			std::string since = collab::queryValue(req, "since_global_id");
			if(since.empty())
			{
				since = collab::headerValue(req, "X-Since-Global-Id");
			}
			if(!since.empty())
			{
				sinceId = uStr2Int(since);
			}
			static std::atomic<int> pullSeq{0};
			const int seq = ++pullSeq;
			const std::string dest = dataDir + "/pull-" + uNumber2Str(seq) + ".db";
			std::printf("[collab] GET /pull client=%s since=%d dest=%s\n",
				clientId.c_str(), sinceId, dest.c_str());
			std::fflush(stdout);
			collab::PullResult result;
			try
			{
				result = map.exportPull(clientId, sinceId, dest);
			}
			catch(const std::exception & e)
			{
				result.ok = false;
				result.error = e.what();
				UERROR("GET /pull threw: %s", e.what());
			}
			catch(...)
			{
				result.ok = false;
				result.error = "pull failed";
				UERROR("GET /pull threw unknown");
			}
			if(!result.ok)
			{
				UFile::erase(dest);
				std::printf("[collab] GET /pull error=%s\n", result.error.c_str());
				std::fflush(stdout);
				return collab::HttpResponse::error(500, result.error.empty() ? "pull failed" : result.error);
			}

			std::ostringstream xf;
			xf << result.localFromGlobal[0] << "," << result.localFromGlobal[1] << ","
				<< result.localFromGlobal[2] << "," << result.localFromGlobal[3] << ","
				<< result.localFromGlobal[4] << "," << result.localFromGlobal[5] << ","
				<< result.localFromGlobal[6];

			const bool haveDb = UFile::exists(dest) && UFile::length(dest) > 0;
			collab::HttpResponse res;
			if(haveDb)
			{
				res = collab::HttpResponse::file(200, dest, "application/octet-stream", "pull.db");
				res.deleteFileAfterSend = true;
			}
			else
			{
				std::ostringstream body;
				body << "{\"ok\":true"
					<< ",\"max_id\":" << result.maxGlobalId
					<< ",\"poses_count\":" << result.posesCount
					<< ",\"nodes_count\":" << result.nodesCount
					<< ",\"aligned\":" << (result.aligned ? "true" : "false")
					<< ",\"loop_closures\":" << result.loopClosures
					<< "}";
				res = collab::HttpResponse::json(200, body.str());
				UFile::erase(dest);
			}
			res.extraHeaders["X-Max-Global-Id"] = uNumber2Str(result.maxGlobalId);
			res.extraHeaders["X-Poses-Count"] = uNumber2Str(result.posesCount);
			res.extraHeaders["X-Nodes-Count"] = uNumber2Str(result.nodesCount);
			res.extraHeaders["X-Aligned"] = result.aligned ? "1" : "0";
			res.extraHeaders["X-Loop-Closures"] = uNumber2Str(result.loopClosures);
			if(result.hasTransform)
			{
				res.extraHeaders["X-Client-To-Global"] = xf.str();
			}
			std::printf("[collab] GET /pull ok nodes=%d poses=%d max_id=%d aligned=%d file=%d\n",
				result.nodesCount, result.posesCount, result.maxGlobalId, result.aligned ? 1 : 0, haveDb ? 1 : 0);
			std::fflush(stdout);
			return res;
		}
		if(req.method == "POST" && req.path == "/join")
		{
			std::string clientId = collab::headerValue(req, "X-Client-Id");
			std::printf("[collab] POST /join client=%s bytes=%ld\n", clientId.c_str(), req.bodyBytes);
			std::fflush(stdout);
			collab::JoinResult result = map.join(clientId);
			int status = result.ok ? 200 : 400;
			std::printf("[collab] POST /join accepted client=%s ok=%d mode=%s active=%d nodes=%d\n",
				clientId.c_str(), result.ok ? 1 : 0, result.mode.c_str(), result.activeClients, result.globalNodes);
			std::fflush(stdout);
			return collab::HttpResponse::json(status, map.joinJson(result));
		}
		if(req.method == "POST" && req.path == "/heartbeat")
		{
			std::string clientId = collab::headerValue(req, "X-Client-Id");
			std::string body = readWholeFile(req.bodyPath);
			collab::JoinResult result = map.heartbeat(clientId, body);
			int status = result.ok ? 200 : 400;
			return collab::HttpResponse::json(status, map.joinJson(result));
		}
		if(req.method == "POST" && req.path == "/pose")
		{
			std::string clientId = collab::headerValue(req, "X-Client-Id");
			std::string body = readWholeFile(req.bodyPath);
			collab::JoinResult result = map.updateLivePose(clientId, body);
			int status = result.ok ? 200 : 400;
			return collab::HttpResponse::json(status, map.joinJson(result));
		}
		if(req.method == "POST" && req.path == "/sync")
		{
			std::string clientId = collab::headerValue(req, "X-Client-Id");
			int sinceId = 0;
			std::string since = collab::headerValue(req, "X-Since-Id");
			if(!since.empty())
			{
				sinceId = uStr2Int(since);
			}
			std::printf("[collab] POST /sync client=%s bytes=%ld since=%d path=%s\n",
				clientId.c_str(), req.bodyBytes, sinceId, req.bodyPath.c_str());
			std::fflush(stdout);
			collab::SyncResult result;
			result.ok = false;
			result.accepted = 0;
			result.lastLocalId = 0;
			result.globalNodes = 0;
			result.loopClosures = 0;
			try
			{
				result = map.ingest(clientId, sinceId, req.bodyPath);
			}
			catch(const std::exception & e)
			{
				result.ok = false;
				result.error = e.what();
				UERROR("POST /sync ingest threw: %s", e.what());
			}
			catch(...)
			{
				result.ok = false;
				result.error = "ingest failed";
				UERROR("POST /sync ingest threw unknown");
			}
			int status = result.ok ? 200 : (result.error.find("missing") != std::string::npos ? 400 : 500);
			std::printf("[collab] POST /sync accepted=%d last_local_id=%d global_nodes=%d ok=%d error=%s\n",
				result.accepted, result.lastLocalId, result.globalNodes, result.ok ? 1 : 0, result.error.c_str());
			std::fflush(stdout);
			return collab::HttpResponse::json(status, map.syncJson(result));
		}
		if(req.method != "GET" && req.method != "POST")
		{
			return collab::HttpResponse::error(405, "method not allowed");
		}
		return collab::HttpResponse::error(404, "not found");
	};

	collab::HttpServer server(port, dataDir, handler);
	gServer = &server;
	std::signal(SIGINT, handleSignal);
	std::signal(SIGTERM, handleSignal);
	std::signal(SIGHUP, handleSignal);
	std::signal(SIGPIPE, SIG_IGN);
	std::signal(SIGSEGV, handleFatalSignal);
	std::signal(SIGBUS, handleFatalSignal);
	std::signal(SIGABRT, handleFatalSignal);
	std::signal(SIGFPE, handleFatalSignal);
	std::signal(SIGILL, handleFatalSignal);
	std::set_terminate(handleTerminate);

	UINFO("rtabmap-collab-server port=%d data=%s pid=%d", port, dataDir.c_str(), static_cast<int>(::getpid()));
	std::fflush(stdout);
	int rc = server.run();
	gServer = 0;
	UWARN("rtabmap-collab-server stopping: signal=%d rc=%d", static_cast<int>(gStopSignal), rc);
	std::fflush(stdout);
	std::fflush(stderr);
	return rc;
}
