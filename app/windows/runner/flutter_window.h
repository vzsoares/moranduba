#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shellapi.h>

#include <memory>

#include "win32_window.h"

// Posted by a second launch to bring this window back.
constexpr const wchar_t kShowMessageName[] = L"MorandubaShow";

// Hosts the Flutter view. Closing hides it to the tray icon, so calls and
// notifications keep going; Quit in the tray menu exits.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  void AddTrayIcon(HWND hwnd);
  void RemoveTrayIcon();
  void ShowFromTray(HWND hwnd);
  void ShowTrayMenu(HWND hwnd);

  NOTIFYICONDATAW tray_icon_ = {};
  bool quitting_ = false;

  // Sent by Explorer when it restarts; the icon must be added again.
  UINT taskbar_created_ = 0;
  UINT show_message_ = 0;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
