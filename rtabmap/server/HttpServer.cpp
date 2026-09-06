#include "HttpServer.h"

#include <rtabmap/utilite/UFile.h>
#include <rtabmap/utilite/ULogger.h>
#include <rtabmap/utilite/UConversion.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
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

}
