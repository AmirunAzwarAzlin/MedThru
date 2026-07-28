import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Where a just-written export ended up, and how the OS surfaced it, so callers
/// can show a sensible message.
class SavedExport {
  const SavedExport(this.path, {required this.shared});

  /// Absolute path the bytes were written to.
  final String path;

  /// True when a share sheet was raised (Android/iOS); false when the file was
  /// opened directly with the desktop default handler.
  final bool shared;
}

/// Writes [bytes] to a file named [fileName] and hands it to the OS: opened
/// with the default app on Windows (so printing / calendar import happens
/// there), or offered through the system share sheet on Android/iOS.
///
/// Kept in one place so every export — the PDFs in `pdf_export.dart` and the
/// `.ics` in `calendar_export.dart` — behaves the same on each platform.
Future<SavedExport> saveAndOpen(
  Uint8List bytes,
  String fileName, {
  required String mimeType,
  String? shareText,
}) async {
  if (Platform.isAndroid || Platform.isIOS) {
    // A share sheet is the native "do something with this file" flow on
    // mobile — save to Files, import into a calendar, send it on, etc.
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: mimeType)],
        text: shareText,
      ),
    );
    return SavedExport(file.path, shared: true);
  }

  // Desktop (Windows / macOS / Linux): drop it in Downloads and let the OS
  // open it with whatever handles that file type.
  final home = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      Directory.current.path;
  final sep = Platform.pathSeparator;
  var dir = Directory('$home${sep}Downloads');
  if (!await dir.exists()) {
    dir = Directory(home);
  }
  final file = File('${dir.path}$sep$fileName');
  await file.writeAsBytes(bytes);
  await _openWithDefaultApp(file.path);
  return SavedExport(file.path, shared: false);
}

Future<void> _openWithDefaultApp(String path) async {
  if (Platform.isWindows) {
    await Process.start('cmd', ['/c', 'start', '""', path], runInShell: true);
  } else if (Platform.isMacOS) {
    await Process.start('open', [path]);
  } else if (Platform.isLinux) {
    await Process.start('xdg-open', [path]);
  }
}
