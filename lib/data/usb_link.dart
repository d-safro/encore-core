import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'subsonic.dart';

/// Music over a USB cable: with the phone plugged into the computer that runs the server (and
/// `encore-usb` forwarding the phone's port 4533 there), the server answers on the phone's own
/// 127.0.0.1:4533 and everything goes through the cable (browsing, playing, downloads: see clientProvider).
///
/// True while the server answers through the cable. The check itself is the phone app's (its
/// PhoneUsbLink overrides [usbLinkProvider]); here it is never plugged in, which is also what the desktop
/// wants (its own 127.0.0.1:4533 may be the server itself).
class UsbLinkNotifier extends Notifier<bool> {
  static const port = 4533;

  /// [u] taken through the cable (same path and login, so a server under e.g. /navidrome works too).
  static Uri viaCable(Uri u) => u.replace(scheme: 'http', host: '127.0.0.1', port: port);

  /// The server's address through the cable.
  static String cableBase(Credentials c) => viaCable(Uri.parse(c.base)).toString().replaceAll(RegExp(r'/+$'), '');

  @override
  bool build() => false;

  /// Looks again now (the app came back, the server changed).
  Future<void> check() async {}
}

final usbLinkProvider = NotifierProvider<UsbLinkNotifier, bool>(UsbLinkNotifier.new);
