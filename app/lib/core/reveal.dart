import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Whether this system has a file manager for showInFolder: a computer's, not a phone's.
bool get canShowInFolder => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// Opens the folder holding [f] in the system's file manager, with [f] selected: Explorer, the Finder; on Linux the
/// folder only.
Future<void> showInFolder(File f) async {
  if (Platform.isWindows) {
    final path = f.absolute.path.replaceAll('/', r'\');
    if (!_selectInExplorer(path)) await openFolder(File(path).parent);
  } else if (Platform.isMacOS) {
    await Process.run('open', ['-R', f.absolute.path]);
  } else {
    await openFolder(f.parent);
  }
}

/// Opens [d] in the system's file manager.
Future<void> openFolder(Directory d) async {
  final path = Platform.isWindows ? d.absolute.path.replaceAll('/', r'\') : d.absolute.path;
  await Process.run(Platform.isWindows ? 'explorer.exe' : Platform.isMacOS ? 'open' : 'xdg-open', [path]);
}

typedef _PathToItemC = Pointer<Void> Function(Pointer<Utf16>);
typedef _PathToItem = Pointer<Void> Function(Pointer<Utf16>);
typedef _OpenAndSelectC = Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>, Uint32);
typedef _OpenAndSelect = int Function(Pointer<Void>, int, Pointer<Pointer<Void>>, int);
typedef _FreeItemC = Void Function(Pointer<Void>);
typedef _FreeItem = void Function(Pointer<Void>);
typedef _ComInitC = Int32 Function(Pointer<Void>, Uint32);
typedef _ComInit = int Function(Pointer<Void>, int);

/// Explorer with the file selected, as Windows' own apps do it (SHOpenFolderAndSelectItems). `explorer /select,`
/// reads a comma in an unquoted path as its end, and Dart quotes an argument only when it has a space: a song named
/// "Hello, Goodbye" would have opened the wrong folder. False when it could not, for the caller to open the folder.
bool _selectInExplorer(String path) {
  try {
    final shell = DynamicLibrary.open('shell32.dll');
    final pathToItem = shell.lookupFunction<_PathToItemC, _PathToItem>('ILCreateFromPathW');
    final openAndSelect = shell.lookupFunction<_OpenAndSelectC, _OpenAndSelect>('SHOpenFolderAndSelectItems');
    final freeItem = shell.lookupFunction<_FreeItemC, _FreeItem>('ILFree');
    // the shell call needs COM on this thread; already set up is fine too
    DynamicLibrary.open('ole32.dll').lookupFunction<_ComInitC, _ComInit>('CoInitializeEx')(nullptr, 0x2);
    final wide = path.toNativeUtf16();
    final item = pathToItem(wide);
    calloc.free(wide);
    if (item == nullptr) return false;
    final result = openAndSelect(item, 0, nullptr, 0);
    freeItem(item);
    return result >= 0;
  } catch (_) {
    return false;
  }
}
