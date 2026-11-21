import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/platform.dart';
import 'account.dart';
import 'library.dart';
import 'shows.dart';
import 'subsonic.dart';

/// Concerts near you: the server (music-lookup's concerts.py) looks once a week for shows of the artists you
/// play most and the ones you follow, near the town you set under Following › Shows (with your Ticketmaster
/// key there, if any). Encore shows them on Home and in Concerts, says when a new one is announced, and puts
/// one in your calendar.
class Concerts {
  const Concerts({this.city = '', this.source = '', this.updated, this.shows = const [], this.supported = true});
  final String city, source;
  final DateTime? updated;
  final List<(Show, int)> shows; // and when it was first seen (ms)
  final bool supported;

  factory Concerts.fromJson(Map<String, dynamic> j) => Concerts(
    city: '${j['city'] ?? ''}',
    source: '${j['source'] ?? ''}',
    updated: j['updated'] is num && j['updated'] > 0 ? DateTime.fromMillisecondsSinceEpoch(j['updated']) : null,
    shows: [
      for (final s in (j['show'] as List? ?? const []))
        if (s is Map) (Show.fromJson(s), (s['first'] as num?)?.toInt() ?? 0),
    ],
  );
}

final concertsProvider = FutureProvider.autoDispose<Concerts>((ref) async {
  ref.cacheFor(const Duration(minutes: 30));
  final c = ref.watch(clientProvider);
  if (c == null) return const Concerts(supported: false);
  try {
    return await c.concerts();
  } on SubsonicException catch (e) {
    if (e.code == 70 || e.message.contains(' 404')) return const Concerts(supported: false);
    rethrow;
  }
});

/// Shows first seen after [since] (ms): the ones to tell you about.
List<Show> newShows(Concerts c, int since) => [for (final (s, first) in c.shows) if (first > since) s];

/// "Fri 5 Dec" (and the year when it isn't this one).
String showDate(String date, [DateTime? now]) {
  final d = DateTime.tryParse(date);
  if (d == null) return date;
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final y = d.year == (now ?? DateTime.now()).year ? '' : ' ${d.year}';
  return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]}$y';
}

/// The show's start (local time; 20:00 when the time isn't known).
DateTime showStart(Show s) {
  final d = DateTime.tryParse(s.date) ?? DateTime.now();
  final t = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(s.time);
  return DateTime(d.year, d.month, d.day, t == null ? 20 : int.parse(t[1]!), t == null ? 0 : int.parse(t[2]!));
}

/// An iCalendar event for the show, three hours long.
String showIcs(Show s, {DateTime? stamp}) {
  String f(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}T'
      '${d.hour.toString().padLeft(2, '0')}${d.minute.toString().padLeft(2, '0')}00';
  String esc(String v) => v.replaceAll('\\', '\\\\').replaceAll(';', '\\;').replaceAll(',', '\\,').replaceAll('\n', '\\n');
  final start = showStart(s);
  return [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Encore//Concerts//EN',
    'BEGIN:VEVENT',
    'UID:${s.key.hashCode.toUnsigned(32)}@encore',
    'DTSTAMP:${f((stamp ?? DateTime.now()).toUtc())}Z',
    'DTSTART:${f(start)}',
    'DTEND:${f(start.add(const Duration(hours: 3)))}',
    'SUMMARY:${esc(s.name.isEmpty ? s.artist : '${s.artist}: ${s.name}')}',
    if (s.place.isNotEmpty) 'LOCATION:${esc(s.place)}',
    if (s.url.isNotEmpty) 'URL:${s.url}',
    'END:VEVENT',
    'END:VCALENDAR',
    '',
  ].join('\r\n');
}

const _system = MethodChannel('encore/system');

/// Put the show in your calendar: Android's "new event" screen, filled in; on the desktop an .ics file opened
/// with your calendar app.
Future<void> addShowToCalendar(Show s) async {
  final start = showStart(s);
  if (!isDesktop) {
    await _system.invokeMethod('addEvent', {
      'title': s.name.isEmpty ? s.artist : '${s.artist}: ${s.name}',
      'location': s.place,
      'begin': start.millisecondsSinceEpoch,
      'end': start.add(const Duration(hours: 3)).millisecondsSinceEpoch,
      'description': s.url,
    });
    return;
  }
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/encore-${s.key.hashCode.toUnsigned(32)}.ics');
  await f.writeAsString(showIcs(s));
  if (Platform.isWindows) {
    await Process.start('rundll32', ['url.dll,FileProtocolHandler', f.path], mode: ProcessStartMode.detached);
  } else {
    await Process.start('xdg-open', [f.path], mode: ProcessStartMode.detached);
  }
}
