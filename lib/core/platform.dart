import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// Running as the desktop app (Linux; the same code would serve Windows and macOS).
final bool isDesktop = !kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS);

/// What this device is called in "Devices" and on the server ("Encore on" plus the computer's name).
String deviceKind() => isDesktop ? 'computer' : 'phone';
