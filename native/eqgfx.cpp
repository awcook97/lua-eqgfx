/*
 * eqgfx.dll - lets Lua draw the EverQuest world with the engine's own renderer.
 *
 * WHY THIS EXISTS
 * ---------------
 * On Linux/Wine we cannot rebuild MQ2Lua, and we cannot ship a C *Lua* module
 * (it would statically link a second LuaJIT and blow up coroutines). So Lua
 * talks to us over a plain extern "C" ABI via LuaJIT FFI instead.
 *
 * HOW WE RENDER (DX11 client)
 * ---------------------------
 * This is the DirectX 11 client, so the engine's legacy DX9 3D path
 * (DrawLine3D) fires but never composites - it's not wired to the live scene.
 * The legacy 2D overlay path (DrawLine2D) DOES still composite. So we:
 *   1. read the live view-projection matrix (CRender::matrixViewProj) and
 *      project world points -> screen on the CPU ourselves,
 *   2. draw the resulting 2D screen-space line segments with DrawLine2D.
 * We issue draws from MacroQuest's own GraphicsSceneRender callback
 * (mq::AddRenderCallbacks), the sanctioned hook, in native C++ so we never
 * re-enter LuaJIT from the render thread.
 *
 * PATCH RESILIENCE
 * ----------------
 * Bakes in ZERO game *addresses*: the live render interface + spell manager
 * come from Lua (read from eqlib.dll exports), AddRenderCallbacks is resolved
 * from MQ2Main.dll at runtime. Hard-coded only: engine *layout* (vtable order +
 * struct field offsets), stable across monthly patches. Layout refs:
 *   src/eqlib/include/eqlib/graphics/RenderInterface.h  (DrawLine2D vtable idx)
 *   src/eqlib/include/eqlib/graphics/Render.h           (matrixViewProj @0x1700)
 *   src/eqlib/include/eqlib/game/Spells.h               (EQ_Spell field offsets)
 *   src/main/GraphicsEngine.h                           (MQRenderCallbacks)
 */

#include <windows.h>
#include <cstdint>
#include <cmath>
#include <vector>
#include <mutex>
#include <functional>
#include <atomic>

