import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const FolderTestApp());
}

class FolderTestApp extends StatelessWidget {
  const FolderTestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'iCloud folder test',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
      ),
      home: const FolderScreen(),
    );
  }
}

class FolderScreen extends StatefulWidget {
  const FolderScreen({super.key});

  @override
  State<FolderScreen> createState() => _FolderScreenState();
}

class _FolderScreenState extends State<FolderScreen> {
  final MethodChannel _channel = const MethodChannel('tableread/folder');
  final List<String> _logEntries = [];
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _checkStatus();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _log(String message) {
    final now = DateTime.now();
    final time = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    setState(() {
      _logEntries.insert(0, '$time $message');
    });
  }

  Future<void> _checkStatus() async {
    try {
      final result = await _channel.invokeMethod('status');
      if (result == null) {
        _log('No folder remembered yet');
      } else {
        final path = result['path'] ?? 'unknown';
        final stale = result['stale'] ?? false;
        _log('Remembered folder: $path (stale: $stale)');
      }
    } catch (e) {
      _log('ERROR: $e');
    }
  }

  Future<void> _pickFolder() async {
    try {
      final result = await _channel.invokeMethod('pick');
      if (result == null) {
        _log('Folder pick cancelled');
      } else {
        final path = result['path'] ?? 'unknown';
        final scoped = result['scoped'] ?? false;
        _log('Picked folder: $path (scoped: $scoped)');
        await _checkStatus();
      }
    } catch (e) {
      _log('ERROR: $e');
    }
  }

  Future<void> _listFiles() async {
    try {
      final result = await _channel.invokeMethod('list');
      if (result == null) {
        _log('List returned null');
        return;
      }
      final List<dynamic> items = result;
      for (final item in items) {
        final name = item['name'] ?? 'unknown';
        final dir = item['dir'] ?? false;
        final size = item['size'] ?? 0;
        final download = item['download'] ?? 'unknown';
        _log('File: $name, dir: $dir, size: $size, download: $download');
      }
    } catch (e) {
      _log('ERROR: $e');
    }
  }

  Future<void> _readHelloFromMac() async {
    try {
      final result = await _channel.invokeMethod('read', {'name': 'hello-from-mac.txt'});
      if (result == null) {
        _log('Read hello-from-mac.txt returned null');
        return;
      }
      final bytes = result['bytes'] ?? 0;
      final text = result['text'] ?? '';
      final seconds = result['seconds'] ?? 0.0;
      _log('Read hello-from-mac.txt: bytes=$bytes, text="$text", seconds=$seconds');
    } catch (e) {
      _log('ERROR: $e');
    }
  }

  Future<void> _writeHelloFromIphone() async {
    try {
      final timestamp = DateTime.now().toIso8601String();
      final text = 'Hello from iPhone at $timestamp';
      final result = await _channel.invokeMethod('write', {'name': 'hello-from-iphone.txt', 'text': text});
      if (result == null) {
        _log('Write hello-from-iphone.txt returned null');
        return;
      }
      _log('Write hello-from-iphone.txt: result=$result');
    } catch (e) {
      _log('ERROR: $e');
    }
  }

  Future<void> _readAllFiles() async {
    try {
      final listResult = await _channel.invokeMethod('list');
      if (listResult == null) {
        _log('Read all files: list returned null');
        return;
      }
      final List<dynamic> items = listResult;
      for (final item in items) {
        final name = item['name'] ?? 'unknown';
        final dir = item['dir'] ?? false;
        if (!dir) {
          try {
            final readResult = await _channel.invokeMethod('read', {'name': name});
            if (readResult == null) {
              _log('Read all files: read $name returned null');
              continue;
            }
            final bytes = readResult['bytes'] ?? 0;
            final seconds = readResult['seconds'] ?? 0.0;
            _log('Read all files: $name, bytes=$bytes, seconds=${seconds.toStringAsFixed(2)}');
          } catch (e) {
            _log('ERROR: Read all files - read $name failed: $e');
          }
        }
      }
    } catch (e) {
      _log('ERROR: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('iCloud folder test'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Wrap(
              spacing: 8.0,
              runSpacing: 8.0,
              children: [
                FilledButton(
                  onPressed: _pickFolder,
                  child: const Text('Pick folder'),
                ),
                FilledButton(
                  onPressed: _listFiles,
                  child: const Text('List'),
                ),
                FilledButton(
                  onPressed: _readHelloFromMac,
                  child: const Text('Read hello-from-mac.txt'),
                ),
                FilledButton(
                  onPressed: _writeHelloFromIphone,
                  child: const Text('Write hello-from-iphone.txt'),
                ),
                FilledButton(
                  onPressed: _readAllFiles,
                  child: const Text('Read all files'),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              controller: _scrollController,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: SelectableText(
                  _logEntries.join('\n'),
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
