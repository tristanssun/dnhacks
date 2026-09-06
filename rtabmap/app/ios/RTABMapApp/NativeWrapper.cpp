//
//  PCLWrapper.cpp
//  ThreeDScanner
//
//  Created by Steven Roach on 2/9/18.
//  Copyright © 2018 Steven Roach. All rights reserved.
//

#include "NativeWrapper.hpp"
#include "RTABMapApp.h"
#include <rtabmap/core/CameraModel.h>
#include <rtabmap/core/DBDriverSqlite3.h>
#include <rtabmap/core/MarkerDetector.h>
#include <rtabmap/core/Parameters.h>
#include <rtabmap/core/Signature.h>
#include <rtabmap/core/Transform.h>
#include <rtabmap/utilite/UConversion.h>
#include <rtabmap/utilite/UFile.h>
#include <rtabmap/utilite/ULogger.h>
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>>
#include <sqlite3.h>
#include <cmath>
#include <cstring>
#include <fstream>
#include <list>
#include <set>
#include <sstream>
#include <string>
#include <unistd.h>

inline RTABMapApp *native(const void *object) {
  return (RTABMapApp *)object;
}

const void * createNativeApplication()
{
    RTABMapApp *app = new RTABMapApp();
    return (void *)app;
}

void setupCallbacksNative(const void *object, void * classPtr,
                          void(*progressCallback)(void*, int, int),
                          void(*initCallback)(void *, int, const char*),
                          void(*statsUpdatedCallback)(void *,
                                                   int, int, int, int,
                                                   float,
                                                   int, int, int, int, int ,int,
                                                   float,
                                                   int,
                                                   float,
                                                   int,
                                                   float, float, float, float,
                                                   int, int,
                                                   float, float, float, float, float, float),
                          void(*cameraInfoEventCallback)(void *, int, const char*, const char*))
{
    if(object)
    {
        native(object)->setupSwiftCallbacks(classPtr, progressCallback, initCallback, statsUpdatedCallback, cameraInfoEventCallback);
    }
    else
    {
        UERROR("object is null!");
    }
}

void destroyNativeApplication(const void *object)
{
    if(object)
    {
        delete native(object);
    }
    else
    {
        UERROR("object is null!");
    }
}

void setScreenRotationNative(const void *object, int displayRotation)
{
    if(object)
    {
        return native(object)->setScreenRotation(displayRotation, 0);
    }
    else
    {
        UERROR("object is null!");
    }
}

int openDatabaseNative(const void *object, const char * databasePath, bool databaseInMemory, bool optimize, bool clearDatabase)
{
    if(object)
    {
        return native(object)->openDatabase(databasePath, databaseInMemory, optimize, clearDatabase);
    }
    else
    {
        UERROR("object is null!");
        return -1;
    }
}

void saveNative(const void *object, const char * databasePath)
{
    if(object)
    {
        return native(object)->save(databasePath);
    }
    else
    {
        UERROR("object is null!");
    }
}

bool recoverNative(const void *object, const char * from, const char * to)
{
    if(object)
    {
        return native(object)->recover(from, to);
    }
    else
    {
        UERROR("object is null!");
    }
    return false;
}

void cancelProcessingNative(const void *object)
{
    if(object)
    {
        native(object)->cancelProcessing();
    }
    else
    {
        UERROR("object is null!");
    }
}

int postProcessingNative(const void *object, int approach)
{
    if(object)
    {
        return native(object)->postProcessing(approach);
    }
    else
    {
        UERROR("object is null!");
    }
    return -1;
}

bool exportMeshNative(
            const void *object,
            float cloudVoxelSize,
            bool regenerateCloud,
            bool meshing,
            int textureSize,
            int textureCount,
            int normalK,
            bool optimized,
            float optimizedVoxelSize,
            int optimizedDepth,
            int optimizedMaxPolygons,
            float optimizedColorRadius,
            bool optimizedCleanWhitePolygons,
            int optimizedMinClusterSize,
            float optimizedMaxTextureDistance,
            int optimizedMinTextureClusterSize,
            int textureVertexColorPolicy,
            bool blockRendering)
{
    if(object)
    {
        return native(object)->exportMesh(cloudVoxelSize, regenerateCloud, meshing, textureSize, textureCount, normalK, optimized, optimizedVoxelSize, optimizedDepth, optimizedMaxPolygons, optimizedColorRadius, optimizedCleanWhitePolygons, optimizedMinClusterSize, optimizedMaxTextureDistance, optimizedMinTextureClusterSize, textureVertexColorPolicy, blockRendering);
    }
    else
    {
        UERROR("object is null!");
    }
    return false;
}

