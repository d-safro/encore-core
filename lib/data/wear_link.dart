import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account.dart';
import 'local_link.dart';

/// Encore on a paired Wear OS watch signs in to the same server: the phone keeps its sign-in (server, user,
/// password, home-network address) in the Wearable Data Layer, which only Encore on your own watch can read.
/// Signing out takes it away. The watch remote itself needs nothing from here (it works through the media
/// session; see android/app WearRemoteService.kt).
final wearLinkProvider = Provider<void>((ref) {
  if (!Platform.isAndroid) return;
  const channel = MethodChannel('encore/wear');
  Future<void> share() async {
    final c = ref.read(accountProvider).value;
    try {
      if (c == null) {
        await channel.invokeMethod('signedOut');
      } else {
        await channel.invokeMethod('account', {
          'server': c.base,
          'user': c.username,
          'pass': c.password,
          'localAddress': ref.read(localAddressProvider),
        });
      }
    } catch (_) {} // no Google Play services, or no watch: nothing to do
  }

  ref.listen(accountProvider, (prev, next) {
    if (next.isLoading) return;
    share();
  }, fireImmediately: true);
  ref.listen(localAddressProvider, (_, _) => share());
});
