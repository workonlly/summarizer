//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <connectivity_plus/connectivity_plus_windows_plugin.h>
#include <flutter_gemma/flutter_gemma_plugin.h>
#include <flutter_tts/flutter_tts_plugin.h>
#include <flutter_webrtc/flutter_web_r_t_c_plugin.h>
#include <livekit_client/live_kit_plugin.h>
#include <permission_handler_windows/permission_handler_windows_plugin.h>
#include <speech_to_text_windows/speech_to_text_windows.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  ConnectivityPlusWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("ConnectivityPlusWindowsPlugin"));
  FlutterGemmaPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterGemmaPlugin"));
  FlutterTtsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterTtsPlugin"));
  FlutterWebRTCPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterWebRTCPlugin"));
  LiveKitPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("LiveKitPlugin"));
  PermissionHandlerWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("PermissionHandlerWindowsPlugin"));
  SpeechToTextWindowsRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("SpeechToTextWindows"));
}