bool postExportationNative(const void *object, bool visualize)
{
    if(object)
    {
        return native(object)->postExportation(visualize);
    }
    else
    {
        UERROR("object is null!");
    }
    return false;
}

bool writeExportedMeshNative(const void *object, const char * directory, const char * name)
{
    if(object)
    {
        return native(object)->writeExportedMesh(directory, name);
    }
    else
    {
        UERROR("object is null!");
    }
    return false;
}

void initGlContentNative(const void *object) {
    if(object)
    {
        native(object)->InitializeGLContent();
    }
    else
    {
        UERROR("object is null!");
    }
}

void setupGraphicNative(const void *object, int width, int height) {
    if(object)
    {
        native(object)->SetViewPort(width, height);
    }
    else
    {
        UERROR("object is null!");
    }
}

void onTouchEventNative(const void *object, int touch_count, int event, float x0, float y0, float x1,
    float y1) {
    if(object)
    {
        using namespace tango_gl;
        GestureCamera::TouchEvent touch_event =
          static_cast<GestureCamera::TouchEvent>(event);
        native(object)->OnTouchEvent(touch_count, touch_event, x0, y0, x1, y1);
    }
    else
    {
        UERROR("object is null!");
    }
}

void setPausedMappingNative(const void *object, bool paused)
{
    if(object)
    {
        return native(object)->setPausedMapping(paused);
    }
    else
    {
        UERROR("object is null!");
    }
}

int renderNative(const void *object) {
    if(object)
    {
        return native(object)->Render();
    }
    else
    {
        UERROR("object is null!");
        return -1;
    }
}

bool startCameraNative(const void *object) {
    if(object)
    {
        return native(object)->startCamera();
    }
    else
    {
        UERROR("object is null!");
        return false;
    }
}

void stopCameraNative(const void *object) {
    if(object)
    {
        native(object)->stopCamera();
    }
    else
    {
        UERROR("object is null!");
    }
}

void setCameraNative(const void *object, int type) {
    if(object)
    {
        native(object)->SetCameraType(tango_gl::GestureCamera::CameraType(type));
    }
    else
    {
        UERROR("object is null!");
    }
}

void postOdometryEventNative(const void *object,
        float x, float y, float z, float qx, float qy, float qz, float qw,
        float fx, float fy, float cx, float cy,
        double stamp,
        const void * yPlane,  const void * uPlane,  const void * vPlane, int yPlaneLen, int rgbWidth, int rgbHeight, int rgbFormat,
        const void * depth, int depthLen, int depthWidth, int depthHeight, int depthFormat,
        const void * conf, int confLen, int confWidth, int confHeight, int confFormat,
        const void * points, int pointsLen, int pointsChannels,
        float vx, float vy, float vz, float vqx, float vqy, float vqz, float vqw,
        float p00, float p11, float p02, float p12, float p22, float p32, float p23,
        float t0, float t1, float t2, float t3, float t4, float t5, float t6, float t7)
{
    if(object)
    {
        native(object)->postOdometryEvent(
                (qx==0.0f && qy==0.0f && qz==0.0f && qw==0.0f)?rtabmap::Transform():rtabmap::Transform(x,y,z,qx,qy,qz,qw),
                fx,fy,cx,cy, 0,0,0,0,
                rtabmap::Transform(), rtabmap::Transform(),
                stamp, 0,
                yPlane, uPlane, vPlane, yPlaneLen, rgbWidth, rgbHeight, rgbFormat,
                depth, depthLen, depthWidth, depthHeight, depthFormat,
                conf, confLen, confWidth, confHeight, confFormat,
                (const float *)points, pointsLen, pointsChannels,
                rtabmap::Transform(vx, vy, vz, vqx, vqy, vqz, vqw),
                p00, p11, p02, p12, p22, p32, p23,
                t0, t1, t2, t3, t4, t5, t6, t7);
    }
    else
    {
        UERROR("object is null!");
        return;
    }
}

