// Native macOS helpers (implemented in macos/Runner/MainFlutterWindow.swift).

import 'package:flutter/services.dart';

class NativePlatform {
  static const _channel = MethodChannel('tableread/platform');

  /// Moves a file or folder to the Trash. Returns where it landed, or null.
  static Future<String?> trash(String path) => _channel.invokeMethod<String>('trashItem', {'path': path});

  static Future<void> revealInFinder(String path) => _channel.invokeMethod('revealInFinder', {'path': path});

  static Future<void> openPath(String path) => _channel.invokeMethod('openPath', {'path': path});

  static Future<void> openURL(String url) => _channel.invokeMethod('openURL', {'url': url});

  static Future<String?> keychainRead(String account) => _channel.invokeMethod<String>('keychainRead', {'account': account});

  static Future<void> keychainWrite(String account, String value) => _channel.invokeMethod('keychainWrite', {'account': account, 'value': value});

  static Future<void> keychainDelete(String account) => _channel.invokeMethod('keychainDelete', {'account': account});

  static Future<Map<String, String>> appVersion() async {
    try {
      final m = await _channel.invokeMethod<Map>('appVersion');
      return Map<String, String>.from(m ?? const {});
    } catch (_) {
      return const {'version': '?', 'build': '?', 'os': '?'};
    }
  }
}

class WindowControl {
  static const _channel = MethodChannel('tableread/platform');
  static Future<void> startDrag() => _channel.invokeMethod('startWindowDrag');
  static Future<void> zoom() => _channel.invokeMethod('zoomWindow');
}
