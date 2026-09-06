#include "CollabMap.h"
#include "DemoTag.h"
#include "HttpServer.h"
#include "VideoSummary.h"

#include <rtabmap/utilite/UConversion.h>
#include <rtabmap/utilite/UDirectory.h>
#include <rtabmap/utilite/UFile.h>
#include <rtabmap/utilite/ULogger.h>
#include <rtabmap/utilite/UTimer.h>

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
#ifdef __APPLE__
#include <arpa/inet.h>
#include <dns_sd.h>
#include <dispatch/dispatch.h>
#include <net/if.h>
#endif

namespace {

collab::HttpServer * gServer = 0;
volatile sig_atomic_t gStopSignal = 0;

#ifdef __APPLE__
DNSServiceRef gBonjour = 0;

void stopBonjour()
{
	if(gBonjour)
	{
		DNSServiceRefDeallocate(gBonjour);
		gBonjour = 0;
	}
}

void advertiseBonjour(int port)
{
	// Wi-Fi only. Advertising on USB/AWDL (169.254.*) made one phone resolve
	// a link-local address the other phone cannot reach.
	uint32_t iface = if_nametoindex("en0");
	if(iface == 0)
	{
		iface = kDNSServiceInterfaceIndexAny;
	}
	DNSServiceErrorType err = DNSServiceRegister(
		&gBonjour,
		0,
		iface,
		"rtabmap-collab",
		"_rtabmap-collab._tcp",
		"local.",
		0,
		htons(static_cast<uint16_t>(port)),
		0,
		0,
		0,
		0);
	if(err != kDNSServiceErr_NoError)
	{
		std::printf("[collab] Bonjour advertise failed err=%d\n", static_cast<int>(err));
		gBonjour = 0;
		return;
	}
	err = DNSServiceSetDispatchQueue(gBonjour, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
	if(err != kDNSServiceErr_NoError)
	{
		std::printf("[collab] Bonjour dispatch failed err=%d\n", static_cast<int>(err));
		DNSServiceRefDeallocate(gBonjour);
		gBonjour = 0;
		return;
	}
	std::printf("[collab] Bonjour advertised _rtabmap-collab._tcp port=%d iface=%u\n",
		port, iface);
	std::fflush(stdout);
}
#endif

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

void noteScanPlace(collab::CollabMap & map, const collab::HttpRequest & req)
{
	std::string address = collab::headerValue(req, "X-Address");
	if(address.empty())
	{
		address = collab::headerValue(req, "X-Video-Address");
	}
	if(!address.empty())
	{
		map.noteRunAddress(address);
	}
	const std::string lat = collab::headerValue(req, "X-Latitude");
	const std::string lng = collab::headerValue(req, "X-Longitude");
	if(!lat.empty() && !lng.empty())
	{
		map.noteRunGeo(uStr2Double(lat), uStr2Double(lng));
	}
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
	collab::enqueuePendingModelIndexes(dataDir);

	collab::HttpServer::Handler handler = [&](const collab::HttpRequest & req) -> collab::HttpResponse
	{
		if(req.method == "GET" && (req.path == "/" || req.path == "/admin"))
		{
			if(collab::queryValue(req, "reset") == "1")
			{
				map.resetDemoRoom();
				collab::enqueuePendingModelIndexes(dataDir);
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
			noteScanPlace(map, req);
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
		// Scan recordings. The phone uploads its .mp4 when a scan stops; the
		// admin sidebar Recordings folder lists the current run; after reset
		// they move into History > Recordings. A click plays them in-page.
		// Playback needs byte ranges (Safari refuses progressive mp4 without them).
		if(req.method == "POST" && req.path == "/video")
		{
			const std::string clientId = collab::headerValue(req, "X-Client-Id");
			std::string name = collab::sanitizeVideoName(collab::headerValue(req, "X-Video-Name"));
			if(name.empty())
			{
				name = collab::sanitizeVideoName(uNumber2Str((int)std::time(0)) + ".mp4");
			}
			if(req.bodyPath.empty() || req.bodyBytes <= 0 || !UFile::exists(req.bodyPath))
			{
				return collab::HttpResponse::error(400, "empty body");
			}
			const std::string dir = dataDir + "/videos";
			if(!UDirectory::exists(dir))
			{
				UDirectory::makeDir(dir);
			}
			const std::string dest = dir + "/" + name;
			UFile::erase(dest);
			if(UFile::rename(req.bodyPath, dest) != 0)
			{
				return collab::HttpResponse::error(500, "cannot store video");
			}
			const std::string durationStr = collab::headerValue(req, "X-Video-Duration");
			const double duration = durationStr.empty() ? 0.0 : uStr2Double(durationStr);
			noteScanPlace(map, req);
			const std::string address = map.currentRunAddress();
			const int runId = map.currentRunId();
			const long started = map.currentRunStarted();
			{
				std::ofstream meta((dest + ".json").c_str(), std::ios::trunc);
				meta << "{\"name\":\"" << collab::jsonEscape(name) << "\""
					<< ",\"client\":\"" << collab::jsonEscape(clientId) << "\""
					<< ",\"bytes\":" << req.bodyBytes
					<< ",\"duration_s\":" << duration
					<< ",\"uploaded\":" << (long)std::time(0)
					<< ",\"run\":" << runId
					<< ",\"address\":\"" << collab::jsonEscape(address) << "\""
					<< ",\"lat\":" << map.currentRunLat()
					<< ",\"lng\":" << map.currentRunLng()
					<< ",\"title\":\"" << collab::jsonEscape(collab::formatRunName(address, started)) << "\""
					<< ",\"summary_status\":\"pending\"}\n";
			}
			std::printf("[collab] POST /video client=%s name=%s bytes=%ld duration=%.1fs\n",
				clientId.c_str(), name.c_str(), req.bodyBytes, duration);
			std::fflush(stdout);
			collab::enqueueVideoSummary(dataDir, dest);
			return collab::HttpResponse::json(200, std::string("{\"ok\":true,\"name\":\"") + collab::jsonEscape(name) +
				"\",\"bytes\":" + uNumber2Str((int)req.bodyBytes) + ",\"url\":\"/videos/" + collab::jsonEscape(name) + "\"}");
		}
		if(req.method == "GET" && req.path == "/videos")
		{
			collab::HttpResponse res = collab::HttpResponse::json(200, collab::listVideosJson(
				dataDir + "/videos", map.currentRunId(), map.currentRunAddress(), map.currentRunStarted(),
				map.currentRunLat(), map.currentRunLng()));
			res.extraHeaders["Cache-Control"] = "no-store";
			return res;
		}
		if(req.method == "GET" && req.path == "/videos/tasks")
		{
			collab::HttpResponse res = collab::HttpResponse::json(200, collab::listVideoTasksJson(dataDir + "/videos"));
			res.extraHeaders["Cache-Control"] = "no-store";
			return res;
		}
		if(req.path.compare(0, 8, "/videos/") == 0)
		{
			std::string name;
			std::string action;
			if(!collab::splitVideoAction(req.path.substr(8), name, action))
			{
				return collab::HttpResponse::error(404, "no such recording");
			}
			const std::string path = dataDir + "/videos/" + name;
			if(action == "analysis" && req.method == "GET")
			{
				if(!UFile::exists(path))
				{
					return collab::HttpResponse::error(404, "no such recording");
				}
				collab::HttpResponse res = collab::HttpResponse::json(200, collab::videoAnalysisHttpBody(path));
				res.extraHeaders["Cache-Control"] = "no-store";
				return res;
			}
			if(action == "tasks" && req.method == "GET")
			{
				if(!UFile::exists(path))
				{
					return collab::HttpResponse::error(404, "no such recording");
				}
				collab::HttpResponse res = collab::HttpResponse::json(200, collab::videoAnalysisHttpBody(path));
				res.extraHeaders["Cache-Control"] = "no-store";
				return res;
			}
			if(action == "summarize" && req.method == "POST")
			{
				if(!UFile::exists(path))
				{
					return collab::HttpResponse::error(404, "no such recording");
				}
				collab::enqueueVideoSummary(dataDir, path);
				collab::HttpResponse res = collab::HttpResponse::json(200, collab::videoAnalysisHttpBody(path));
				res.extraHeaders["Cache-Control"] = "no-store";
				return res;
			}
			if(!action.empty())
			{
				return collab::HttpResponse::error(404, "no such recording");
			}
			if(req.method != "GET" && req.method != "HEAD")
			{
				return collab::HttpResponse::error(405, "method not allowed");
			}
			if(name.empty() || !UFile::exists(path))
			{
				return collab::HttpResponse::error(404, "no such recording");
			}
			const long total = UFile::length(path);
			const std::string range = collab::headerValue(req, "Range");
			long from = 0;
			long to = total - 1;
			if(range.compare(0, 6, "bytes=") == 0 && total > 0)
			{
				const std::string spec = range.substr(6);
				const size_t dash = spec.find('-');
				if(dash != std::string::npos)
				{
					const std::string a = spec.substr(0, dash);
					const std::string b = spec.substr(dash + 1);
					if(a.empty() && !b.empty())
					{
						// suffix range: last N bytes
						from = std::max(0L, total - uStr2Int(b));
					}
					else
					{
						from = a.empty() ? 0 : uStr2Int(a);
						if(!b.empty())
						{
							to = std::min(total - 1, (long)uStr2Int(b));
						}
					}
				}
				if(from < 0 || from >= total || from > to)
				{
					collab::HttpResponse res = collab::HttpResponse::text(416, "text/plain", "range not satisfiable");
					res.statusText = "Range Not Satisfiable";
					res.extraHeaders["Content-Range"] = "bytes */" + uNumber2Str((int)total);
					return res;
				}
				// Serve at most 16 MB per request; the player asks for the rest.
				const long kChunk = 16L * 1024L * 1024L;
				if(to - from + 1 > kChunk)
				{
					to = from + kChunk - 1;
				}
				std::string body;
				if(req.method == "GET")
				{
					FILE * in = std::fopen(path.c_str(), "rb");
					if(!in)
					{
						return collab::HttpResponse::error(500, "cannot read recording");
					}
					body.resize(static_cast<size_t>(to - from + 1));
					std::fseek(in, from, SEEK_SET);
					const size_t got = std::fread(&body[0], 1, body.size(), in);
					std::fclose(in);
					body.resize(got);
					to = from + (long)got - 1;
				}
				collab::HttpResponse res = collab::HttpResponse::text(206, "video/mp4", body);
				res.statusText = "Partial Content";
				res.extraHeaders["Content-Range"] = "bytes " + uNumber2Str((int)from) + "-" + uNumber2Str((int)to) + "/" + uNumber2Str((int)total);
				res.extraHeaders["Accept-Ranges"] = "bytes";
				res.extraHeaders["Cache-Control"] = "no-store";
				return res;
			}
			collab::HttpResponse res = collab::HttpResponse::file(200, path, "video/mp4", "");
			res.extraHeaders["Accept-Ranges"] = "bytes";
			res.extraHeaders["Cache-Control"] = "no-store";
			return res;
		}
		// Archived room meshes. Saved on reset / new-room so History can show
		// past 3D models after the live map is wiped.
		if(req.method == "GET" && req.path == "/runs")
		{
			collab::HttpResponse res = collab::HttpResponse::json(200, map.runsJson());
			res.extraHeaders["Cache-Control"] = "no-store";
			return res;
		}
		if((req.method == "GET" || req.method == "POST") && req.path == "/search")
		{
			std::string q = collab::queryValue(req, "q");
			if(q.empty())
			{
				q = collab::jsonFieldString(readWholeFile(req.bodyPath), "q");
			}
			collab::HttpResponse res = collab::HttpResponse::json(200, collab::historySearchJson(dataDir, q));
			res.extraHeaders["Cache-Control"] = "no-store";
			return res;
		}
		if(req.method == "GET" && req.path == "/models")
		{
			collab::HttpResponse res = collab::HttpResponse::json(200, collab::listModelsJson(dataDir + "/models"));
			res.extraHeaders["Cache-Control"] = "no-store";
			return res;
		}
		if(req.method == "GET" && req.path == "/models/index")
		{
			collab::HttpResponse res = collab::HttpResponse::json(200, collab::listModelIndexJson(dataDir + "/models"));
			res.extraHeaders["Cache-Control"] = "no-store";
			return res;
		}
		if(req.path.compare(0, 8, "/models/") == 0)
		{
			std::string name;
			std::string action;
			if(!collab::splitModelAction(req.path.substr(8), name, action))
			{
				return collab::HttpResponse::error(404, "no such model");
			}
			const std::string path = dataDir + "/models/" + name;
			if(action == "analysis" && req.method == "GET")
			{
				if(!UFile::exists(path))
				{
					return collab::HttpResponse::error(404, "no such model");
				}
				collab::HttpResponse res = collab::HttpResponse::json(200, collab::modelAnalysisHttpBody(path));
				res.extraHeaders["Cache-Control"] = "no-store";
				return res;
			}
			if(action == "index" && req.method == "POST")
			{
				if(!UFile::exists(path))
				{
					return collab::HttpResponse::error(404, "no such model");
				}
				collab::enqueueModelIndex(dataDir, path);
				collab::HttpResponse res = collab::HttpResponse::json(200, collab::modelAnalysisHttpBody(path));
				res.extraHeaders["Cache-Control"] = "no-store";
				return res;
			}
			if(!action.empty())
			{
				return collab::HttpResponse::error(404, "no such model");
			}
			if(req.method != "GET" && req.method != "HEAD")
			{
				return collab::HttpResponse::error(405, "method not allowed");
			}
			if(name.empty() || !UFile::exists(path) || UFile::length(path) <= 0)
			{
				return collab::HttpResponse::error(404, "no such model");
			}
			const bool jpg = name.size() >= 4 && name.compare(name.size() - 4, 4, ".jpg") == 0;
			if(jpg)
			{
				collab::HttpResponse res = collab::HttpResponse::file(200, path, "image/jpeg", "");
				res.extraHeaders["Cache-Control"] = "no-store";
				return res;
			}
			int verts = 0;
			int faces = 0;
			bool textured = false;
			{
				std::ifstream in(path.c_str());
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
					else if(line.find("property float s") != std::string::npos ||
						line.find("property float t") != std::string::npos)
					{
						textured = true;
					}
					else if(line.compare(0, 10, "end_header") == 0)
					{
						break;
					}
				}
			}
			collab::HttpResponse res = collab::HttpResponse::file(200, path, "model/ply", "");
			res.extraHeaders["Cache-Control"] = "no-store";
			res.extraHeaders["X-Vertex-Count"] = uNumber2Str(verts);
			res.extraHeaders["X-Face-Count"] = uNumber2Str(faces);
			res.extraHeaders["X-Mesh-Kind"] = "archive";
			res.extraHeaders["X-Mesh-Textured"] = textured ? "1" : "0";
			return res;
		}
		if(req.method == "POST" && req.path == "/bake")
		{
			std::string bakeErr;
			UTimer bakeTimer;
			const bool ok = map.bakeNow(bakeErr);
			std::printf("[collab] POST /bake ok=%d %.1fs error=%s\n", ok ? 1 : 0, bakeTimer.ticks(), bakeErr.c_str());
			std::fflush(stdout);
			if(!ok)
			{
				return collab::HttpResponse::error(500, bakeErr.empty() ? "bake failed" : bakeErr);
			}
			return collab::HttpResponse::json(200, map.demoJson());
		}
		if(req.method == "POST" && req.path == "/tag_size")
		{
			// The admin page reports the physical width of the black marker
			// square it is displaying; phones read it back from /join and /demo.
			const std::string body = readWholeFile(req.bodyPath);
			if(!req.bodyPath.empty())
			{
				UFile::erase(req.bodyPath);
			}
			double meters = 0.0;
			const size_t k = body.find("tag_size_m");
			if(k != std::string::npos)
			{
				const size_t colon = body.find(':', k);
				if(colon != std::string::npos)
				{
					meters = std::atof(body.c_str() + colon + 1);
				}
			}
			if(!map.setTagSizeM(static_cast<float>(meters)))
			{
				return collab::HttpResponse::error(400, "tag_size_m must be between 0.02 and 2.0 meters");
			}
			std::ostringstream oss;
			oss << "{\"ok\":true,\"tag_size_m\":" << map.tagSizeM() << "}";
			return collab::HttpResponse::json(200, oss.str());
		}
		if(req.method == "POST" && req.path == "/lock_phones")
		{
			const std::string body = readWholeFile(req.bodyPath);
			if(!req.bodyPath.empty())
			{
				UFile::erase(req.bodyPath);
			}
			int count = 0;
			const size_t k = body.find("lock_phones_required");
			if(k != std::string::npos)
			{
				const size_t colon = body.find(':', k);
				if(colon != std::string::npos)
				{
					count = std::atoi(body.c_str() + colon + 1);
				}
			}
			if(!map.setLockPhonesRequired(count))
			{
				return collab::HttpResponse::error(400, "lock_phones_required must be between 1 and 16");
			}
			std::ostringstream oss;
			oss << "{\"ok\":true,\"lock_phones_required\":" << map.lockPhonesRequired()
				<< ",\"locked\":" << (map.isRoomLocked() ? "true" : "false") << "}";
			return collab::HttpResponse::json(200, oss.str());
		}
		if(req.method == "POST" && req.path == "/reset")
		{
			map.resetDemoRoom();
			collab::enqueuePendingModelIndexes(dataDir);
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
		if(req.method == "GET" && req.path == "/map.bake.jpg")
		{
			const std::string atlas = map.bakedAtlasPath();
			if(atlas.empty() || !UFile::exists(atlas) || UFile::length(atlas) <= 0)
			{
				return collab::HttpResponse::error(404, "no textured bake");
			}
			collab::HttpResponse res = collab::HttpResponse::file(200, atlas, "image/jpeg", "");
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
			// Overlay: live node meshes newer than the bake, built from the cache.
			const std::string sinceStr = collab::queryValue(req, "since_node");
			if(!sinceStr.empty())
			{
				int nodes = 0;
				const std::string body = map.liveMeshSince(uStr2Int(sinceStr), nodes);
				if(body.empty())
				{
					collab::HttpResponse res = collab::HttpResponse::text(200, "model/ply", emptyMesh);
					meshHeaders(res, 0, 0, false);
					res.extraHeaders["X-Node-Count"] = "0";
					return res;
				}
				collab::HttpResponse res = collab::HttpResponse::text(200, "model/ply", body);
				int verts = 0;
				int faces = 0;
				std::istringstream hin(body.substr(0, 400));
				std::string line;
				while(std::getline(hin, line))
				{
					if(line.compare(0, 15, "element vertex ") == 0) verts = uStr2Int(line.substr(15));
					else if(line.compare(0, 13, "element face ") == 0) faces = uStr2Int(line.substr(13));
					else if(line.compare(0, 10, "end_header") == 0) break;
				}
				meshHeaders(res, verts, faces, false);
				res.extraHeaders["X-Node-Count"] = uNumber2Str(nodes);
				return res;
			}
			// The live mesh file is maintained by the ingest worker; never trigger
			// the (slow, on-demand) cloud export from the admin page's 2 s poll.
			const bool useBaked = wantBake && map.hasBakedMesh();
			const std::string meshPath = useBaked ? map.mapBakedMeshPath() : map.mapLiveMeshPath();
			// A bake request never falls back to the live file: the viewer would
			// take the per-node mesh for the assembled surface.
			if((wantBake && !useBaked) || !UFile::exists(meshPath) || UFile::length(meshPath) <= 0)
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
			if(useBaked)
			{
				res.extraHeaders["X-Mesh-Textured"] = map.bakedAtlasPath().empty() ? "0" : "1";
			}
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
			collab::enqueuePendingModelIndexes(dataDir);
			noteScanPlace(map, req);
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
			noteScanPlace(map, req);
			int status = result.ok ? 200 : 400;
			return collab::HttpResponse::json(status, map.joinJson(result));
		}
		if(req.method == "POST" && req.path == "/pose")
		{
			std::string clientId = collab::headerValue(req, "X-Client-Id");
			std::string body = readWholeFile(req.bodyPath);
			collab::JoinResult result = map.updateLivePose(clientId, body);
			noteScanPlace(map, req);
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
			noteScanPlace(map, req);
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
#ifdef __APPLE__
	advertiseBonjour(port);
#endif
	int rc = server.run();
#ifdef __APPLE__
	stopBonjour();
#endif
	gServer = 0;
	UWARN("rtabmap-collab-server stopping: signal=%d rc=%d", static_cast<int>(gStopSignal), rc);
	std::fflush(stdout);
	std::fflush(stderr);
	return rc;
}