ImageNative getPreviewImageNative(const char * databasePath)
{
    ImageNative imageNative;
    imageNative.data = 0;
    imageNative.objectPtr = 0;
    rtabmap::DBDriverSqlite3 driver;
    if(driver.openConnection(databasePath))
    {
        cv::Mat image = driver.loadPreviewImage();
        if(image.empty())
        {
            return imageNative;
        }
        cv::Mat * imagePtr = new cv::Mat();
        // We should add alpha channel
        cv::cvtColor(image, *imagePtr, cv::COLOR_BGR2BGRA);
        std::vector<cv::Mat> channels;
        cv::split(*imagePtr, channels);
        channels.back() = cv::Scalar(255);
        cv::merge(channels, *imagePtr);
        imageNative.objectPtr = imagePtr;
        imageNative.data = imagePtr->data;
        imageNative.width = imagePtr->cols;
        imageNative.height = imagePtr->rows;
        imageNative.channels = imagePtr->channels();
    }
    return imageNative;
}

void releasePreviewImageNative(ImageNative image)
{
    if(image.objectPtr)
    {
        delete (cv::Mat*)image.objectPtr;
    }
}

static int queryLastNodeId(sqlite3 * db)
{
    int lastId = 0;
    sqlite3_stmt * stmt = 0;
    int rc = sqlite3_prepare_v2(db, "SELECT MAX(id) FROM Node;", -1, &stmt, 0);
    if(rc == SQLITE_OK)
    {
        rc = sqlite3_step(stmt);
        if(rc == SQLITE_ROW && sqlite3_column_type(stmt, 0) != SQLITE_NULL)
        {
            lastId = sqlite3_column_int(stmt, 0);
        }
        else if(rc != SQLITE_DONE && rc != SQLITE_ROW)
        {
            UERROR("lastNodeIdFromDatabaseNative: query failed (%s)", sqlite3_errmsg(db));
        }
    }
    else
    {
        UERROR("lastNodeIdFromDatabaseNative: prepare failed (%s)", sqlite3_errmsg(db));
    }
    if(stmt)
    {
        sqlite3_finalize(stmt);
    }
    return lastId;
}

static bool copyFileBinary(const std::string & from, const std::string & to)
{
    std::ifstream src(from.c_str(), std::ios::binary);
    if(!src)
    {
        return false;
    }
    std::ofstream dst(to.c_str(), std::ios::binary | std::ios::trunc);
    if(!dst)
    {
        return false;
    }
    dst << src.rdbuf();
    dst.flush();
    return !src.bad() && dst.good();
}

static void eraseDbSidecars(const std::string & path)
{
    UFile::erase(path);
    UFile::erase(path + "-wal");
    UFile::erase(path + "-shm");
}

// File-copy the db and WAL/SHM sidecars. Never sqlite3_open the live mapping file
// while Rtabmap is writing (that races and can FATAL with disk I/O error).
static bool snapshotDbFiles(const std::string & srcPath, const std::string & dstPath)
{
    if(srcPath.empty() || dstPath.empty() || !UFile::exists(srcPath))
    {
        return false;
    }
    eraseDbSidecars(dstPath);
    if(!copyFileBinary(srcPath, dstPath))
    {
        UERROR("snapshotDbFiles: copy failed %s -> %s", srcPath.c_str(), dstPath.c_str());
        eraseDbSidecars(dstPath);
        return false;
    }
    const std::string srcWal = srcPath + "-wal";
    if(UFile::exists(srcWal) && !copyFileBinary(srcWal, dstPath + "-wal"))
    {
        UERROR("snapshotDbFiles: wal copy failed %s", srcWal.c_str());
        eraseDbSidecars(dstPath);
        return false;
    }
    const std::string srcShm = srcPath + "-shm";
    if(UFile::exists(srcShm))
    {
        copyFileBinary(srcShm, dstPath + "-shm");
    }
    return true;
}

static std::string makeSnapshotPath(const char * srcPath)
{
    static int seq = 0;
    ++seq;
    std::ostringstream oss;
    oss << srcPath << ".collab-snap." << static_cast<long>(getpid()) << "." << seq;
    return oss.str();
}

