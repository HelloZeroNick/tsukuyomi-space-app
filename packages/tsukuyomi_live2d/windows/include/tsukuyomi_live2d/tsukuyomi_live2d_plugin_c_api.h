#pragma once
#include <flutter_plugin_registrar.h>
#ifdef FLUTTER_PLUGIN_IMPL
#define TS_PLUGIN_EXPORT __declspec(dllexport)
#else
#define TS_PLUGIN_EXPORT __declspec(dllimport)
#endif
#ifdef __cplusplus
extern "C" {
#endif
TS_PLUGIN_EXPORT void TsukuyomiLive2dPluginCApiRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar);
#ifdef __cplusplus
}
#endif
