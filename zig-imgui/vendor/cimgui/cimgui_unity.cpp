#define IMGUI_DISABLE_OBSOLETE_FUNCTIONS 1
#define IMGUI_DISABLE_OBSOLETE_KEYIO 1
#define IMGUI_USE_WCHAR32 1
#define IMGUI_IMPL_API extern "C"
#define ImTextureID unsigned long long

#include "imgui/imgui.cpp"
#include "imgui/imgui_draw.cpp"
#include "imgui/imgui_demo.cpp"
#include "imgui/imgui_tables.cpp"
#include "imgui/imgui_widgets.cpp"
#ifdef IMGUI_ENABLE_FREETYPE
#include "imgui/imgui_freetype.cpp"
#endif
#include "cimgui.cpp"