int lastNodeIdFromDatabaseNative(const char * databasePath)
{
    if(!databasePath || databasePath[0] == '\0')
    {
        return 0;
    }

    const std::string snapshotPath = makeSnapshotPath(databasePath);
    if(!snapshotDbFiles(databasePath, snapshotPath))
    {
        UERROR("lastNodeIdFromDatabaseNative: snapshot failed, not opening live db %s", databasePath);
        return 0;
    }

    sqlite3 * db = 0;
    int rc = sqlite3_open_v2(snapshotPath.c_str(), &db, SQLITE_OPEN_READONLY, 0);
    if(rc != SQLITE_OK)
    {
        UERROR("lastNodeIdFromDatabaseNative: failed to open snapshot %s (%s)", snapshotPath.c_str(), db ? sqlite3_errmsg(db) : "");
        if(db)
        {
            sqlite3_close(db);
        }
        eraseDbSidecars(snapshotPath);
        return 0;
    }
    sqlite3_busy_timeout(db, 2000);
    int lastId = queryLastNodeId(db);
    sqlite3_close(db);
    eraseDbSidecars(snapshotPath);
    UINFO("lastNodeIdFromDatabaseNative: %s lastId=%d (via snapshot)", databasePath, lastId);
    return lastId;
}

int exportDeltaDbNative(const char * srcDbPath, const char * dstDbPath, int sinceId)
{
    if(!srcDbPath || !dstDbPath || srcDbPath[0] == '\0' || dstDbPath[0] == '\0')
    {
        return 0;
    }

    const std::string snapshotPath = makeSnapshotPath(srcDbPath);
    if(!snapshotDbFiles(srcDbPath, snapshotPath))
    {
        UERROR("exportDeltaDbNative: snapshot failed, not opening live db %s", srcDbPath);
        return 0;
    }

    rtabmap::DBDriverSqlite3 src;
    if(!src.openConnection(snapshotPath, false, true))
    {
        UERROR("exportDeltaDbNative: failed to open snapshot %s", snapshotPath.c_str());
        eraseDbSidecars(snapshotPath);
        return 0;
    }

    std::set<int> allIds;
    src.getAllNodeIds(allIds);

    std::list<int> ids;
    for(std::set<int>::const_iterator it = allIds.begin(); it != allIds.end(); ++it)
    {
        if(*it > sinceId)
        {
            ids.push_back(*it);
        }
    }

    if(ids.empty())
    {
        UERROR("exportDeltaDbNative: no nodes with id > %d (total=%d) in snapshot of %s", sinceId, (int)allIds.size(), srcDbPath);
        src.closeConnection(false);
        eraseDbSidecars(snapshotPath);
        return 0;
    }

    std::list<rtabmap::Signature *> signatures;
    src.loadSignatures(ids, signatures);
    if(!signatures.empty())
    {
        src.loadNodeData(signatures);
    }
    src.closeConnection(false);
    eraseDbSidecars(snapshotPath);

    if(signatures.empty())
    {
        UERROR("exportDeltaDbNative: loadSignatures returned empty for %d ids", (int)ids.size());
        return 0;
    }

    rtabmap::DBDriverSqlite3 dst;
    if(!dst.openConnection(dstDbPath, true))
    {
        UERROR("exportDeltaDbNative: failed to open dest %s", dstDbPath);
        for(std::list<rtabmap::Signature *>::iterator it = signatures.begin(); it != signatures.end(); ++it)
        {
            delete *it;
        }
        return 0;
    }

    int count = 0;
    for(std::list<rtabmap::Signature *>::iterator it = signatures.begin(); it != signatures.end(); ++it)
    {
        // Dest is a new file; loaded signatures are marked saved from the source DB.
        (*it)->setSaved(false);
        // Neighbor/intra links are already on the signature from loadSignatures.
        dst.asyncSave(*it);
        ++count;
    }
    dst.emptyTrashes(false);
    dst.closeConnection(true);
    UINFO("exportDeltaDbNative: exported %d nodes since %d", count, sinceId);
    return count;
}

int importRemoteDeltaDbNative(const void *object, const char * path, const float * clientToGlobal7, int aligned)
{
    if(!object)
    {
        UERROR("importRemoteDeltaDbNative: object is null");
        return 0;
    }
    if(!path || path[0] == '\0')
    {
        return 0;
    }
    rtabmap::Transform T = rtabmap::Transform::getIdentity();
    if(clientToGlobal7)
    {
        T = rtabmap::Transform(
            clientToGlobal7[0], clientToGlobal7[1], clientToGlobal7[2],
            clientToGlobal7[3], clientToGlobal7[4], clientToGlobal7[5], clientToGlobal7[6]);
    }
    return native(object)->importRemoteDeltaDb(path, T, aligned != 0);
}

