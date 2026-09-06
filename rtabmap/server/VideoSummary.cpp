#include "VideoSummary.h"
#include "HttpServer.h"

#include <rtabmap/utilite/UDirectory.h>
#include <rtabmap/utilite/UFile.h>

#include <cctype>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <list>
#include <poll.h>
#include <sstream>
#include <string>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

namespace collab {

namespace {

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

bool writeFile(const std::string & path, const std::string & contents)
{
	const std::string tmp = path + ".tmp";
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

std::string trimKey(const std::string & in)
{
	size_t a = 0;
	while(a < in.size() && std::isspace(static_cast<unsigned char>(in[a])))
	{
		++a;
	}
	size_t b = in.size();
	while(b > a && std::isspace(static_cast<unsigned char>(in[b - 1])))
	{
		--b;
	}
	return in.substr(a, b - a);
}

std::string executableDir()
{
#ifdef __APPLE__
	char buf[4096];
	uint32_t n = sizeof(buf);
	if(_NSGetExecutablePath(buf, &n) == 0)
	{
		std::string p(buf);
		const size_t slash = p.rfind('/');
		if(slash != std::string::npos)
		{
			return p.substr(0, slash);
		}
	}
#endif
	return ".";
}

std::string findSummarizeScript()
{
	const char * env = std::getenv("COLLAB_VIDEO_SUMMARIZE");
	if(env && env[0] && UFile::exists(env))
	{
		return env;
	}
	const std::string binDir = executableDir();
	const char * tails[] = {
		"/video_summarize.py",
		"/../server/video_summarize.py",
		"/../../server/video_summarize.py",
		0
	};
	for(int i = 0; tails[i]; ++i)
	{
		const std::string path = binDir + tails[i];
		if(UFile::exists(path))
		{
			return path;
		}
	}
	if(UFile::exists("server/video_summarize.py"))
	{
		return "server/video_summarize.py";
	}
	return "";
}

std::string findPython()
{
	const char * env = std::getenv("COLLAB_PYTHON");
	if(env && env[0] && (env[0] != '/' || UFile::exists(env)))
	{
		return env;
	}
	const char * cands[] = {
		"/opt/homebrew/bin/python3",
		"/usr/local/bin/python3",
		"/usr/bin/python3",
		"python3",
		0
	};
	for(int i = 0; cands[i]; ++i)
	{
		if(cands[i][0] != '/' || UFile::exists(cands[i]))
		{
			return cands[i];
		}
	}
	return "python3";
}

std::string extractJsonArray(const std::string & text, const char * key)
{
	const std::string pat = std::string("\"") + key + "\":";
	size_t p = text.find(pat);
	if(p == std::string::npos)
	{
		return "";
	}
	p += pat.size();
	while(p < text.size() && std::isspace(static_cast<unsigned char>(text[p])))
	{
		++p;
	}
	if(p >= text.size() || text[p] != '[')
	{
		return "";
	}
	int depth = 0;
	bool inStr = false;
	bool esc = false;
	for(size_t i = p; i < text.size(); ++i)
	{
		const char c = text[i];
		if(inStr)
		{
			if(esc)
			{
				esc = false;
			}
			else if(c == '\\')
			{
				esc = true;
			}
			else if(c == '"')
			{
				inStr = false;
			}
			continue;
		}
		if(c == '"')
		{
			inStr = true;
		}
		else if(c == '[')
		{
			++depth;
		}
		else if(c == ']')
		{
			--depth;
			if(depth == 0)
			{
				return text.substr(p, i - p + 1);
			}
		}
	}
	return "";
}

}

bool geminiKeyConfigured(const std::string & dataDir)
{
	const char * keys[] = {"GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENERATIVE_AI_API_KEY", 0};
	for(int i = 0; keys[i]; ++i)
	{
		const char * v = std::getenv(keys[i]);
		if(v && v[0])
		{
			return true;
		}
	}
	const std::string path = dataDir + "/gemini.key";
	if(!UFile::exists(path))
	{
		return false;
	}
	return !trimKey(readFile(path)).empty();
}

bool splitVideoAction(const std::string & rest, std::string & name, std::string & action)
{
	std::string file = rest;
	action.clear();
	const size_t slash = rest.find('/');
	if(slash != std::string::npos)
	{
		file = rest.substr(0, slash);
		action = rest.substr(slash + 1);
	}
	name = sanitizeVideoName(file);
	return !name.empty();
}

std::string videoAnalysisPath(const std::string & videoPath)
{
	return videoPath + ".analysis.json";
}

void setSidecarString(const std::string & jsonPath, const std::string & key, const std::string & value)
{
	std::string text = readFile(jsonPath);
	if(text.empty())
	{
		text = "{}\n";
	}
	const std::string pat = std::string("\"") + key + "\":";
	size_t p = text.find(pat);
	if(p != std::string::npos)
	{
		p += pat.size();
		while(p < text.size() && (text[p] == ' ' || text[p] == '\t' || text[p] == '\n' || text[p] == '\r'))
		{
			++p;
		}
		if(p < text.size() && text[p] == '"')
		{
			const size_t start = p + 1;
			size_t e = start;
			bool esc = false;
			for(; e < text.size(); ++e)
			{
				const char c = text[e];
				if(esc)
				{
					esc = false;
					continue;
				}
				if(c == '\\')
				{
					esc = true;
					continue;
				}
				if(c == '"')
				{
					break;
				}
			}
			if(e < text.size())
			{
				text.replace(start, e - start, jsonEscape(value));
				writeFile(jsonPath, text);
				return;
			}
		}
	}
	const size_t end = text.rfind('}');
	if(end == std::string::npos)
	{
		text = std::string("{\"") + key + "\":\"" + jsonEscape(value) + "\"}\n";
		writeFile(jsonPath, text);
		return;
	}
	bool emptyObj = true;
	for(size_t i = 0; i < end; ++i)
	{
		if(!std::isspace(static_cast<unsigned char>(text[i])) && text[i] != '{')
		{
			emptyObj = false;
			break;
		}
	}
	const std::string insert = (emptyObj ? "\"" : ",\"") + key + "\":\"" + jsonEscape(value) + "\"";
	text.insert(end, insert);
	writeFile(jsonPath, text);
}

std::string videoAnalysisHttpBody(const std::string & videoPath)
{
	const std::string analysis = videoAnalysisPath(videoPath);
	if(UFile::exists(analysis))
	{
		const std::string body = readFile(analysis);
		if(!body.empty())
		{
			return body;
		}
	}
	std::string status = jsonFieldString(readFile(videoPath + ".json"), "summary_status");
	std::string err = jsonFieldString(readFile(videoPath + ".json"), "summary_error");
	if(status.empty())
	{
		status = "idle";
	}
	return std::string("{\"ok\":true,\"status\":\"") + jsonEscape(status) +
		"\",\"error\":\"" + jsonEscape(err) + "\",\"summary\":\"\",\"tasks\":[]}";
}

std::string listVideoTasksJson(const std::string & videoDir)
{
	const std::string jsonl = videoDir + "/tasks.jsonl";
	if(UFile::exists(jsonl))
	{
		std::ifstream in(jsonl.c_str());
		std::ostringstream oss;
		oss << "{\"ok\":true,\"tasks\":[";
		bool first = true;
		std::string line;
		while(std::getline(in, line))
		{
			size_t a = 0;
			while(a < line.size() && std::isspace(static_cast<unsigned char>(line[a])))
			{
				++a;
			}
			if(a >= line.size() || line[a] != '{')
			{
				continue;
			}
			if(!first)
			{
				oss << ",";
			}
			first = false;
			oss << line.substr(a);
		}
		oss << "]}";
		return oss.str();
	}
	std::ostringstream oss;
	oss << "{\"ok\":true,\"tasks\":[";
	bool first = true;
	if(UDirectory::exists(videoDir))
	{
		UDirectory d(videoDir, "json");
		const std::list<std::string> & names = d.getFileNames();
		for(std::list<std::string>::const_iterator it = names.begin(); it != names.end(); ++it)
		{
			if(it->size() < 15 || it->compare(it->size() - 14, 14, ".analysis.json") != 0)
			{
				continue;
			}
			const std::string arr = extractJsonArray(readFile(videoDir + "/" + *it), "tasks");
			if(arr.size() < 2)
			{
				continue;
			}
			const std::string inner = arr.substr(1, arr.size() - 2);
			size_t i = 0;
			while(i < inner.size() && std::isspace(static_cast<unsigned char>(inner[i])))
			{
				++i;
			}
			if(i >= inner.size())
			{
				continue;
			}
			if(!first)
			{
				oss << ",";
			}
			first = false;
			oss << inner;
		}
	}
	oss << "]}";
	return oss.str();
}

std::string listJsonlArray(const std::string & jsonl, const char * key)
{
	std::ostringstream oss;
	oss << "{\"ok\":true,\"" << key << "\":[";
	bool first = true;
	if(UFile::exists(jsonl))
	{
		std::ifstream in(jsonl.c_str());
		std::string line;
		while(std::getline(in, line))
		{
			size_t a = 0;
			while(a < line.size() && std::isspace(static_cast<unsigned char>(line[a])))
			{
				++a;
			}
			if(a >= line.size() || line[a] != '{')
			{
				continue;
			}
			if(!first)
			{
				oss << ",";
			}
			first = false;
			oss << line.substr(a);
		}
	}
	oss << "]}";
	return oss.str();
}

int hexVal(char c)
{
	if(c >= '0' && c <= '9') return c - '0';
	if(c >= 'a' && c <= 'f') return 10 + (c - 'a');
	if(c >= 'A' && c <= 'F') return 10 + (c - 'A');
	return -1;
}

std::string urlDecode(const std::string & in)
{
	std::string out;
	out.reserve(in.size());
	for(size_t i = 0; i < in.size(); ++i)
	{
		if(in[i] == '%' && i + 2 < in.size())
		{
			const int hi = hexVal(in[i + 1]);
			const int lo = hexVal(in[i + 2]);
			if(hi >= 0 && lo >= 0)
			{
				out.push_back(static_cast<char>((hi << 4) | lo));
				i += 2;
				continue;
			}
		}
		out.push_back(in[i] == '+' ? ' ' : in[i]);
	}
	return out;
}

void enqueueVideoSummary(const std::string & dataDir, const std::string & videoPath)
{
	if(videoPath.empty() || !UFile::exists(videoPath))
	{
		return;
	}
	const std::string sidecar = videoPath + ".json";
	if(!geminiKeyConfigured(dataDir))
	{
		setSidecarString(sidecar, "summary_status", "unavailable");
		setSidecarString(sidecar, "summary_error",
			"Set GEMINI_API_KEY or put the key in collab-data/gemini.key");
		std::printf("[collab] video summary skipped (no Gemini key) %s\n", videoPath.c_str());
		std::fflush(stdout);
		return;
	}
	const std::string script = findSummarizeScript();
	if(script.empty())
	{
		setSidecarString(sidecar, "summary_status", "error");
		setSidecarString(sidecar, "summary_error", "video_summarize.py not found");
		std::printf("[collab] video summary missing script\n");
		std::fflush(stdout);
		return;
	}
	setSidecarString(sidecar, "summary_status", "pending");
	setSidecarString(sidecar, "summary_error", "");
	::signal(SIGCHLD, SIG_IGN);
	const pid_t pid = ::fork();
	if(pid < 0)
	{
		setSidecarString(sidecar, "summary_status", "error");
		setSidecarString(sidecar, "summary_error", "fork failed");
		return;
	}
	if(pid > 0)
	{
		std::printf("[collab] video summary queued name=%s pid=%d\n",
			UFile::getName(videoPath).c_str(), static_cast<int>(pid));
		std::fflush(stdout);
		return;
	}
	::setsid();
	const std::string py = findPython();
	if(!py.empty() && py[0] == '/')
	{
		::execl(py.c_str(), py.c_str(), script.c_str(),
			"--video", videoPath.c_str(),
			"--data-dir", dataDir.c_str(),
			static_cast<char *>(0));
	}
	else
	{
		::execlp("python3", "python3", script.c_str(),
			"--video", videoPath.c_str(),
			"--data-dir", dataDir.c_str(),
			static_cast<char *>(0));
	}
	std::fprintf(stderr, "[collab] video summary exec failed script=%s\n", script.c_str());
	::_exit(127);
}

bool splitModelAction(const std::string & rest, std::string & name, std::string & action)
{
	std::string file = rest;
	action.clear();
	const size_t slash = rest.find('/');
	if(slash != std::string::npos)
	{
		file = rest.substr(0, slash);
		action = rest.substr(slash + 1);
	}
	name = sanitizeModelName(file);
	return !name.empty();
}

std::string modelAnalysisPath(const std::string & modelPath)
{
	return modelPath + ".analysis.json";
}

std::string modelAnalysisHttpBody(const std::string & modelPath)
{
	const std::string analysis = modelAnalysisPath(modelPath);
	if(UFile::exists(analysis))
	{
		const std::string body = readFile(analysis);
		if(!body.empty())
		{
			return body;
		}
	}
	std::string status = jsonFieldString(readFile(modelPath + ".json"), "index_status");
	std::string err = jsonFieldString(readFile(modelPath + ".json"), "index_error");
	if(status.empty())
	{
		status = "idle";
	}
	return std::string("{\"ok\":true,\"status\":\"") + jsonEscape(status) +
		"\",\"error\":\"" + jsonEscape(err) + "\",\"summary\":\"\",\"places\":[]}";
}

std::string listModelIndexJson(const std::string & modelDir)
{
	const std::string jsonl = modelDir + "/index.jsonl";
	if(UFile::exists(jsonl))
	{
		return listJsonlArray(jsonl, "places");
	}
	std::ostringstream oss;
	oss << "{\"ok\":true,\"places\":[";
	bool first = true;
	if(UDirectory::exists(modelDir))
	{
		UDirectory d(modelDir, "json");
		const std::list<std::string> & names = d.getFileNames();
		for(std::list<std::string>::const_iterator it = names.begin(); it != names.end(); ++it)
		{
			if(it->size() < 15 || it->compare(it->size() - 14, 14, ".analysis.json") != 0)
			{
				continue;
			}
			const std::string arr = extractJsonArray(readFile(modelDir + "/" + *it), "places");
			if(arr.size() < 2)
			{
				continue;
			}
			const std::string inner = arr.substr(1, arr.size() - 2);
			size_t i = 0;
			while(i < inner.size() && std::isspace(static_cast<unsigned char>(inner[i])))
			{
				++i;
			}
			if(i >= inner.size())
			{
				continue;
			}
			if(!first)
			{
				oss << ",";
			}
			first = false;
			oss << inner;
		}
	}
	oss << "]}";
	return oss.str();
}

void enqueueModelIndex(const std::string & dataDir, const std::string & modelPath)
{
	if(modelPath.empty() || !UFile::exists(modelPath))
	{
		return;
	}
	const std::string sidecar = modelPath + ".json";
	if(!geminiKeyConfigured(dataDir))
	{
		setSidecarString(sidecar, "index_status", "unavailable");
		setSidecarString(sidecar, "index_error",
			"Set GEMINI_API_KEY or put the key in collab-data/gemini.key");
		std::printf("[collab] model index skipped (no Gemini key) %s\n", modelPath.c_str());
		std::fflush(stdout);
		return;
	}
	const std::string script = findSummarizeScript();
	if(script.empty())
	{
		setSidecarString(sidecar, "index_status", "error");
		setSidecarString(sidecar, "index_error", "video_summarize.py not found");
		std::printf("[collab] model index missing script\n");
		std::fflush(stdout);
		return;
	}
	setSidecarString(sidecar, "index_status", "pending");
	setSidecarString(sidecar, "index_error", "");
	::signal(SIGCHLD, SIG_IGN);
	const pid_t pid = ::fork();
	if(pid < 0)
	{
		setSidecarString(sidecar, "index_status", "error");
		setSidecarString(sidecar, "index_error", "fork failed");
		return;
	}
	if(pid > 0)
	{
		std::printf("[collab] model index queued name=%s pid=%d\n",
			UFile::getName(modelPath).c_str(), static_cast<int>(pid));
		std::fflush(stdout);
		return;
	}
	::setsid();
	const std::string py = findPython();
	if(!py.empty() && py[0] == '/')
	{
		::execl(py.c_str(), py.c_str(), script.c_str(),
			"--model", modelPath.c_str(),
			"--data-dir", dataDir.c_str(),
			static_cast<char *>(0));
	}
	else
	{
		::execlp("python3", "python3", script.c_str(),
			"--model", modelPath.c_str(),
			"--data-dir", dataDir.c_str(),
			static_cast<char *>(0));
	}
	std::fprintf(stderr, "[collab] model index exec failed script=%s\n", script.c_str());
	::_exit(127);
}

void enqueuePendingModelIndexes(const std::string & dataDir)
{
	const std::string dir = dataDir + "/models";
	if(!UDirectory::exists(dir))
	{
		return;
	}
	UDirectory d(dir, "ply");
	const std::list<std::string> & names = d.getFileNames();
	for(std::list<std::string>::const_iterator it = names.begin(); it != names.end(); ++it)
	{
		const std::string path = dir + "/" + *it;
		const std::string status = jsonFieldString(readFile(path + ".json"), "index_status");
		if(status == "ready" || status == "processing" || status == "pending")
		{
			continue;
		}
		if(status.empty() && UFile::exists(modelAnalysisPath(path)))
		{
			continue;
		}
		enqueueModelIndex(dataDir, path);
	}
}

std::string lexicalHistorySearch(const std::string & dataDir, const std::string & query)
{
	std::string q = query;
	for(size_t i = 0; i < q.size(); ++i)
	{
		q[i] = static_cast<char>(std::tolower(static_cast<unsigned char>(q[i])));
	}
	std::ostringstream oss;
	oss << "{\"ok\":true,\"query\":\"" << jsonEscape(query) << "\",\"hits\":[";
	bool first = true;
	int n = 0;
	const char * files[] = {"/videos/tasks.jsonl", "/models/index.jsonl", 0};
	for(int f = 0; files[f] && n < 12; ++f)
	{
		const std::string path = dataDir + files[f];
		if(!UFile::exists(path))
		{
			continue;
		}
		std::ifstream in(path.c_str());
		std::string line;
		while(std::getline(in, line) && n < 12)
		{
			std::string low = line;
			for(size_t i = 0; i < low.size(); ++i)
			{
				low[i] = static_cast<char>(std::tolower(static_cast<unsigned char>(low[i])));
			}
			if(q.empty() || low.find(q) == std::string::npos)
			{
				continue;
			}
			if(!first)
			{
				oss << ",";
			}
			first = false;
			oss << line;
			++n;
		}
	}
	oss << "],\"count\":" << n << "}";
	return oss.str();
}

std::string runPythonSearch(const std::string & dataDir, const std::string & query)
{
	const std::string script = findSummarizeScript();
	if(script.empty())
	{
		return "";
	}
	int fds[2];
	if(::pipe(fds) != 0)
	{
		return "";
	}
	const pid_t pid = ::fork();
	if(pid < 0)
	{
		::close(fds[0]);
		::close(fds[1]);
		return "";
	}
	if(pid == 0)
	{
		::close(fds[0]);
		::dup2(fds[1], STDOUT_FILENO);
		::close(fds[1]);
		const std::string py = findPython();
		if(!py.empty() && py[0] == '/')
		{
			::execl(py.c_str(), py.c_str(), script.c_str(),
				"--search", "--query", query.c_str(),
				"--data-dir", dataDir.c_str(),
				static_cast<char *>(0));
		}
		else
		{
			::execlp("python3", "python3", script.c_str(),
				"--search", "--query", query.c_str(),
				"--data-dir", dataDir.c_str(),
				static_cast<char *>(0));
		}
		::_exit(127);
	}
	::close(fds[1]);
	std::string out;
	char buf[4096];
	const long deadlineMs = 25000;
	long waited = 0;
	while(waited < deadlineMs)
	{
		struct pollfd pfd;
		std::memset(&pfd, 0, sizeof(pfd));
		pfd.fd = fds[0];
		pfd.events = POLLIN;
		const int pr = ::poll(&pfd, 1, 250);
		if(pr < 0)
		{
			break;
		}
		if(pr == 0)
		{
			waited += 250;
			int status = 0;
			if(::waitpid(pid, &status, WNOHANG) == pid && out.empty())
			{
				break;
			}
			continue;
		}
		const ssize_t n = ::read(fds[0], buf, sizeof(buf));
		if(n <= 0)
		{
			break;
		}
		out.append(buf, static_cast<size_t>(n));
	}
	::close(fds[0]);
	int status = 0;
	::waitpid(pid, &status, WNOHANG);
	size_t a = 0;
	while(a < out.size() && std::isspace(static_cast<unsigned char>(out[a])))
	{
		++a;
	}
	if(a >= out.size() || out[a] != '{')
	{
		return "";
	}
	return out.substr(a);
}

std::string historySearchJson(const std::string & dataDir, const std::string & rawQuery)
{
	const std::string query = urlDecode(rawQuery);
	if(query.empty())
	{
		return "{\"ok\":true,\"query\":\"\",\"hits\":[]}";
	}
	const std::string fromPy = runPythonSearch(dataDir, query);
	if(!fromPy.empty())
	{
		return fromPy;
	}
	return lexicalHistorySearch(dataDir, query);
}

}
