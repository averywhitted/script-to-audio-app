// Export Audio: copies a project's rendered scenes (.m4a only) to a folder the
// user picks, for listening elsewhere (phone, another computer).

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/platform.dart';
import '../state/app_state.dart';

Future<void> exportAudio(BuildContext context, {required String sourceFolder, required String projectName}) async {
  final app = context.read<AppState>();
  final dest = await getDirectoryPath(confirmButtonText: 'Export Here');
  if (dest == null) return;
  try {
    final (folder, count) = await AppState.exportAudio(sourceFolder: sourceFolder, projectName: projectName, destination: dest);
    app.appendLog('Exported $count scene${count == 1 ? '' : 's'} to $folder', LogStyle.success);
    await NativePlatform.revealInFinder(folder);
  } catch (e) {
    app.showError(e is StateError ? e.message : 'Could not export the audio: $e');
  }
}