void clearRemoteMapNative(const void *object)
{
    if(object)
    {
        native(object)->clearRemoteMap();
    }
    else
    {
        UERROR("object is null!");
    }
}


// Parameters
void setOnlineBlendingNative(const void *object, bool enabled)
{
    if(object)
        native(object)->setOnlineBlending(enabled);
    else
        UERROR("object is null!");
}
void setMapCloudShownNative(const void *object, bool shown)
{
    if(object)
        native(object)->setMapCloudShown(shown);
    else
        UERROR("object is null!");
}
void setOdomCloudShownNative(const void *object, bool shown)
{
    if(object)
        native(object)->setOdomCloudShown(shown);
    else
        UERROR("object is null!");
}
void setMeshRenderingNative(const void *object, bool enabled, bool withTexture)
{
    if(object)
        native(object)->setMeshRendering(enabled, withTexture);
    else
        UERROR("object is null!");
}
void setPointSizeNative(const void *object, float value)
{
    if(object)
        native(object)->setPointSize(value);
    else
        UERROR("object is null!");
}
void setFOVNative(const void *object, float angle)
{
    if(object)
        native(object)->setFOV(angle);
    else
        UERROR("object is null!");
}
void setOrthoCropFactorNative(const void *object, float value)
{
    if(object)
        native(object)->setOrthoCropFactor(value);
    else
        UERROR("object is null!");
}
void setGridRotationNative(const void *object, float value)
{
    if(object)
        native(object)->setGridRotation(value);
    else
        UERROR("object is null!");
}
void setLightingNative(const void *object, bool enabled)
{
    if(object)
        native(object)->setLighting(enabled);
    else
        UERROR("object is null!");
}
void setBackfaceCullingNative(const void *object, bool enabled)
{
    if(object)
        native(object)->setBackfaceCulling(enabled);
    else
        UERROR("object is null!");
}
void setWireframeNative(const void *object, bool enabled)
{
    if(object)
        native(object)->setWireframe(enabled);
    else
        UERROR("object is null!");
}
void setTextureColorSeamsHiddenNative(const void *object, bool hidden)
{
    if(object)
        native(object)->setTextureColorSeamsHidden(hidden);
    else
        UERROR("object is null!");
}
void setLocalizationModeNative(const void *object, bool enabled)
{
    if(object)
        native(object)->setLocalizationMode(enabled);
    else
        UERROR("object is null!");
}
void setDataRecorderModeNative(const void *object, bool enabled)
{
    if(object)
        native(object)->setDataRecorderMode(enabled);
    else
        UERROR("object is null!");
}
void setTrajectoryModeNative(const void *object, bool enabled)
{
    if(object)
        native(object)->setTrajectoryMode(enabled);
    else
        UERROR("object is null!");
}
void setGraphOptimizationNative(const void *object, bool enabled)
{
    if(object)
        native(object)->setGraphOptimization(enabled);
    else
        UERROR("object is null!");
}
void setNodesFilteringNative(const void *object, bool enabled)
{
    if(object)
        native(object)->setNodesFiltering(enabled);
    else
        UERROR("object is null!");
}
void setGraphVisibleNative(const void *object, bool visible)
{
    if(object)
        native(object)->setGraphVisible(visible);
    else
        UERROR("object is null!");
}
void setGridVisibleNative(const void *object, bool visible)
{
    if(object)
        native(object)->setGridVisible(visible);
    else
        UERROR("object is null!");
}
void setFullResolutionNative(const void *object, bool enabled)
{
    if(object)
        native(object)->setFullResolution(enabled);
    else
        UERROR("object is null!");
}
void setSmoothingNative(const void *object, bool enabled)
{
    if(object)
        native(object)->setSmoothing(enabled);
    else
        UERROR("object is null!");
}
void setDepthBleedingErrorNative(const void *object, float value)
{
    if(object)
        native(object)->setDepthBleedingError(value);
    else
        UERROR("object is null!");
}
void setAppendModeNative(const void *object, bool enabled)
{
    if(object)
        native(object)->setAppendMode(enabled);
    else
        UERROR("object is null!");
}
void setUpstreamRelocalizationAccThrNative(const void * object, float value)
{
    if(object)
        native(object)->setUpstreamRelocalizationAccThr(value);
    else
        UERROR("object is null!");
}
void setMaxCloudDepthNative(const void *object, float value)
{
    if(object)
        native(object)->setMaxCloudDepth(value);
    else
        UERROR("object is null!");
}
void setMinCloudDepthNative(const void *object, float value)
{
    if(object)
        native(object)->setMinCloudDepth(value);
    else
        UERROR("object is null!");
}
void setCloudDensityLevelNative(const void *object, int value)
{
    if(object)
        native(object)->setCloudDensityLevel(value);
    else
        UERROR("object is null!");
}
void setMeshAngleToleranceNative(const void *object, float value)
{
    if(object)
        native(object)->setMeshAngleTolerance(value);
    else
        UERROR("object is null!");
}
void setMeshDecimationFactorNative(const void *object, float value)
{
    if(object)
        native(object)->setMeshDecimationFactor(value);
    else
        UERROR("object is null!");
}
void setMeshTriangleSizeNative(const void *object, int value)
{
    if(object)
        native(object)->setMeshTriangleSize(value);
    else
        UERROR("object is null!");
}
void setClusterRatioNative(const void *object, float value)
{
    if(object)
        native(object)->setClusterRatio(value);
    else
        UERROR("object is null!");
}
void setMaxGainRadiusNative(const void *object, float value)
{
    if(object)
        native(object)->setMaxGainRadius(value);
    else
        UERROR("object is null!");
}
void setRenderingTextureDecimationNative(const void *object, int value)
{
    if(object)
        native(object)->setRenderingTextureDecimation(value);
    else
        UERROR("object is null!");
}
void setBackgroundColorNative(const void *object, float gray)
{
    if(object)
        native(object)->setBackgroundColor(gray);
    else
        UERROR("object is null!");
}
void setDepthConfidenceNative(const void *object, int value)
{
    if(object)
        native(object)->setDepthConfidence(value);
    else
        UERROR("object is null!");
}

