#include "taskbar_buttons.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cstdint>
#include <cwchar>
#include <iterator>
#include <vector>

namespace {

// The buttons' ids: a press arrives as WM_COMMAND with THBN_CLICKED and the id
constexpr UINT kPrevious = 1;
constexpr UINT kPlay = 2;
constexpr UINT kNext = 3;

// Previous, Play, Pause and Next, filled as in the player bar, from Segoe Fluent Icons (Windows 11) or Segoe MDL2
// Assets (Windows 10), the system's own icon fonts: both have them at these code points
constexpr wchar_t kGlyphs[4] = {0xF8AC, 0xF5B0, 0xF8AE, 0xF8AD};

std::wstring Utf16(const std::string& text) {
  int length = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
  if (length <= 1) return L"";
  std::wstring out(length - 1, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, out.data(), length);
  return out;
}

// Whether the taskbar, and so the toolbar under the preview, is light: Settings > Personalisation > Colours >
// "Choose your mode" (Windows' mode, not the apps').
bool TaskbarIsLight() {
  DWORD light = 0;
  DWORD size = sizeof(light);
  RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
               L"SystemUsesLightTheme", RRF_RT_REG_DWORD, nullptr, &light, &size);
  return light != 0;
}

// The first of the icon fonts that is installed, at `size` pixels; null with neither.
HFONT IconFont(HDC dc, int size) {
  for (const wchar_t* face : {L"Segoe Fluent Icons", L"Segoe MDL2 Assets"}) {
    HFONT font = CreateFontW(-size, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                             CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY, DEFAULT_PITCH, face);
    HGDIOBJ before = SelectObject(dc, font);
    wchar_t chosen[LF_FACESIZE] = {};
    GetTextFaceW(dc, LF_FACESIZE, chosen);
    SelectObject(dc, before);
    if (_wcsicmp(chosen, face) == 0) return font;  // else GDI put another face in its place
    DeleteObject(font);
  }
  return nullptr;
}

// One glyph as a `size`-pixel icon in `colour`. Drawn white on black, so each pixel's brightness is how much of it the
// glyph covers: that becomes the icon's alpha, with the colour premultiplied.
HICON GlyphIcon(wchar_t glyph, int size, COLORREF colour) {
  BITMAPINFO info = {};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = size;
  info.bmiHeader.biHeight = -size;  // top-down rows
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  HDC dc = CreateCompatibleDC(nullptr);
  void* bits = nullptr;
  HBITMAP image = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  HFONT font = image ? IconFont(dc, size) : nullptr;
  if (!font) {
    if (image) DeleteObject(image);
    DeleteDC(dc);
    return nullptr;
  }
  HGDIOBJ old_image = SelectObject(dc, image);
  HGDIOBJ old_font = SelectObject(dc, font);
  SetBkMode(dc, TRANSPARENT);
  SetTextColor(dc, RGB(255, 255, 255));
  RECT box = {0, 0, size, size};
  DrawTextW(dc, &glyph, 1, &box, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
  GdiFlush();
  auto* pixels = static_cast<uint32_t*>(bits);
  for (int i = 0; i < size * size; i++) {
    const uint32_t cover = pixels[i] & 0xFF;
    pixels[i] = (cover << 24) | ((GetRValue(colour) * cover / 255) << 16) | ((GetGValue(colour) * cover / 255) << 8) |
                (GetBValue(colour) * cover / 255);
  }
  SelectObject(dc, old_font);
  SelectObject(dc, old_image);
  DeleteObject(font);
  // the mask is unused where the image has alpha; all clear
  std::vector<BYTE> clear(((size + 15) / 16) * 2 * size, 0);
  HBITMAP mask = CreateBitmap(size, size, 1, 1, clear.data());
  ICONINFO parts = {TRUE, 0, 0, mask, image};
  HICON icon = CreateIconIndirect(&parts);
  DeleteObject(mask);
  DeleteObject(image);
  DeleteDC(dc);
  return icon;
}

}  // namespace

