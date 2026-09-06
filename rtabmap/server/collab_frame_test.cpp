// Frame-consistency test for the start-tag lock.
//
// Simulates two phones whose ARKit worlds differ by an arbitrary yaw and
// translation, both seeing the same physical tag. Replicates what each side
// does: rtabmap's MarkerDetector returns the tag in the camera base_link
// frame, TagCalibrator composes ARKit camera * T_arkitCam_from_base * that,
// the server converts to T_G_from_clientWorld, and node poses (stored in the
// phone's rtabmap world) are aligned with it. Both phones must land the same
// physical camera pose on the same G pose, and G must be z-up with the tag at
// the origin. This is the algebra that was wrong before; it does not replace
// a live two-phone check.

#include <rtabmap/core/Transform.h>
#include <rtabmap/utilite/ULogger.h>

#include <cmath>
#include <cstdio>
#include <iostream>
#include <string>

#include "CollabMap.h"

namespace {

int gPass = 0;
int gFail = 0;

void check(bool cond, const std::string & name, const std::string & detail = "")
{
	if(cond)
	{
		++gPass;
		std::cout << "PASS  " << name;
	}
	else
	{
		++gFail;
		std::cout << "FAIL  " << name;
	}
	if(!detail.empty())
	{
		std::cout << "  (" << detail << ")";
	}
	std::cout << "\n";
}

bool close(const rtabmap::Transform & a, const rtabmap::Transform & b, float tol = 1e-3f)
{
	if(a.isNull() || b.isNull())
	{
		return false;
	}
	rtabmap::Transform d = a.inverse() * b;
	float roll, pitch, yaw;
	d.getEulerAngles(roll, pitch, yaw);
	return d.getNorm() < tol && std::fabs(roll) < tol && std::fabs(pitch) < tol && std::fabs(yaw) < tol;
}

// The iOS TagCalibrator composition, in rtabmap::Transform terms.
// T_arkitCam_from_base is opengl_world_T_rtabmap_world used as a camera-axes rotation.
rtabmap::Transform phoneComposeArkitWorldFromTag(
	const rtabmap::Transform & arkitCamera,
	const rtabmap::Transform & baseFromTag)
{
	return arkitCamera * collab::CollabMap::openGLWorldFromRtabmap() * baseFromTag;
}

// Physical world P (rtabmap convention, z up). A phone's ARKit world differs
// from P by yaw about gravity plus a translation, and by the axis convention.
struct Phone
{
	rtabmap::Transform P_from_Wr; // yaw + translation between this phone's rtabmap world and P
	// ARKit camera transform for a physical camera pose C_P (rtabmap base_link in P):
	//   C_P = P_from_Wr * conv(P_a), conv(P_a) = R_ro * P_a * R_or
	//   => P_a = R_or * P_from_Wr^-1 * C_P * R_ro
	rtabmap::Transform arkitCameraFor(const rtabmap::Transform & C_P) const
	{
		return collab::CollabMap::openGLWorldFromRtabmap() * P_from_Wr.inverse() * C_P *
			collab::CollabMap::rtabmapWorldFromOpenGL();
	}
	// What the phone stores in its db for that frame (rtabmap odom pose).
	rtabmap::Transform storedNodePose(const rtabmap::Transform & C_P) const
	{
		return P_from_Wr.inverse() * C_P;
	}
};

}