namespace {

constexpr float kPi = 3.14159265358979323846f;

struct CVector3 { float x, y, z; };
using RGB = uint32_t;

// CRenderInterface vtable indices (RenderInterface.h offset / 8)
enum : size_t {
	VT_GetDisplayWidth  = 6,   // 0x030 int()
	VT_GetDisplayHeight = 7,   // 0x038 int()
	VT_DrawLine2D       = 34,  // 0x110 void(const CVector3&, const CVector3&, RGB)
	VT_TransformWorldToCamera = 55, // 0x1b8 void(const CVector3& world, CVector3& camera)
	VT_GetEyeOffset     = 56,  // 0x1c0 void(CVector3& pos) - camera eye position
};
enum : size_t { VT_GetSpellByID = 8 };               // ClientSpellManager (Spells.h 0x40)

// CRender member offset (Render.h): CMatrix44 matrixViewProj, row-major CVector4 row[4]
enum : size_t { REN_matrixViewProj = 0x1700 };

// CDisplay::pCamera (Display.h 0x118) and CCameraInterface vtable index for
// ProjectWorldCoordinatesToScreen (CameraInterface.h: 30th virtual = index 29).
enum : size_t { CD_pCamera = 0x118 };
enum : size_t { VT_ProjectWorldToScreen = 29 };

// EQ_Spell field offsets (Spells.h)
enum : size_t {
	SP_Range = 0x000, SP_AERange = 0x004,
	SP_ConeStartAngle = 0x0c8, SP_ConeEndAngle = 0x0cc, SP_TargetType = 0x187,
};

using FnDrawLine2D   = void  (*)(void* thisptr, const CVector3* p1, const CVector3* p2, RGB color);
using FnGetSpellByID = void* (*)(void* thisptr, int spellID);
using FnGetInt       = int   (*)(void* thisptr);
using FnGetEyeOffset = void  (*)(void* thisptr, CVector3* pos);
using FnWorldToCamera = void (*)(void* thisptr, const CVector3* world, CVector3* camera);
using FnProjectW2S    = bool (*)(void* thisptr, const CVector3* world, float* sx, float* sy);

struct MQRenderCallbacks {
	std::function<void()> CreateDeviceObjects;
	std::function<void()> InvalidateDeviceObjects;
	std::function<void()> GraphicsSceneRender;
};
using FnAddRenderCallbacks    = int  (*)(const MQRenderCallbacks&);
using FnRemoveRenderCallbacks = void (*)(int);
constexpr const char* kSymAdd    = "AddRenderCallbacks";
constexpr const char* kSymRemove = "RemoveRenderCallbacks";

inline void* VtblEntry(void* instance, size_t index) {
	return (*reinterpret_cast<void***>(instance))[index];
}
template <typename T> inline T ReadField(void* base, size_t off) {
	return *reinterpret_cast<T*>(reinterpret_cast<uint8_t*>(base) + off);
}
inline int CallGetInt(void* inst, size_t vt) {
	return reinterpret_cast<FnGetInt>(VtblEntry(inst, vt))(inst);
}

// --- State ------------------------------------------------------------------
// screen=true: a/b are already screen-space pixels (x,y), no projection.
struct Segment { CVector3 a, b; RGB color; bool screen; };
struct Rect    { float x0, y0, x1, y1; RGB color; };   // filled 2D screen rect

std::mutex              g_mutex;
void*                   g_pRender = nullptr;
void*                   g_pSpellMgr = nullptr;
void*                   g_pDisplay = nullptr;   // CDisplay*, for the active camera
std::vector<Segment>    g_segments;
std::vector<Rect>       g_rects;
int                     g_callbackId = -1;
FnRemoveRenderCallbacks g_removeCallbacks = nullptr;
int                     g_axisMode = 6;          // 6 = (-X, Z, Y), solved from matrix dump
int                     g_thickness = 3;         // line half-width in pixels
int                     g_convention = 1;        // 0=row-vector(v*M), 1=column-vector(M*v)
int                     g_eyeRelative = 0;        // matrix is absolute world->clip; no eye subtract
int                     g_wsign = -1;            // front-facing points have negative clip.w here
int                     g_flipX = 1;             // engine cam.x is +left here; mirror to screen +right
int                     g_flipY = 1;             // screen is y-down; flip ndc.y to pixels
std::atomic<uint32_t>   g_sceneCalls{ 0 };
std::atomic<uint32_t>   g_lastDraws{ 0 };

// Map TLO (x,y,z) into the engine's render-world axis convention. Unknown until
// calibrated in-game, so selectable at runtime.
inline void ApplyAxis(float x, float y, float z, float& wx, float& wy, float& wz) {
	switch (g_axisMode) {
	default:
	case 0: wx =  x; wy =  y; wz =  z; break;
	case 1: wx =  y; wy =  x; wz =  z; break;
	case 2: wx = -y; wy =  x; wz =  z; break;
	case 3: wx =  y; wy = -x; wz =  z; break;
	case 4: wx = -x; wy =  y; wz =  z; break;
	case 5: wx =  x; wy = -y; wz =  z; break;
	case 6: wx = -x; wy =  z; wz =  y; break;   // EQ render frame (solved)
	}
}

void GetEye(CVector3& eye) {
	eye = CVector3{ 0, 0, 0 };
	reinterpret_cast<FnGetEyeOffset>(VtblEntry(g_pRender, VT_GetEyeOffset))(g_pRender, &eye);
}

// World -> screen via the engine's OWN TransformWorldToCamera (vtable 55), which
// returns clip-style coords (x, y, depth) with projection scales baked in. The
// perspective divide by depth then gives normalized device coords. This sidesteps
// all matrix-convention / axis / eye guesswork. Returns false if behind camera.
inline void WorldToCamera(float x, float y, float z, CVector3& out) {
	CVector3 w{ x, y, z };
	out = CVector3{ 0, 0, 0 };
	reinterpret_cast<FnWorldToCamera>(VtblEntry(g_pRender, VT_TransformWorldToCamera))(g_pRender, &w, &out);
}

inline void* GetCamera() {
	if (!g_pDisplay) return nullptr;
	return *reinterpret_cast<void**>(reinterpret_cast<uint8_t*>(g_pDisplay) + CD_pCamera);
}

// World -> screen via the engine's OWN CCamera::ProjectWorldCoordinatesToScreen
// (camera vtable 29). Returns final screen pixels + a visible bool; the engine
// handles projection / axes / clipping. Nothing for us to get wrong.
bool WorldToScreen(float x, float y, float z, float& sx, float& sy) {
	void* cam = GetCamera();
	if (!cam) return false;
	// Callers pass MQ/TLO order (x=X, y=Y). EQ's engine CVector3 is (Y, X, Z),
	// matching /loc YXZ - so swap the first two before projecting.
	CVector3 w{ y, x, z };
	sx = sy = 0.0f;
	return reinterpret_cast<FnProjectW2S>(VtblEntry(cam, VT_ProjectWorldToScreen))(cam, &w, &sx, &sy);
}

void DrawLine2D_raw(float x1, float y1, float x2, float y2, RGB color) {
	CVector3 a{ x1, y1, 0.0f }, b{ x2, y2, 0.0f };
	auto fn = reinterpret_cast<FnDrawLine2D>(VtblEntry(g_pRender, VT_DrawLine2D));
	fn(g_pRender, &a, &b, color);
}

// Thick screen-space line: draw parallel copies offset along the perpendicular.
void DrawThickScreenLine(float x1, float y1, float x2, float y2, RGB color) {
	float dx = x2 - x1, dy = y2 - y1;
	float len = sqrtf(dx*dx + dy*dy);
	if (len < 0.001f) { DrawLine2D_raw(x1, y1, x2, y2, color); return; }
	float px = -dy / len, py = dx / len;               // unit perpendicular
	for (int k = -g_thickness; k <= g_thickness; ++k) {
		float ox = px * k, oy = py * k;
		DrawLine2D_raw(x1 + ox, y1 + oy, x2 + ox, y2 + oy, color);
	}
}

void OnSceneRender() {
	g_sceneCalls.fetch_add(1, std::memory_order_relaxed);
	if (!g_pRender || !GetCamera()) return;          // need render iface to draw, camera to project

	std::lock_guard<std::mutex> lock(g_mutex);
	uint32_t n = 0;
	for (const Segment& s : g_segments) {
		if (s.screen) {
			DrawThickScreenLine(s.a.x, s.a.y, s.b.x, s.b.y, s.color);
			++n;
			continue;
		}
		// Each endpoint projected by the engine's own camera. Draw the segment
		// only if both ends are visible (in front of the camera).
		float ax, ay, bx, by;
		if (WorldToScreen(s.a.x, s.a.y, s.a.z, ax, ay) &&
		    WorldToScreen(s.b.x, s.b.y, s.b.z, bx, by)) {
			DrawThickScreenLine(ax, ay, bx, by, s.color);
			++n;
		}
	}
	// Filled 2D rects (health bars etc.) - solid fill via 1px horizontal scanlines.
	for (const Rect& r : g_rects) {
		float y0 = r.y0 < r.y1 ? r.y0 : r.y1;
		float y1 = r.y0 < r.y1 ? r.y1 : r.y0;
		for (float yy = y0; yy <= y1; yy += 1.0f)
			DrawLine2D_raw(r.x0, yy, r.x1, yy, r.color);
		++n;
	}
	g_lastDraws.store(n, std::memory_order_relaxed);
}

void PushSeg(float x1, float y1, float z1, float x2, float y2, float z2, RGB c) {
	g_segments.push_back(Segment{ { x1, y1, z1 }, { x2, y2, z2 }, c, false });
}

} // namespace

