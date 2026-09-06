# Collaborative mapping HTTP server (headless).

IF(NOT TARGET rtabmap::core)
	FIND_PACKAGE(RTABMap REQUIRED)
ENDIF(NOT TARGET rtabmap::core)

# OpenCV and PCL are already found by the root CMakeLists when this
# directory is added as a subdirectory. Standalone builds against an
# installed RTAB-Map still need them for pcl::io and OpenCV headers.
IF(NOT OpenCV_FOUND)
	FIND_PACKAGE(OpenCV REQUIRED QUIET COMPONENTS core)
	IF(OpenCV_VERSION_MAJOR GREATER 4)
		FIND_PACKAGE(OpenCV REQUIRED QUIET COMPONENTS core imgproc highgui)
	ELSE()
		FIND_PACKAGE(OpenCV REQUIRED QUIET COMPONENTS core imgproc highgui)
	ENDIF()
ENDIF(NOT OpenCV_FOUND)

IF(NOT PCL_FOUND)
	FIND_PACKAGE(PCL 1.7 REQUIRED QUIET COMPONENTS common io kdtree search surface filters registration sample_consensus segmentation)
ENDIF(NOT PCL_FOUND)

IF(PCL_DEFINITIONS)
	ADD_DEFINITIONS(${PCL_DEFINITIONS})
ENDIF(PCL_DEFINITIONS)

SET(SRC_FILES
	main.cpp
	HttpServer.cpp
	CollabMap.cpp
	DemoTag.cpp
)

ADD_EXECUTABLE(rtabmap-collab-server ${SRC_FILES})

TARGET_LINK_LIBRARIES(rtabmap-collab-server rtabmap::core)
IF(APPLE)
	TARGET_LINK_LIBRARIES(rtabmap-collab-server "-framework CoreFoundation")
ENDIF(APPLE)

IF(PCL_INCLUDE_DIRS)
	TARGET_INCLUDE_DIRECTORIES(rtabmap-collab-server SYSTEM PRIVATE ${PCL_INCLUDE_DIRS})
ENDIF(PCL_INCLUDE_DIRS)

IF(OpenCV_INCLUDE_DIRS)
	TARGET_INCLUDE_DIRECTORIES(rtabmap-collab-server SYSTEM PRIVATE ${OpenCV_INCLUDE_DIRS})
ENDIF(OpenCV_INCLUDE_DIRS)

SET_TARGET_PROPERTIES(rtabmap-collab-server PROPERTIES
	OUTPUT_NAME "rtabmap-collab-server")

INSTALL(TARGETS rtabmap-collab-server
	RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}" COMPONENT runtime)

# Standalone merge harness (not ctest). Replays client deltas into a temp room.
SET(TEST_SRC_FILES
	collab_merge_test.cpp
	CollabMap.cpp
	HttpServer.cpp
)
ADD_EXECUTABLE(rtabmap-collab-merge-test ${TEST_SRC_FILES})
TARGET_LINK_LIBRARIES(rtabmap-collab-merge-test rtabmap::core)
IF(PCL_INCLUDE_DIRS)
	TARGET_INCLUDE_DIRECTORIES(rtabmap-collab-merge-test SYSTEM PRIVATE ${PCL_INCLUDE_DIRS})
ENDIF(PCL_INCLUDE_DIRS)
IF(OpenCV_INCLUDE_DIRS)
	TARGET_INCLUDE_DIRECTORIES(rtabmap-collab-merge-test SYSTEM PRIVATE ${OpenCV_INCLUDE_DIRS})
ENDIF(OpenCV_INCLUDE_DIRS)
SET_TARGET_PROPERTIES(rtabmap-collab-merge-test PROPERTIES
	OUTPUT_NAME "rtabmap-collab-merge-test")

# Frame-consistency test for the start-tag lock (fast, no database).
ADD_EXECUTABLE(rtabmap-collab-frame-test collab_frame_test.cpp CollabMap.cpp HttpServer.cpp)
TARGET_LINK_LIBRARIES(rtabmap-collab-frame-test rtabmap::core)
IF(PCL_INCLUDE_DIRS)
	TARGET_INCLUDE_DIRECTORIES(rtabmap-collab-frame-test SYSTEM PRIVATE ${PCL_INCLUDE_DIRS})
ENDIF(PCL_INCLUDE_DIRS)
IF(OpenCV_INCLUDE_DIRS)
	TARGET_INCLUDE_DIRECTORIES(rtabmap-collab-frame-test SYSTEM PRIVATE ${OpenCV_INCLUDE_DIRS})
ENDIF(OpenCV_INCLUDE_DIRS)
SET_TARGET_PROPERTIES(rtabmap-collab-frame-test PROPERTIES
	OUTPUT_NAME "rtabmap-collab-frame-test")
