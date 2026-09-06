#ifndef COLLAB_HTTP_SERVER_H
#define COLLAB_HTTP_SERVER_H

#include <map>
#include <string>
#include <functional>

namespace collab {

struct HttpRequest
{
	std::string method;
	std::string path;
	std::string query;
	std::map<std::string, std::string> headers;
	std::map<std::string, std::string> params;
	std::string bodyPath;
	long bodyBytes;
};

struct HttpResponse
{
	int status;
	std::string statusText;
	std::string contentType;
	std::string body;
	std::string filePath;
	std::string fileName;
	std::map<std::string, std::string> extraHeaders;
	bool deleteFileAfterSend;

	static HttpResponse text(int status, const std::string & contentType, const std::string & body);
	static HttpResponse json(int status, const std::string & body);
	static HttpResponse file(int status, const std::string & path, const std::string & contentType, const std::string & fileName);
	static HttpResponse error(int status, const std::string & message);
};

class HttpServer
{
public:
	typedef std::function<HttpResponse(const HttpRequest &)> Handler;

	HttpServer(int port, const std::string & uploadDir, const Handler & handler);
	int run();
	void stop();

private:
	bool bindListen();
	void handleClient(int fd);
	bool readRequest(int fd, HttpRequest & req);
	bool writeResponse(int fd, const HttpResponse & res);
	bool sendFile(int fd, const std::string & path);

private:
	int port_;
	std::string uploadDir_;
	Handler handler_;
	int listenFd_;
	volatile bool running_;
};

std::string headerValue(const HttpRequest & req, const std::string & name);
std::string queryValue(const HttpRequest & req, const std::string & name);
std::string jsonEscape(const std::string & in);

}

#endif
