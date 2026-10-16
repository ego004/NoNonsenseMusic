#ifndef RUNNER_TASKBAR_BUTTONS_H_
#define RUNNER_TASKBAR_BUTTONS_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <shobjidl.h>
#include <windows.h>
#include <wrl/client.h>

#include <memory>
#include <optional>
#include <string>

// Previous, Play or Pause, and Next under the window's preview on the taskbar, as Windows Media Player has: a
// thumbnail toolbar (#22). The Widgets board takes widgets only from packaged (MSIX) apps; this is Windows' own place
// for an unpackaged app's media buttons. Dart (lib/core/taskbar_buttons.dart) says what the player can do on the
// "nononsense/taskbar" channel and hears the presses. Nothing runs at rest: Windows draws the toolbar itself, and
// sends a message only when a button is pressed.
class TaskbarButtons {
 public:
  TaskbarButtons(flutter::BinaryMessenger* messenger, HWND window);
  ~TaskbarButtons();

  // The window's messages the buttons need: the taskbar button's creation (again after Explorer restarts), a press,
  // and the system's theme changing between light and dark. Others are not theirs.
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  // Puts the toolbar on the taskbar button; once there, only its buttons' state can change (ThumbBarAddButtons).
  void Add();
  // The buttons as the player is now.
  void Update();
  // The glyphs as icons, light or dark after the taskbar.
  void DrawIcons();
  void Fill(THUMBBUTTON (&buttons)[3]) const;

  HWND window_;
  UINT taskbar_created_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  Microsoft::WRL::ComPtr<ITaskbarList3> taskbar_;
  bool added_ = false;
  // what Dart last said
  bool loaded_ = false;    // a song is loaded: Previous and Next work
  bool playing_ = false;   // Pause instead of Play
  bool can_play_ = false;  // a song to play: the loaded one, or the latest play to resume
  std::wstring play_tip_ = L"Play";
  HICON icons_[4] = {};    // previous, play, pause, next
};

#endif  // RUNNER_TASKBAR_BUTTONS_H_
