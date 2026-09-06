#ifndef COLLAB_VIDEO_SUMMARY_H
#define COLLAB_VIDEO_SUMMARY_H

#include <string>

namespace collab {

// Gemini scan-recording and archived-model indexes. The worker is
// server/video_summarize.py. Video results live next to the mp4 as
// <name>.analysis.json plus videos/tasks.jsonl. Model results live next
// to the ply as <name>.analysis.json plus models/index.jsonl. GET /search
// ranks both corpora.

bool geminiKeyConfigured(const std::string & dataDir);
bool splitVideoAction(const std::string & rest, std::string & name, std::string & action);
bool splitModelAction(const std::string & rest, std::string & name, std::string & action);
std::string videoAnalysisPath(const std::string & videoPath);
std::string videoAnalysisHttpBody(const std::string & videoPath);
std::string modelAnalysisPath(const std::string & modelPath);
std::string modelAnalysisHttpBody(const std::string & modelPath);
std::string listVideoTasksJson(const std::string & videoDir);
std::string listModelIndexJson(const std::string & modelDir);
std::string historySearchJson(const std::string & dataDir, const std::string & query);
void setSidecarString(const std::string & jsonPath, const std::string & key, const std::string & value);
void enqueueVideoSummary(const std::string & dataDir, const std::string & videoPath);
void enqueueModelIndex(const std::string & dataDir, const std::string & modelPath);
void enqueuePendingModelIndexes(const std::string & dataDir);

}

#endif
