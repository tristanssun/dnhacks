#include "DemoTag.h"

#include <opencv2/core.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/objdetect.hpp>
#include <opencv2/objdetect/aruco_dictionary.hpp>

#include <mutex>
#include <vector>

namespace collab {

std::string demoTagPng()
{
	static std::mutex mutex;
	static std::string cached;
	std::lock_guard<std::mutex> lock(mutex);
	if(!cached.empty())
	{
		return cached;
	}

	cv::aruco::Dictionary dict = cv::aruco::getPredefinedDictionary(cv::aruco::DICT_4X4_50);
	cv::Mat marker;
	dict.generateImageMarker(kDemoTagId, 720, marker, 1);
	if(marker.empty())
	{
		return std::string();
	}
	const int quiet = 720 * 2 / 6;
	cv::Mat padded;
	cv::copyMakeBorder(marker, padded, quiet, quiet, quiet, quiet, cv::BORDER_CONSTANT, cv::Scalar(255));
	std::vector<uchar> buf;
	if(!cv::imencode(".png", padded, buf) || buf.empty())
	{
		return std::string();
	}
	cached.assign(reinterpret_cast<const char *>(buf.data()), buf.size());
	return cached;
}

}
