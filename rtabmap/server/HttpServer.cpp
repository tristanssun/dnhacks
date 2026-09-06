#include "HttpServer.h"

#include <rtabmap/utilite/UFile.h>
#include <rtabmap/utilite/UDirectory.h>
#include <rtabmap/utilite/ULogger.h>
#include <rtabmap/utilite/UConversion.h>
#include <sys/stat.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <sstream>
#include <thread>
#include <vector>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

namespace collab {

namespace {

std::string toLower(const std::string & in)
{
	std::string out = in;
	std::transform(out.begin(), out.end(), out.begin(), ::tolower);
	return out;
}

std::string trim(const std::string & in)
{
	size_t start = 0;
	while(start < in.size() && (in[start] == ' ' || in[start] == '\t' || in[start] == '\r'))
	{
		++start;
	}
	size_t end = in.size();
	while(end > start && (in[end-1] == ' ' || in[end-1] == '\t' || in[end-1] == '\r'))
	{
		--end;
	}
	return in.substr(start, end - start);
}

std::string pathOnly(const std::string & target)
{
	size_t q = target.find('?');
	return q == std::string::npos ? target : target.substr(0, q);
}

std::string queryOnly(const std::string & target)
{
	size_t q = target.find('?');
	return q == std::string::npos ? std::string() : target.substr(q + 1);
}

void parseQuery(const std::string & query, std::map<std::string, std::string> & out)
{
	size_t start = 0;
	while(start < query.size())
	{
		size_t amp = query.find('&', start);
		if(amp == std::string::npos)
		{
			amp = query.size();
		}
		std::string pair = query.substr(start, amp - start);
		size_t eq = pair.find('=');
		if(eq != std::string::npos)
		{
			out[pair.substr(0, eq)] = pair.substr(eq + 1);
		}
		else if(!pair.empty())
		{
			out[pair] = "";
		}
		start = amp + 1;
	}
}

bool writeAll(int fd, const void * data, size_t size)
{
	const char * p = static_cast<const char *>(data);
	size_t sent = 0;
	while(sent < size)
	{
		ssize_t n = ::send(fd, p + sent, size - sent, 0);
		if(n <= 0)
		{
			return false;
		}
		sent += static_cast<size_t>(n);
	}
	return true;
}

void flushLogs()
{
	std::fflush(stdout);
	std::fflush(stderr);
}

void setClientSocketOpts(int fd)
{
	int yes = 1;
#ifdef SO_NOSIGPIPE
	::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
#ifdef TCP_NODELAY
	::setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
#endif
	timeval tv;
	tv.tv_sec = 120;
	tv.tv_usec = 0;
	::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	::setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
	int buf = 1024 * 1024;
	::setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buf, sizeof(buf));
}

}

HttpResponse HttpResponse::text(int status, const std::string & contentType, const std::string & body)
{
	HttpResponse r;
	r.status = status;
	r.statusText = status == 200 ? "OK" : "Error";
	r.contentType = contentType;
	r.body = body;
	r.deleteFileAfterSend = false;
	return r;
}

HttpResponse HttpResponse::json(int status, const std::string & body)
{
	return text(status, "application/json", body);
}

HttpResponse HttpResponse::file(int status, const std::string & path, const std::string & contentType, const std::string & fileName)
{
	HttpResponse r;
	r.status = status;
	r.statusText = "OK";
	r.contentType = contentType;
	r.filePath = path;
	r.fileName = fileName;
	r.deleteFileAfterSend = false;
	return r;
}

HttpResponse HttpResponse::error(int status, const std::string & message)
{
	return json(status, std::string("{\"ok\":false,\"error\":\"") + jsonEscape(message) + "\"}");
}

HttpServer::HttpServer(int port, const std::string & uploadDir, const Handler & handler) :
	port_(port),
	uploadDir_(uploadDir),
	handler_(handler),
	listenFd_(-1),
	running_(false)
{
}