TaskbarButtons::TaskbarButtons(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window), taskbar_created_(RegisterWindowMessageW(L"TaskbarButtonCreated")) {
  DrawIcons();
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "nononsense/taskbar", &flutter::StandardMethodCodec::GetInstance());
  // "set" {loaded, playing, canPlay, playTip}: answers whether the toolbar is on the taskbar button yet
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto* state = std::get_if<flutter::EncodableMap>(call.arguments());
    if (call.method_name() != "set" || !state) {
      result->NotImplemented();
      return;
    }
    auto value = [state](const char* key) { return state->find(flutter::EncodableValue(key)); };
    auto flag = [&](const char* key) {
      auto found = value(key);
      return found != state->end() && std::get_if<bool>(&found->second) && std::get<bool>(found->second);
    };
    loaded_ = flag("loaded");
    playing_ = flag("playing");
    can_play_ = flag("canPlay");
    auto tip = value("playTip");
    if (tip != state->end() && std::get_if<std::string>(&tip->second)) play_tip_ = Utf16(std::get<std::string>(tip->second));
    Update();
    result->Success(flutter::EncodableValue(added_));
  });
}

TaskbarButtons::~TaskbarButtons() {
  channel_->SetMethodCallHandler(nullptr);
  for (HICON icon : icons_) {
    if (icon) DestroyIcon(icon);
  }
}

std::optional<LRESULT> TaskbarButtons::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == taskbar_created_) {
    Add();
    return 0;
  }
  if (message == WM_COMMAND && HIWORD(wparam) == THBN_CLICKED) {
    const UINT id = LOWORD(wparam);
    const char* press = id == kPrevious ? "previous" : id == kPlay ? "toggle" : id == kNext ? "next" : nullptr;
    if (press) {
      channel_->InvokeMethod("press", std::make_unique<flutter::EncodableValue>(press));
      return 0;
    }
  }
  // light or dark: the icons follow the taskbar; the window's own handling goes on
  if (message == WM_SETTINGCHANGE && lparam &&
      wcscmp(reinterpret_cast<const wchar_t*>(lparam), L"ImmersiveColorSet") == 0) {
    HICON old[4];
    std::copy(std::begin(icons_), std::end(icons_), old);
    DrawIcons();
    Update();
    for (HICON icon : old) {
      if (icon) DestroyIcon(icon);
    }
  }
  return std::nullopt;
}

void TaskbarButtons::Add() {
  if (!taskbar_ && (FAILED(CoCreateInstance(CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&taskbar_))) ||
                    FAILED(taskbar_->HrInit()))) {
    taskbar_.Reset();
    return;
  }
  THUMBBUTTON buttons[3];
  Fill(buttons);
  // a new taskbar button (Explorer restarted) has no toolbar; the same one keeps its toolbar, which is updated instead
  added_ = SUCCEEDED(taskbar_->ThumbBarAddButtons(window_, 3, buttons)) ||
           (added_ && SUCCEEDED(taskbar_->ThumbBarUpdateButtons(window_, 3, buttons)));
}

void TaskbarButtons::Update() {
  if (!added_) return;  // Add puts them on with this state once the taskbar button exists
  THUMBBUTTON buttons[3];
  Fill(buttons);
  taskbar_->ThumbBarUpdateButtons(window_, 3, buttons);
}

void TaskbarButtons::DrawIcons() {
  const int size = GetSystemMetrics(SM_CXSMICON);  // the size the taskbar draws them at
  const COLORREF colour = TaskbarIsLight() ? RGB(0x1A, 0x1A, 0x1A) : RGB(0xFF, 0xFF, 0xFF);
  for (int i = 0; i < 4; i++) icons_[i] = GlyphIcon(kGlyphs[i], size, colour);
}

void TaskbarButtons::Fill(THUMBBUTTON (&buttons)[3]) const {
  struct Button {
    UINT id;
    HICON icon;
    const wchar_t* tip;
    bool enabled;
  };
  const Button all[3] = {
      {kPrevious, icons_[0], L"Previous", loaded_},
      {kPlay, playing_ ? icons_[2] : icons_[1], playing_ ? L"Pause" : play_tip_.c_str(), can_play_},
      {kNext, icons_[3], L"Next", loaded_},
  };
  for (int i = 0; i < 3; i++) {
    buttons[i] = {};
    buttons[i].dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS;
    buttons[i].iId = all[i].id;
    buttons[i].hIcon = all[i].icon;
    wcsncpy_s(buttons[i].szTip, all[i].tip, _TRUNCATE);
    buttons[i].dwFlags = all[i].enabled ? THBF_ENABLED : THBF_DISABLED;
  }
}