struct eqgfx_spell_geom {
	int targetType; float range; float aeRange; int coneStart; int coneEnd;
};

extern "C" {

__declspec(dllexport) int eqgfx_init(void* pRenderInterface, void* pSpellManager) {
	g_pRender   = pRenderInterface;
	g_pSpellMgr = pSpellManager;
	if (!g_pRender) return 1;
	if (g_callbackId >= 0) return 0;
	HMODULE hMain = GetModuleHandleA("MQ2Main.dll");
	if (!hMain) return 2;
	auto add = reinterpret_cast<FnAddRenderCallbacks>(GetProcAddress(hMain, kSymAdd));
	g_removeCallbacks = reinterpret_cast<FnRemoveRenderCallbacks>(GetProcAddress(hMain, kSymRemove));
	if (!add) return 3;
	MQRenderCallbacks cb;
	cb.GraphicsSceneRender = &OnSceneRender;
	g_callbackId = add(cb);
	return 0;
}

// Provide the live CDisplay* (its ->pCamera is the active camera we project with).
__declspec(dllexport) void eqgfx_set_display(void* pCDisplay) { g_pDisplay = pCDisplay; }

__declspec(dllexport) void eqgfx_shutdown() {
	if (g_callbackId >= 0 && g_removeCallbacks) g_removeCallbacks(g_callbackId);
	g_callbackId = -1;
	std::lock_guard<std::mutex> lock(g_mutex);
	g_segments.clear();
}

__declspec(dllexport) void eqgfx_clear() {
	std::lock_guard<std::mutex> lock(g_mutex);
	g_segments.clear();
	g_rects.clear();
}

// Select the world-coordinate convention (0..5) while calibrating in-game.
__declspec(dllexport) void eqgfx_set_axis_mode(int mode) { g_axisMode = mode; }
// 0=row-vector(v*M), 1=column-vector(M*v).
__declspec(dllexport) void eqgfx_set_convention(int c) { g_convention = c; }
// 1=subtract camera eye before transform (EQ renders eye-relative), 0=absolute.
__declspec(dllexport) void eqgfx_set_eyerel(int e) { g_eyeRelative = e; }
// Sign of clip.w for front-facing points (+1 or -1).
__declspec(dllexport) void eqgfx_set_wsign(int s) { g_wsign = s < 0 ? -1 : 1; }
// Mirror horizontal axis (engine cam.x sign vs screen +right).
__declspec(dllexport) void eqgfx_set_flipx(int f) { g_flipX = f ? 1 : 0; }
// Mirror vertical axis (engine cam.y sign vs screen +down).
__declspec(dllexport) void eqgfx_set_flipy(int f) { g_flipY = f ? 1 : 0; }
// Camera eye position (world coords) for debugging.
__declspec(dllexport) void eqgfx_get_eye(float* x, float* y, float* z) {
	CVector3 e{ 0, 0, 0 };
	if (g_pRender) GetEye(e);
	if (x) *x = e.x; if (y) *y = e.y; if (z) *z = e.z;
}

// Engine's own world->camera transform (vtable 55). Returns view-space coords.
__declspec(dllexport) void eqgfx_world_to_camera(float x, float y, float z,
                                                 float* cx, float* cy, float* cz) {
	CVector3 w{ x, y, z }, c{ 0, 0, 0 };
	if (g_pRender)
		reinterpret_cast<FnWorldToCamera>(VtblEntry(g_pRender, VT_TransformWorldToCamera))(g_pRender, &w, &c);
	if (cx) *cx = c.x; if (cy) *cy = c.y; if (cz) *cz = c.z;
}

// Display size (vtable 6/7) so the overlay can self-center.
__declspec(dllexport) void eqgfx_get_screen(int* w, int* h) {
	if (w) *w = g_pRender ? CallGetInt(g_pRender, VT_GetDisplayWidth)  : 0;
	if (h) *h = g_pRender ? CallGetInt(g_pRender, VT_GetDisplayHeight) : 0;
}

// Line half-width in pixels (0 = hairline).
__declspec(dllexport) void eqgfx_set_thickness(int t) { g_thickness = t < 0 ? 0 : t; }

// Copy the 16 floats of CRender::matrixViewProj so Lua can print them. Lets us
// read off the matrix convention (which row/col is the perspective term).
__declspec(dllexport) void eqgfx_dump_matrix(float* out16) {
	if (!out16) return;
	if (!g_pRender) { for (int i = 0; i < 16; ++i) out16[i] = 0.0f; return; }
	const float* m = reinterpret_cast<const float*>(
		reinterpret_cast<uint8_t*>(g_pRender) + REN_matrixViewProj);
	for (int i = 0; i < 16; ++i) out16[i] = m[i];
}

// Pure 2D screen-space line in pixels (no projection) - for HUD/crosshairs.
__declspec(dllexport) void eqgfx_add_screen_line(float x1, float y1, float x2, float y2, uint32_t color) {
	std::lock_guard<std::mutex> lock(g_mutex);
	g_segments.push_back(Segment{ { x1, y1, 0.0f }, { x2, y2, 0.0f }, color, true });
}

// Filled 2D screen-space rectangle (pixels) - for health bars / HUD fills.
__declspec(dllexport) void eqgfx_add_screen_rect(float x0, float y0, float x1, float y1, uint32_t color) {
	std::lock_guard<std::mutex> lock(g_mutex);
	g_rects.push_back(Rect{ x0, y0, x1, y1, color });
}

// Project a world point; visible=1 only when in front AND on screen.
__declspec(dllexport) void eqgfx_world_to_screen(float x, float y, float z,
                                                 float* sx, float* sy, int* visible) {
	float ox = 0, oy = 0;
	bool v = WorldToScreen(x, y, z, ox, oy);
	if (v && g_pRender) {
		float W = (float)CallGetInt(g_pRender, VT_GetDisplayWidth);
		float H = (float)CallGetInt(g_pRender, VT_GetDisplayHeight);
		v = (ox >= 0 && ox <= W && oy >= 0 && oy <= H);
	}
	if (sx) *sx = ox; if (sy) *sy = oy; if (visible) *visible = v ? 1 : 0;
}

// Project a world point and return the RAW screen pixels (NO on-screen rect
// clamp) plus the engine's own in-front-of-camera bool. The engine's
// ProjectWorldCoordinatesToScreen (vtable 29) returns true only when the point
// is in front of the camera, so `infront` is a reliable per-vertex front test -
// unlike eqgfx_world_to_screen's `visible`, which ANDs that with an on-screen
// test and so is false for merely-off-screen-but-in-front points too. Callers
// that triangulate large rings need this to skip wedges straddling the camera.
__declspec(dllexport) void eqgfx_project(float x, float y, float z,
                                         float* sx, float* sy, int* infront) {
	float ox = 0, oy = 0;
	bool v = WorldToScreen(x, y, z, ox, oy);
	if (sx) *sx = ox; if (sy) *sy = oy; if (infront) *infront = v ? 1 : 0;
}

__declspec(dllexport) void eqgfx_stats(uint32_t* sceneCalls, uint32_t* lastDraws) {
	if (sceneCalls) *sceneCalls = g_sceneCalls.load(std::memory_order_relaxed);
	if (lastDraws)  *lastDraws  = g_lastDraws.load(std::memory_order_relaxed);
}

__declspec(dllexport) void eqgfx_add_circle(float x, float y, float z,
                                            float radius, uint32_t color, int segments) {
	const int segs = segments < 3 ? 3 : segments;
	std::lock_guard<std::mutex> lock(g_mutex);
	float px = x + radius, py = y;
	for (int i = 1; i <= segs; ++i) {
		const float t  = (2.0f * kPi * i) / segs;
		const float cx = x + radius * cosf(t), cy = y + radius * sinf(t);
		PushSeg(px, py, z, cx, cy, z, color);
		px = cx; py = cy;
	}
}

__declspec(dllexport) void eqgfx_add_arc(float cx, float cy, float cz, float radius,
                                         float startRad, float endRad,
                                         uint32_t color, int segments) {
	const int segs = segments < 1 ? 1 : segments;
	std::lock_guard<std::mutex> lock(g_mutex);
	const float ex0 = cx + radius * cosf(startRad), ey0 = cy + radius * sinf(startRad);
	PushSeg(cx, cy, cz, ex0, ey0, cz, color);
	float px = ex0, py = ey0;
	for (int i = 1; i <= segs; ++i) {
		const float t  = startRad + (endRad - startRad) * (float)i / segs;
		const float ax = cx + radius * cosf(t), ay = cy + radius * sinf(t);
		PushSeg(px, py, cz, ax, ay, cz, color);
		px = ax; py = ay;
	}
	PushSeg(px, py, cz, cx, cy, cz, color);
}

__declspec(dllexport) void eqgfx_add_line(float x1, float y1, float z1,
                                          float x2, float y2, float z2, uint32_t color) {
	std::lock_guard<std::mutex> lock(g_mutex);
	PushSeg(x1, y1, z1, x2, y2, z2, color);
}

__declspec(dllexport) int eqgfx_get_spell_geom(int spellID, eqgfx_spell_geom* out) {
	if (out) { out->targetType = -1; out->range = out->aeRange = 0.0f; out->coneStart = out->coneEnd = 0; }
	if (!g_pSpellMgr || !out || spellID <= 0) return 0;
	auto fn = reinterpret_cast<FnGetSpellByID>(VtblEntry(g_pSpellMgr, VT_GetSpellByID));
	void* spell = fn(g_pSpellMgr, spellID);
	if (!spell) return 0;
	out->targetType = ReadField<uint8_t>(spell, SP_TargetType);
	out->range      = ReadField<float>(spell, SP_Range);
	out->aeRange    = ReadField<float>(spell, SP_AERange);
	out->coneStart  = ReadField<int32_t>(spell, SP_ConeStartAngle);
	out->coneEnd    = ReadField<int32_t>(spell, SP_ConeEndAngle);
	return 1;
}

} // extern "C"

BOOL APIENTRY DllMain(HMODULE, DWORD reason, LPVOID) {
	if (reason == DLL_PROCESS_DETACH) eqgfx_shutdown();
	return TRUE;
}