int HttpServer::run()
{
	if(!bindListen())
	{
		return 1;
	}
	running_ = true;
	UINFO("Listening on 0.0.0.0:%d", port_);
	flushLogs();
	while(running_)
	{
		pollfd pfd;
		pfd.fd = listenFd_;
		pfd.events = POLLIN;
		pfd.revents = 0;
		int pr = ::poll(&pfd, 1, 500);
		if(pr < 0)
		{
			if(!running_)
			{
				break;
			}
			continue;
		}
		if(pr == 0 || !(pfd.revents & POLLIN))
		{
			continue;
		}
		sockaddr_in addr;
		socklen_t addrLen = sizeof(addr);
		int client = ::accept(listenFd_, reinterpret_cast<sockaddr *>(&addr), &addrLen);
		if(client < 0)
		{
			continue;
		}
		setClientSocketOpts(client);
		// Detach so /status is not blocked behind a large /sync body or ingest.
		std::thread([this, client]() {
			handleClient(client);
			::close(client);
		}).detach();
	}
	if(listenFd_ >= 0)
	{
		::close(listenFd_);
		listenFd_ = -1;
	}
	return 0;
}

void HttpServer::stop()
{
	running_ = false;
}

bool HttpServer::bindListen()
{
	listenFd_ = ::socket(AF_INET, SOCK_STREAM, 0);
	if(listenFd_ < 0)
	{
		UERROR("socket() failed");
		return false;
	}
	int yes = 1;
	::setsockopt(listenFd_, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
#ifdef SO_NOSIGPIPE
	::setsockopt(listenFd_, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
	sockaddr_in addr;
	std::memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_addr.s_addr = htonl(INADDR_ANY);
	addr.sin_port = htons(static_cast<uint16_t>(port_));
	if(::bind(listenFd_, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) < 0)
	{
		UERROR("bind() to 0.0.0.0:%d failed", port_);
		::close(listenFd_);
		listenFd_ = -1;
		return false;
	}
	if(::listen(listenFd_, 16) < 0)
	{
		UERROR("listen() failed");
		::close(listenFd_);
		listenFd_ = -1;
		return false;
	}
	return true;
}

void HttpServer::handleClient(int fd)
{
	HttpRequest req;
	try
	{
		if(!readRequest(fd, req))
		{
			HttpResponse err = HttpResponse::error(400, "malformed request");
			writeResponse(fd, err);
			if(!req.bodyPath.empty())
			{
				UFile::erase(req.bodyPath);
			}
			flushLogs();
			return;
		}
		HttpResponse res;
		try
		{
			res = handler_(req);
		}
		catch(const std::exception & e)
		{
			res = HttpResponse::error(500, e.what());
		}
		catch(...)
		{
			res = HttpResponse::error(500, "handler failed");
		}
		writeResponse(fd, res);
		flushLogs();
		if(!req.bodyPath.empty())
		{
			UFile::erase(req.bodyPath);
		}
	}
	catch(...)
	{
		UERROR("handleClient: uncaught exception");
		flushLogs();
		if(!req.bodyPath.empty())
		{
			UFile::erase(req.bodyPath);
		}
	}
}

bool HttpServer::readRequest(int fd, HttpRequest & req)
{
	req.bodyBytes = 0;
	std::string headerBuf;
	headerBuf.reserve(4096);
	char chunk[4096];
	const size_t kMaxHeaders = 64 * 1024;
	while(headerBuf.find("\r\n\r\n") == std::string::npos)
	{
		ssize_t n = ::recv(fd, chunk, sizeof(chunk), 0);
		if(n <= 0)
		{
			return false;
		}
		headerBuf.append(chunk, static_cast<size_t>(n));
		if(headerBuf.size() > kMaxHeaders)
		{
			return false;
		}
	}
	size_t headerEnd = headerBuf.find("\r\n\r\n");
	std::string leftover = headerBuf.substr(headerEnd + 4);
	headerBuf.resize(headerEnd);

	std::istringstream hs(headerBuf);
	std::string line;
	if(!std::getline(hs, line))
	{
		return false;
	}
	if(!line.empty() && line[line.size()-1] == '\r')
	{
		line.resize(line.size()-1);
	}
	std::istringstream first(line);
	std::string version;
	if(!(first >> req.method >> req.path >> version))
	{
		return false;
	}
	req.query = queryOnly(req.path);
	parseQuery(req.query, req.params);
	req.path = pathOnly(req.path);

	while(std::getline(hs, line))
	{
		if(!line.empty() && line[line.size()-1] == '\r')
		{
			line.resize(line.size()-1);
		}
		size_t colon = line.find(':');
		if(colon == std::string::npos)
		{
			continue;
		}
		std::string key = toLower(trim(line.substr(0, colon)));
		std::string value = trim(line.substr(colon + 1));
		req.headers[key] = value;
	}

	long contentLength = 0;
	std::map<std::string, std::string>::const_iterator cl = req.headers.find("content-length");
	if(cl != req.headers.end())
	{
		contentLength = std::strtol(cl->second.c_str(), 0, 10);
		if(contentLength < 0)
		{
			contentLength = 0;
		}
	}
	req.bodyBytes = contentLength;
	if(contentLength <= 0)
	{
		// High-rate polling endpoints (admin page at 4 Hz per tab, phone /demo
		// and /pose) would otherwise dominate server.log. Keep them at debug.
		if(req.path == "/demo" || req.path == "/status" || req.path == "/map.mesh" ||
		   req.path == "/tag.png" || req.path == "/favicon.ico")
		{
			UDEBUG("HTTP %s %s (no body)", req.method.c_str(), req.path.c_str());
		}
		else
		{
			UINFO("HTTP %s %s (no body)", req.method.c_str(), req.path.c_str());
			flushLogs();
		}
		return true;
	}

	const long kMaxBody = 1024L * 1024L * 1024L;
	if(contentLength > kMaxBody)
	{
		UERROR("POST body too large: %ld", contentLength);
		return false;
	}

	static std::atomic<int> uploadSeq{0};
	const int seq = ++uploadSeq;
	req.bodyPath = uploadDir_ + "/upload-" + uNumber2Str(seq) + ".db";
	FILE * out = std::fopen(req.bodyPath.c_str(), "wb");
	if(!out)
	{
		UERROR("Cannot write upload to %s", req.bodyPath.c_str());
		flushLogs();
		return false;
	}

	// /pose (3 Hz per phone) and /heartbeat carry tiny JSON bodies; keep their
	// per-request lines at debug so uploads and calibrations stay readable.
	const bool quietBody = (req.path == "/pose" || req.path == "/heartbeat");
	if(quietBody)
	{
		UDEBUG("HTTP %s %s reading body content-length=%ld", req.method.c_str(), req.path.c_str(), contentLength);
	}
	else
	{
		UINFO("HTTP %s %s reading body content-length=%ld -> %s",
			req.method.c_str(), req.path.c_str(), contentLength, req.bodyPath.c_str());
		flushLogs();
	}

	long written = 0;
	if(!leftover.empty())
	{
		size_t take = std::min(leftover.size(), static_cast<size_t>(contentLength));
		if(std::fwrite(leftover.data(), 1, take, out) != take)
		{
			std::fclose(out);
			UERROR("HTTP body fwrite leftover failed");
			flushLogs();
			return false;
		}
		written += static_cast<long>(take);
	}
	while(written < contentLength)
	{
		size_t want = static_cast<size_t>(std::min<long>(sizeof(chunk), contentLength - written));
		ssize_t n = ::recv(fd, chunk, want, 0);
		if(n <= 0)
		{
			std::fclose(out);
			UERROR("HTTP body recv failed after %ld/%ld bytes", written, contentLength);
			flushLogs();
			return false;
		}
		if(std::fwrite(chunk, 1, static_cast<size_t>(n), out) != static_cast<size_t>(n))
		{
			std::fclose(out);
			UERROR("HTTP body fwrite failed after %ld/%ld bytes", written, contentLength);
			flushLogs();
			return false;
		}
		written += n;
	}
	std::fflush(out);
	std::fclose(out);
	if(quietBody)
	{
		UDEBUG("HTTP %s %s body complete bytes=%ld", req.method.c_str(), req.path.c_str(), written);
	}
	else
	{
		UINFO("HTTP %s %s body complete bytes=%ld", req.method.c_str(), req.path.c_str(), written);
		flushLogs();
	}
	return true;
}

bool HttpServer::writeResponse(int fd, const HttpResponse & res)
{
	std::ostringstream oss;
	std::string statusText = res.statusText.empty() ? (res.status == 200 ? "OK" : "Error") : res.statusText;
	if(res.status == 404) statusText = "Not Found";
	if(res.status == 400) statusText = "Bad Request";
	if(res.status == 405) statusText = "Method Not Allowed";
	if(res.status == 500) statusText = "Internal Server Error";

	long length = static_cast<long>(res.body.size());
	if(!res.filePath.empty() && UFile::exists(res.filePath))
	{
		length = UFile::length(res.filePath);
		if(length < 0)
		{
			length = 0;
		}
	}

	oss << "HTTP/1.1 " << res.status << " " << statusText << "\r\n";
	oss << "Content-Type: " << (res.contentType.empty() ? "text/plain" : res.contentType) << "\r\n";
	oss << "Content-Length: " << length << "\r\n";
	if(!res.fileName.empty())
	{
		oss << "Content-Disposition: attachment; filename=\"" << res.fileName << "\"\r\n";
	}
	for(std::map<std::string, std::string>::const_iterator it = res.extraHeaders.begin(); it != res.extraHeaders.end(); ++it)
	{
		oss << it->first << ": " << it->second << "\r\n";
	}
	oss << "Connection: close\r\n\r\n";
	std::string head = oss.str();
	if(!writeAll(fd, head.data(), head.size()))
	{
		if(res.deleteFileAfterSend && !res.filePath.empty())
		{
			UFile::erase(res.filePath);
		}
		return false;
	}
	bool ok = true;
	if(!res.filePath.empty())
	{
		ok = sendFile(fd, res.filePath);
	}
	else if(!res.body.empty())
	{
		ok = writeAll(fd, res.body.data(), res.body.size());
	}
	if(res.deleteFileAfterSend && !res.filePath.empty())
	{
		UFile::erase(res.filePath);
	}
	return ok;
}

bool HttpServer::sendFile(int fd, const std::string & path)
{
	FILE * in = std::fopen(path.c_str(), "rb");
	if(!in)
	{
		return false;
	}
	char buf[64 * 1024];
	size_t n;
	while((n = std::fread(buf, 1, sizeof(buf), in)) > 0)
	{
		if(!writeAll(fd, buf, n))
		{
			std::fclose(in);
			return false;
		}
	}
	std::fclose(in);
	return true;
}

std::string headerValue(const HttpRequest & req, const std::string & name)
{
	std::map<std::string, std::string>::const_iterator it = req.headers.find(toLower(name));
	if(it == req.headers.end())
	{
		return "";
	}
	return it->second;
}

std::string queryValue(const HttpRequest & req, const std::string & name)
{
	std::map<std::string, std::string>::const_iterator it = req.params.find(name);
	if(it == req.params.end())
	{
		return "";
	}
	return it->second;
}

std::string jsonEscape(const std::string & in)
{
	std::string out;
	out.reserve(in.size());
	for(size_t i = 0; i < in.size(); ++i)
	{
		char c = in[i];
		if(c == '\\' || c == '"')
		{
			out.push_back('\\');
			out.push_back(c);
		}
		else if(c == '\n')
		{
			out += "\\n";
		}
		else if(c == '\r')
		{
			out += "\\r";
		}
		else
		{
			out.push_back(c);
		}
	}
	return out;
}

std::string jsonFieldString(const std::string & meta, const char * key)
{
	if(!key || !key[0])
	{
		return "";
	}
	const std::string needle = std::string("\"") + key + "\":";
	size_t p = meta.find(needle);
	if(p == std::string::npos)
	{
		return "";
	}
	p += needle.size();
	while(p < meta.size() && (meta[p] == ' ' || meta[p] == '\t' || meta[p] == '\n' || meta[p] == '\r'))
	{
		++p;
	}
	if(p >= meta.size() || meta[p] != '"')
	{
		return "";
	}
	++p;
	std::string out;
	for(; p < meta.size(); ++p)
	{
		if(meta[p] == '\\' && p + 1 < meta.size())
		{
			out.push_back(meta[p + 1]);
			++p;
			continue;
		}
		if(meta[p] == '"')
		{
			break;
		}
		out.push_back(meta[p]);
	}
	return out;
}

std::string jsonStringArray(const std::vector<std::string> & values)
{
	std::ostringstream oss;
	oss << "[";
	for(size_t i = 0; i < values.size(); ++i)
	{
		if(i)
		{
			oss << ",";
		}
		oss << "\"" << jsonEscape(values[i]) << "\"";
	}
	oss << "]";
	return oss.str();
}

std::vector<std::string> jsonFieldStringArray(const std::string & meta, const char * key)
{
	std::vector<std::string> out;
	if(!key || !key[0])
	{
		return out;
	}
	const std::string needle = std::string("\"") + key + "\":";
	size_t p = meta.find(needle);
	if(p == std::string::npos)
	{
		return out;
	}
	p += needle.size();
	while(p < meta.size() && (meta[p] == ' ' || meta[p] == '\t' || meta[p] == '\n' || meta[p] == '\r'))
	{
		++p;
	}
	if(p >= meta.size() || meta[p] != '[')
	{
		const std::string one = jsonFieldString(meta, key);
		if(!one.empty())
		{
			out.push_back(one);
		}
		return out;
	}
	++p;
	while(p < meta.size())
	{
		while(p < meta.size() && (meta[p] == ' ' || meta[p] == '\t' || meta[p] == '\n' || meta[p] == '\r' || meta[p] == ','))
		{
			++p;
		}
		if(p >= meta.size() || meta[p] == ']')
		{
			break;
		}
		if(meta[p] != '"')
		{
			break;
		}
		++p;
		std::string item;
		for(; p < meta.size(); ++p)
		{
			if(meta[p] == '\\' && p + 1 < meta.size())
			{
				item.push_back(meta[p + 1]);
				++p;
				continue;
			}
			if(meta[p] == '"')
			{
				++p;
				break;
			}
			item.push_back(meta[p]);
		}
		if(!item.empty())
		{
			out.push_back(item);
		}
	}
	return out;
}

std::string sanitizeAddress(const std::string & in)
{
	std::string out;
	out.reserve(in.size());
	for(size_t i = 0; i < in.size(); ++i)
	{
		const unsigned char c = static_cast<unsigned char>(in[i]);
		if(c < 32 || c == 127)
		{
			continue;
		}
		out.push_back(static_cast<char>(c));
		if(out.size() >= 200)
		{
			break;
		}
	}
	while(!out.empty() && (out[0] == ' ' || out[0] == ','))
	{
		out.erase(0, 1);
	}
	while(!out.empty() && (out[out.size() - 1] == ' ' || out[out.size() - 1] == ','))
	{
		out.erase(out.size() - 1);
	}
	return out;
}

std::string formatRunName(const std::string & address, long unixTime)
{
	const std::time_t t = unixTime > 0 ? static_cast<std::time_t>(unixTime) : std::time(0);
	std::tm local;
	if(!localtime_r(&t, &local))
	{
		return address;
	}
	char buf[64];
	std::strftime(buf, sizeof(buf), "%b %d, %I:%M %p", &local);
	std::string stamp(buf);
	// "Sep 06, 05:51 AM" -> "Sep 6, 5:51 AM"
	size_t i = 0;
	while(i + 1 < stamp.size())
	{
		if((i == 0 || stamp[i - 1] == ' ' || stamp[i - 1] == ',') && stamp[i] == '0' &&
			stamp[i + 1] >= '1' && stamp[i + 1] <= '9')
		{
			stamp.erase(i, 1);
			continue;
		}
		++i;
	}
	if(address.empty())
	{
		return stamp;
	}
	return address + " · " + stamp;
}

// Recording names come from the phone and from URLs: keep a plain file name
// (letters, digits, dot, dash, underscore), no path parts, always ".mp4".
std::string sanitizeVideoName(const std::string & in)
{
	std::string out;
	for(size_t i = 0; i < in.size(); ++i)
	{
		const char c = in[i];
		if(std::isalnum(static_cast<unsigned char>(c)) || c == '.' || c == '-' || c == '_')
		{
			out.push_back(c);
		}
	}
	while(!out.empty() && out[0] == '.')
	{
		out.erase(0, 1);
	}
	if(out.empty())
	{
		return out;
	}
	if(out.size() < 4 || out.compare(out.size() - 4, 4, ".mp4") != 0)
	{
		out += ".mp4";
	}
	return out;
}

// JSON array of the .mp4 files in dir, newest first, with their sidecar
// metadata (client, duration) when the upload wrote one.
std::string listVideosJson(
	const std::string & dir,
	int currentRun,
	const std::string & currentAddress,
	long currentStarted,
	double currentLat,
	double currentLng)
{
	if(currentRun < 1)
	{
		currentRun = 1;
	}
	std::vector<std::pair<long, std::string> > files; // (mtime, name)
	if(UDirectory::exists(dir))
	{
		UDirectory d(dir, "mp4");
		const std::list<std::string> & names = d.getFileNames();
		for(std::list<std::string>::const_iterator it = names.begin(); it != names.end(); ++it)
		{
			const std::string path = dir + "/" + *it;
			struct stat st;
			if(::stat(path.c_str(), &st) == 0)
			{
				files.push_back(std::make_pair((long)st.st_mtime, *it));
			}
		}
	}
	std::sort(files.begin(), files.end());
	std::ostringstream oss;
	oss << "{\"ok\":true,\"videos\":[";
	bool first = true;
	for(std::vector<std::pair<long, std::string> >::reverse_iterator it = files.rbegin(); it != files.rend(); ++it)
	{
		const std::string path = dir + "/" + it->second;
		std::string client;
		std::string summaryStatus;
		std::string address;
		double duration = 0.0;
		double lat = 0.0;
		double lng = 0.0;
		int run = currentRun;
		int taskCount = 0;
		long uploaded = 0;
		{
			// sidecar: {"name":..,"client":"..","bytes":..,"duration_s":..,"uploaded":..,"run":..,"address":..}
			FILE * f = std::fopen((path + ".json").c_str(), "rb");
			if(f)
			{
				char buf[8192];
				const size_t n = std::fread(buf, 1, sizeof(buf) - 1, f);
				std::fclose(f);
				buf[n] = 0;
				const std::string meta(buf);
				client = jsonFieldString(meta, "client");
				address = sanitizeAddress(jsonFieldString(meta, "address"));
				size_t p = meta.find("\"duration_s\":");
				if(p != std::string::npos)
				{
					duration = std::atof(meta.c_str() + p + 13);
				}
				p = meta.find("\"run\":");
				if(p != std::string::npos)
				{
					run = std::atoi(meta.c_str() + p + 6);
					if(run < 1) run = currentRun;
				}
				summaryStatus = jsonFieldString(meta, "summary_status");
				p = meta.find("\"task_count\":");
				if(p != std::string::npos)
				{
					taskCount = std::atoi(meta.c_str() + p + 13);
				}
				p = meta.find("\"uploaded\":");
				if(p != std::string::npos)
				{
					uploaded = std::atol(meta.c_str() + p + 11);
				}
				p = meta.find("\"lat\":");
				if(p != std::string::npos)
				{
					lat = std::atof(meta.c_str() + p + 6);
				}
				p = meta.find("\"lng\":");
				if(p != std::string::npos)
				{
					lng = std::atof(meta.c_str() + p + 6);
				}
			}
		}
		if(address.empty() && run >= currentRun)
		{
			address = currentAddress;
		}
		if(lat == 0.0 && lng == 0.0 && run >= currentRun)
		{
			lat = currentLat;
			lng = currentLng;
		}
		const long titleAt = uploaded > 0 ? uploaded : (run >= currentRun && currentStarted > 0 ? currentStarted : it->first);
		const std::string title = formatRunName(address, titleAt);
		const bool current = run >= currentRun;
		if(!first) oss << ",";
		first = false;
		oss << "{\"name\":\"" << jsonEscape(it->second) << "\""
			<< ",\"url\":\"/videos/" << jsonEscape(it->second) << "\""
			<< ",\"client\":\"" << jsonEscape(client) << "\""
			<< ",\"bytes\":" << UFile::length(path)
			<< ",\"duration_s\":" << duration
			<< ",\"run\":" << run
			<< ",\"current\":" << (current ? "true" : "false")
			<< ",\"summary_status\":\"" << jsonEscape(summaryStatus) << "\""
			<< ",\"task_count\":" << taskCount
			<< ",\"address\":\"" << jsonEscape(address) << "\""
			<< ",\"lat\":" << lat
			<< ",\"lng\":" << lng
			<< ",\"title\":\"" << jsonEscape(title) << "\""
			<< ",\"mtime\":" << it->first << "}";
	}
	oss << "],\"current_run\":" << currentRun
		<< ",\"run_address\":\"" << jsonEscape(currentAddress) << "\""
		<< ",\"run_lat\":" << currentLat
		<< ",\"run_lng\":" << currentLng
		<< ",\"run_started\":" << currentStarted
		<< ",\"run_name\":\"" << jsonEscape(formatRunName(currentAddress, currentStarted)) << "\"}";
	return oss.str();
}

// Mesh archive names from URLs: plain file name, .ply or .jpg only.
std::string sanitizeModelName(const std::string & in)
{
	std::string out;
	for(size_t i = 0; i < in.size(); ++i)
	{
		const char c = in[i];
		if(std::isalnum(static_cast<unsigned char>(c)) || c == '.' || c == '-' || c == '_')
		{
			out.push_back(c);
		}
	}
	while(!out.empty() && out[0] == '.')
	{
		out.erase(0, 1);
	}
	if(out.empty())
	{
		return out;
	}
	const bool jpg = out.size() >= 4 && out.compare(out.size() - 4, 4, ".jpg") == 0;
	const bool ply = out.size() >= 4 && out.compare(out.size() - 4, 4, ".ply") == 0;
	if(!jpg && !ply)
	{
		out += ".ply";
	}
	return out;
}

static void readModelSidecar(
	const std::string & path,
	int & nodes,
	int & verts,
	int & faces,
	bool & textured,
	int & run,
	long & created,
	std::string & kind,
	std::string & address,
	std::vector<std::string> & users,
	double & lat,
	double & lng,
	std::string & indexStatus,
	int & placeCount)
{
	nodes = 0;
	verts = 0;
	faces = 0;
	textured = false;
	run = 0;
	created = 0;
	lat = 0;
	lng = 0;
	placeCount = 0;
	kind.clear();
	address.clear();
	users.clear();
	indexStatus.clear();
	FILE * f = std::fopen((path + ".json").c_str(), "rb");
	if(!f)
	{
		return;
	}
	char buf[4096];
	const size_t n = std::fread(buf, 1, sizeof(buf) - 1, f);
	std::fclose(f);
	buf[n] = 0;
	const std::string meta(buf);
	size_t p = meta.find("\"nodes\":");
	if(p != std::string::npos) nodes = std::atoi(meta.c_str() + p + 8);
	p = meta.find("\"verts\":");
	if(p != std::string::npos) verts = std::atoi(meta.c_str() + p + 8);
	p = meta.find("\"faces\":");
	if(p != std::string::npos) faces = std::atoi(meta.c_str() + p + 8);
	p = meta.find("\"textured\":");
	if(p != std::string::npos)
	{
		const char * s = meta.c_str() + p + 11;
		while(*s == ' ') ++s;
		textured = (*s == 't' || *s == '1');
	}
	p = meta.find("\"run\":");
	if(p != std::string::npos) run = std::atoi(meta.c_str() + p + 6);
	p = meta.find("\"created\":");
	if(p != std::string::npos) created = std::atol(meta.c_str() + p + 10);
	kind = jsonFieldString(meta, "kind");
	address = sanitizeAddress(jsonFieldString(meta, "address"));
	p = meta.find("\"lat\":");
	if(p != std::string::npos) lat = std::atof(meta.c_str() + p + 6);
	p = meta.find("\"lng\":");
	if(p != std::string::npos) lng = std::atof(meta.c_str() + p + 6);
	users = jsonFieldStringArray(meta, "users");
	if(users.empty())
	{
		const std::string one = jsonFieldString(meta, "user");
		if(!one.empty())
		{
			users.push_back(one);
		}
	}
	indexStatus = jsonFieldString(meta, "index_status");
	p = meta.find("\"place_count\":");
	if(p != std::string::npos) placeCount = std::atoi(meta.c_str() + p + 14);
}

std::string listModelsJson(const std::string & dir)
{
	std::vector<std::pair<long, std::string> > files;
	if(UDirectory::exists(dir))
	{
		UDirectory d(dir, "ply");
		const std::list<std::string> & names = d.getFileNames();
		for(std::list<std::string>::const_iterator it = names.begin(); it != names.end(); ++it)
		{
			const std::string path = dir + "/" + *it;
			struct stat st;
			if(::stat(path.c_str(), &st) == 0 && st.st_size > 0)
			{
				files.push_back(std::make_pair((long)st.st_mtime, *it));
			}
		}
	}
	std::sort(files.begin(), files.end());
	std::ostringstream oss;
	oss << "{\"ok\":true,\"models\":[";
	bool first = true;
	for(std::vector<std::pair<long, std::string> >::reverse_iterator it = files.rbegin(); it != files.rend(); ++it)
	{
		const std::string path = dir + "/" + it->second;
		int nodes = 0, verts = 0, faces = 0, run = 0, placeCount = 0;
		bool textured = false;
		long created = 0;
		std::string kind;
		std::string address;
		std::string indexStatus;
		std::vector<std::string> users;
		double lat = 0, lng = 0;
		readModelSidecar(path, nodes, verts, faces, textured, run, created, kind, address, users, lat, lng, indexStatus, placeCount);
		std::string stem = it->second;
		if(stem.size() > 4 && stem.compare(stem.size() - 4, 4, ".ply") == 0)
		{
			stem.erase(stem.size() - 4);
		}
		const std::string atlas = dir + "/" + stem + ".jpg";
		const bool haveAtlas = UFile::exists(atlas) && UFile::length(atlas) > 0;
		const long titleAt = created > 0 ? created : it->first;
		if(!first) oss << ",";
		first = false;
		oss << "{\"name\":\"" << jsonEscape(it->second) << "\""
			<< ",\"url\":\"/models/" << jsonEscape(it->second) << "\""
			<< ",\"atlas_url\":\"" << (haveAtlas ? ("/models/" + jsonEscape(stem) + ".jpg") : "") << "\""
			<< ",\"kind\":\"" << jsonEscape(kind.empty() ? (haveAtlas ? "baked" : "live") : kind) << "\""
			<< ",\"nodes\":" << nodes
			<< ",\"verts\":" << verts
			<< ",\"faces\":" << faces
			<< ",\"textured\":" << (textured || haveAtlas ? "true" : "false")
			<< ",\"bytes\":" << UFile::length(path)
			<< ",\"run\":" << run
			<< ",\"address\":\"" << jsonEscape(address) << "\""
			<< ",\"lat\":" << lat
			<< ",\"lng\":" << lng
			<< ",\"users\":" << jsonStringArray(users)
			<< ",\"title\":\"" << jsonEscape(formatRunName(address, titleAt)) << "\""
			<< ",\"index_status\":\"" << jsonEscape(indexStatus) << "\""
			<< ",\"place_count\":" << placeCount
			<< ",\"mtime\":" << it->first << "}";
	}
	oss << "]}";
	return oss.str();
}

}