void setExportPointCloudFormatNative(const void *object, const char * format)
{
    if(object)
        native(object)->setExportPointCloudFormat(format);
    else
        UERROR("object is null!");
}

int setMappingParameterNative(const void *object, const char * key, const char * value)
{
    if(object)
        return native(object)->setMappingParameter(key, value);
    else
        UERROR("object is null!");
    return -1;
}

void setGPSNative(const void *object, double stamp, double longitude, double latitude, double altitude, double accuracy, double bearing)
{
    rtabmap::GPS gps(stamp, longitude, latitude, altitude, accuracy, bearing);
    if(object)
        return native(object)->setGPS(gps);
    else
        UERROR("object is null!");
}

void addEnvSensorNative(const void *object, int type, float value)
{
    if(object)
        return native(object)->addEnvSensor(type, value);
    else
        UERROR("object is null!");
}

void removeMeasureNative(const void *object)
{
    if(object)
        return native(object)->removeMeasure();
    else
        UERROR("object is null!");
}
void addMeasureNative(const void *object)
{
    if(object)
        return native(object)->addMeasureButtonClicked();
    else
        UERROR("object is null!");
}
void teleportNative(const void *object)
{
    if(object)
        return native(object)->teleportButtonClicked();
    else
        UERROR("object is null!");
}
void setMeasuringModeNative(const void *object, int mode)
{
    if(object)
        return native(object)->setMeasuringMode(mode);
    else
        UERROR("object is null!");
}
void setMetricSystemNative(const void *object, bool enabled)
{
    if(object)
        return native(object)->setMetricSystem(enabled);
    else
        UERROR("object is null!");
}
void setMeasuringTextSizeNative(const void *object, float size)
{
    if(object)
        return native(object)->setMeasuringTextSize(size);
    else
        UERROR("object is null!");
}
void clearMeasuresNative(const void *object)
{
    if(object)
        return native(object)->clearMeasures();
    else
        UERROR("object is null!");
}