int main(int, char **)
{
	ULogger::setLevel(ULogger::kWarning);
	const rtabmap::Transform R_ro = collab::CollabMap::rtabmapWorldFromOpenGL();
	const rtabmap::Transform R_or = collab::CollabMap::openGLWorldFromRtabmap();

	check(close(R_ro * R_or, rtabmap::Transform::getIdentity()), "axis rotations are inverses");
	// rtabmap x (forward) is OpenGL -z; rtabmap z (up) is OpenGL +y.
	{
		float x, y, z;
		rtabmap::Transform t = R_or * rtabmap::Transform(1, 0, 0, 0, 0, 0);
		x = t.x(); y = t.y(); z = t.z();
		check(std::fabs(x) < 1e-6 && std::fabs(y) < 1e-6 && std::fabs(z + 1) < 1e-6,
			"rtabmap +x maps to OpenGL -z", "got " + t.prettyPrint());
		t = R_or * rtabmap::Transform(0, 0, 1, 0, 0, 0);
		check(std::fabs(t.x()) < 1e-6 && std::fabs(t.y() - 1) < 1e-6 && std::fabs(t.z()) < 1e-6,
			"rtabmap +z maps to OpenGL +y", "got " + t.prettyPrint());
	}

	// Physical tag: on a vertical screen 1.2 m above the floor. Tag frame is
	// OpenGL-like (x right along the screen, y up, z out toward the viewer).
	// Express it in P: tag z (toward viewer) points along P -x, tag y is P +z.
	// So T_P_from_tag has columns tag.x -> P -y, tag.y -> P +z, tag.z -> P -x:
	// that is exactly R_ro. Add a yaw so the screen is not axis aligned.
	const rtabmap::Transform screenYaw(0, 0, 0, 0, 0, 0.35f);
	const rtabmap::Transform T_P_from_tag = screenYaw * rtabmap::Transform(0.8f, -0.3f, 1.2f, 0, 0, 0) * R_ro;
	// Shared frame G is the tag frame re-expressed in rtabmap convention:
	// T_P_from_G = T_P_from_tag * R_or (so G = R_ro * tag).
	const rtabmap::Transform T_P_from_G = T_P_from_tag * R_or;
	{
		// G must be z-up: G's z axis (third column) in P must be P +z.
		rtabmap::Transform gz = T_P_from_G * rtabmap::Transform(0, 0, 1, 0, 0, 0);
		rtabmap::Transform g0 = T_P_from_G;
		float dz = gz.z() - g0.z();
		float dxy = std::hypot(gz.x() - g0.x(), gz.y() - g0.y());
		check(std::fabs(dz - 1.0f) < 1e-4f && dxy < 1e-4f, "G is z-up when the tag hangs vertically",
			"dz=" + std::to_string(dz) + " dxy=" + std::to_string(dxy));
	}

	Phone phones[2];
	phones[0].P_from_Wr = rtabmap::Transform(2.0f, 1.0f, 0.0f, 0, 0, 0.9f);   // started elsewhere, yawed 0.9 rad
	phones[1].P_from_Wr = rtabmap::Transform(-1.5f, 3.0f, 0.0f, 0, 0, -2.2f); // different origin and yaw

	// Two calibration camera poses in P (rtabmap base_link: x forward, z up),
	// each phone standing in front of the screen at different spots.
	// Viewers stand on the -x side of the screen (the side its normal faces)
	// and look toward +x, roughly at the tag.
	const rtabmap::Transform calibCam[2] = {
		screenYaw * rtabmap::Transform(0.8f - 1.1f, -0.3f + 0.2f, 1.35f, 0.0f, 0.15f, 0.1f),
		screenYaw * rtabmap::Transform(0.8f - 0.9f, -0.3f - 0.4f, 1.25f, 0.05f, 0.1f, -0.25f)
	};

	rtabmap::Transform G_from_Wr[2];
	for(int k = 0; k < 2; ++k)
	{
		const rtabmap::Transform C_P = calibCam[k];
		// MarkerDetector output: tag in camera base_link.
		const rtabmap::Transform baseFromTag = C_P.inverse() * T_P_from_tag;
		check(baseFromTag.x() > 0.5f, std::string("phone ") + char('A' + k) + " sees the tag in front of it",
			"forward distance " + std::to_string(baseFromTag.x()));
		const rtabmap::Transform arkitCam = phones[k].arkitCameraFor(C_P);
		const rtabmap::Transform arkitWorldFromTag = phoneComposeArkitWorldFromTag(arkitCam, baseFromTag);
		G_from_Wr[k] = collab::CollabMap::globalFromClientWorld(arkitWorldFromTag);
		check(!G_from_Wr[k].isNull(), std::string("phone ") + char('A' + k) + " alignment is valid");
		// Ground truth: T_G_from_Wr = T_G_from_P * T_P_from_Wr.
		const rtabmap::Transform expected = T_P_from_G.inverse() * phones[k].P_from_Wr;
		check(close(G_from_Wr[k], expected), std::string("phone ") + char('A' + k) + " server alignment equals ground truth",
			"got " + G_from_Wr[k].prettyPrint() + " expected " + expected.prettyPrint());
	}

	// The same physical camera pose seen by both phones must land on the same G pose.
	const rtabmap::Transform sharedSpot = rtabmap::Transform(3.2f, -1.7f, 1.4f, 0.02f, -0.1f, 2.4f);
	rtabmap::Transform inG[2];
	for(int k = 0; k < 2; ++k)
	{
		inG[k] = G_from_Wr[k] * phones[k].storedNodePose(sharedSpot);
	}
	check(close(inG[0], inG[1], 1e-3f), "both phones map one physical spot to one G pose",
		"A " + inG[0].prettyPrint() + " B " + inG[1].prettyPrint());
	check(close(inG[0], T_P_from_G.inverse() * sharedSpot), "aligned pose equals ground truth in G");

	// The tag itself must sit at the origin of G, and a point 1 m in front of
	// the screen (toward the viewers, P -x side of the screen normal) must have
	// negative G x, with the same height as the tag (G z ~ 0).
	{
		const rtabmap::Transform tagInG = T_P_from_G.inverse() * T_P_from_tag;
		check(tagInG.getNorm() < 1e-4f, "tag center is the G origin", tagInG.prettyPrint());
		const rtabmap::Transform viewer = T_P_from_tag * rtabmap::Transform(0, 0, 1.0f, 0, 0, 0); // 1 m along tag z (toward viewer)
		const rtabmap::Transform viewerG = T_P_from_G.inverse() * viewer;
		check(viewerG.x() < -0.99f && std::fabs(viewerG.z()) < 1e-3f, "viewer side of the screen is G -x at tag height",
			viewerG.prettyPrint());
	}

	// Live pose path: POST /pose carries the raw ARKit camera transform; the
	// server converts it to the phone's rtabmap world before aligning.
	{
		const rtabmap::Transform C_P = rtabmap::Transform(2.5f, 0.4f, 1.3f, 0.0f, 0.2f, 1.1f);
		for(int k = 0; k < 2; ++k)
		{
			const rtabmap::Transform arkitCam = phones[k].arkitCameraFor(C_P);
			const rtabmap::Transform odomR = collab::CollabMap::rtabmapPoseFromArkit(arkitCam);
			check(close(odomR, phones[k].storedNodePose(C_P)), std::string("phone ") + char('A' + k) + " live pose converts like a stored node",
				odomR.prettyPrint());
			const rtabmap::Transform live = G_from_Wr[k] * odomR;
			check(close(live, T_P_from_G.inverse() * C_P), std::string("phone ") + char('A' + k) + " live pose lands at ground truth in G");
		}
	}

	// GET /pull sends inverse(T_G_from_Wr) so the receiving phone can place a
	// G-frame node into its own rtabmap world: localFromGlobal * poseG == its own frame.
	{
		const rtabmap::Transform poseG = inG[0];
		for(int k = 0; k < 2; ++k)
		{
			const rtabmap::Transform local = G_from_Wr[k].inverse() * poseG;
			check(close(local, phones[k].storedNodePose(sharedSpot)), std::string("phone ") + char('A' + k) + " pull transform places remote node in its own frame");
		}
	}

	std::cout << "\nRESULT  pass=" << gPass << " fail=" << gFail << "\n";
	return gFail == 0 ? 0 : 1;
}