StartTagDetect detectStartTagNative(
    const void * yPlane,
    int width,
    int height,
    int bytesPerRow,
    float fx,
    float fy,
    float cx,
    float cy,
    float markerLength)
{
    StartTagDetect out;
    std::memset(&out, 0, sizeof(out));
    out.qw = 1.0f;
    out.seen_id = -1;
    out.error = 2;
    if(!yPlane || width < 16 || height < 16 || bytesPerRow < width)
    {
        out.error = 1;
        return out;
    }
    cv::Mat grayFull(height, width, CV_8UC1);
    const unsigned char * src = static_cast<const unsigned char *>(yPlane);
    for(int y = 0; y < height; ++y)
    {
        std::memcpy(grayFull.ptr(y), src + y * bytesPerRow, static_cast<size_t>(width));
    }

    float sfx = fx;
    float sfy = fy;
    float scx = cx;
    float scy = cy;
    cv::Mat gray = grayFull;
    const int maxWidth = 960;
    if(gray.cols > maxWidth)
    {
        const double scale = double(maxWidth) / double(gray.cols);
        cv::Mat small;
        cv::resize(gray, small, cv::Size(), scale, scale, cv::INTER_AREA);
        gray = small;
        sfx *= float(scale);
        sfy *= float(scale);
        scx *= float(scale);
        scy *= float(scale);
    }

    static rtabmap::MarkerDetector * detector = 0;
    static float lastLength = -1.0f;
    const float length = markerLength > 0.01f ? markerLength : 0.20f;
    if(!detector || std::fabs(lastLength - length) > 1e-4f)
    {
        delete detector;
        rtabmap::ParametersMap params;
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kMarkerDictionary(), "0"));
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kMarkerLength(), uNumber2Str(length)));
        params.insert(rtabmap::ParametersPair(rtabmap::Parameters::kMarkerStrategy(), "0"));
        detector = new rtabmap::MarkerDetector(params);
        lastLength = length;
    }

    // imageWidth must match the gray image or MarkerDetector::detect returns empty
    // (it treats size mismatch as multi-camera and bails).
    rtabmap::CameraModel model(
        sfx, sfy, scx, scy,
        rtabmap::CameraModel::opticalRotation(),
        0.0,
        cv::Size(gray.cols, gray.rows));

    auto firstId = [](const std::map<int, rtabmap::MarkerInfo> & found) -> int {
        if(found.empty())
        {
            return -1;
        }
        return found.begin()->first;
    };

    // Raw first. Always-on CLAHE washed out the high-contrast screen marker.
    std::map<int, rtabmap::MarkerInfo> found = detector->detect(gray, model);
    out.seen_id = firstId(found);
    if(found.find(0) == found.end())
    {
        cv::Mat blurred;
        cv::GaussianBlur(gray, blurred, cv::Size(3, 3), 0);
        found = detector->detect(blurred, model);
        if(out.seen_id < 0)
        {
            out.seen_id = firstId(found);
        }
    }
    if(found.find(0) == found.end())
    {
        cv::Ptr<cv::CLAHE> clahe = cv::createCLAHE(3.0, cv::Size(8, 8));
        cv::Mat enhanced;
        clahe->apply(gray, enhanced);
        found = detector->detect(enhanced, model);
        if(out.seen_id < 0)
        {
            out.seen_id = firstId(found);
        }
        if(found.find(0) == found.end())
        {
            cv::Mat inverted;
            cv::bitwise_not(gray, inverted);
            found = detector->detect(inverted, model);
            if(out.seen_id < 0)
            {
                out.seen_id = firstId(found);
            }
        }
    }
    std::map<int, rtabmap::MarkerInfo>::const_iterator it = found.find(0);
    if(it == found.end())
    {
        UINFO("detectStartTagNative: no id=0 in %dx%d seen=%d", gray.cols, gray.rows, out.seen_id);
        out.error = 2;
        return out;
    }
    UINFO("detectStartTagNative: found id=0");
    const rtabmap::Transform & pose = it->second.pose();
    if(pose.isNull())
    {
        out.error = 3;
        return out;
    }
    out.error = 0;
    Eigen::Quaternionf q = pose.getQuaternionf();
    out.found = 1;
    out.tag_id = it->first;
    out.tx = pose.x();
    out.ty = pose.y();
    out.tz = pose.z();
    out.qx = q.x();
    out.qy = q.y();
    out.qz = q.z();
    out.qw = q.w();
    return out;
}
