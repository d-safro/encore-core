import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'online_lyrics.dart' show parseLrc;

/// Lyrics that come with a music file on this device: inside its tags, or in a `.lrc` file beside it.
///   MP3        ID3v2 SYLT (timed) and USLT (plain, or LRC text)
///   FLAC, Ogg  Vorbis comments LYRICS / UNSYNCEDLYRICS / SYNCEDLYRICS (plain or LRC text), Opus too
///   M4A, APE   ©lyr / LYRICS, read by audio_metadata_reader
/// Timed lyrics win over plain ones, wherever they are. Shared code: plain Dart, given a file dart:io can read
/// (on Android, MediaStoreSource hands one over for a content:// address).

const _maxRead = 32 << 20; // tags bigger than this (huge pictures) aren't looked through

/// The file's lyrics, or empty. [lrcText]: a .lrc found for it some other way (Android); otherwise the one next
/// to [path] (same name, `.lrc`) is read.
Future<Lyrics> fileLyrics(String path, {String? lrcText}) async {
  final found = <Lyrics>[];
  try {
    found.addAll(await embeddedLyrics(File(path)));
  } catch (_) {}
  final lrc = lrcText ?? await _sidecar(path);
  if (lrc != null && lrc.trim().isNotEmpty) found.add(lyricsFromText(lrc).withSource('the .lrc file'));
  return found.where((l) => l.synced && !l.isEmpty).firstOrNull ??
      found.where((l) => !l.isEmpty).firstOrNull ??
      const Lyrics();
}

Future<String?> _sidecar(String path) async {
  for (final ext in const ['.lrc', '.LRC']) {
    final f = File(p.setExtension(path, ext));
    try {
      if (await f.exists()) return _decode(await f.readAsBytes());
    } catch (_) {}
  }
  return null;
}

/// Text that may be LRC ("[01:23.45] line"): timed when it is, plain otherwise.
Lyrics lyricsFromText(String text) {
  final t = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final timed = parseLrc(t);
  if (timed.lines.length >= 2) return timed;
  final plain = t.trim();
  return plain.isEmpty ? const Lyrics() : Lyrics.plain(plain);
}

/// Every lyrics found in [f]'s tags (timed ones first).
Future<List<Lyrics>> embeddedLyrics(File f) async {
  final raf = await f.open();
  final out = <Lyrics>[];
  try {
    final head = await raf.read(12);
    if (head.length < 4) return const [];
    String tag(int from, int n) => String.fromCharCodes(head.sublist(from, from + n));
    if (tag(0, 3) == 'ID3') {
      out.addAll(_id3(await _readTag(raf)));
    } else if (tag(0, 4) == 'fLaC') {
      out.addAll(_comments(await _flacComments(raf)));
    } else if (tag(0, 4) == 'OggS') {
      out.addAll(_comments(await _oggComments(raf)));
    }
  } finally {
    await raf.close();
  }
  if (out.isEmpty) {
    // M4A, APE, and anything else the tag library knows
    try {
      final text = readMetadata(f).lyrics;
      if (text != null && text.trim().isNotEmpty) out.add(lyricsFromText(text));
    } catch (_) {}
  }
  out.sort((a, b) => (b.synced ? 1 : 0) - (a.synced ? 1 : 0));
  return [
    for (final l in out)
      if (!l.isEmpty) l.withSource('the file'),
  ];
}

// ── ID3v2 (MP3) ──
int _synchsafe(List<int> b, int at) => (b[at] << 21) | (b[at + 1] << 14) | (b[at + 2] << 7) | b[at + 3];
int _be(List<int> b, int at, int n) {
  var v = 0;
  for (var i = 0; i < n; i++) {
    v = (v << 8) | b[at + i];
  }
  return v;
}

/// The whole ID3v2 tag: its header (10 bytes) then its frames.
Future<Uint8List> _readTag(RandomAccessFile raf) async {
  await raf.setPosition(0);
  final h = await raf.read(10);
  if (h.length < 10) return Uint8List(0);
  final size = _synchsafe(h, 6);
  if (size <= 0 || size > _maxRead) return Uint8List(0);
  return Uint8List.fromList([...h, ...await raf.read(size)]);
}

List<int> _ununsync(List<int> b) {
  final out = <int>[];
  for (var i = 0; i < b.length; i++) {
    out.add(b[i]);
    if (b[i] == 0xFF && i + 1 < b.length && b[i + 1] == 0) i++;
  }
  return out;
}

/// The lyrics frames of an ID3v2.2 / 2.3 / 2.4 tag ([tag] starts with its 10-byte header).
List<Lyrics> _id3(Uint8List tag) {
  if (tag.length < 10) return const [];
  final ver = tag[3], flags = tag[5];
  List<int> body = tag.sublist(10);
  if (flags & 0x80 != 0 && ver < 4) body = _ununsync(body); // the whole tag was unsynchronised (2.2 / 2.3)
  var at = 0;
  if (flags & 0x40 != 0 && ver >= 3 && body.length >= 4) {
    at = ver == 4 ? _synchsafe(body, 0) : _be(body, 0, 4) + 4; // an extended header to skip
  }
  final idLen = ver == 2 ? 3 : 4, hdr = ver == 2 ? 6 : 10;
  final synced = <Lyrics>[], plain = <Lyrics>[];
  while (at + hdr <= body.length) {
    final id = String.fromCharCodes(body.sublist(at, at + idLen));
    if (id.codeUnitAt(0) == 0) break; // padding
    final size = ver == 2 ? _be(body, at + 3, 3) : (ver == 4 ? _synchsafe(body, at + 4) : _be(body, at + 4, 4));
    final fflags = ver == 2 ? 0 : _be(body, at + 8, 2);
    at += hdr;
    if (size <= 0 || at + size > body.length) break;
    List<int> data = body.sublist(at, at + size);
    at += size;
    if (ver == 4) {
      if (fflags & 0x0001 != 0 && data.length >= 4) data = data.sublist(4); // its length before unsynchronising
      if (fflags & 0x0002 != 0) data = _ununsync(data);
      if (fflags & 0x000C != 0) continue; // compressed or encrypted: not read
    } else if (ver == 3 && fflags & 0x00C0 != 0) {
      continue;
    }
    try {
      if (id == 'USLT' || id == 'ULT') {
        final l = _uslt(data);
        if (!l.isEmpty) (l.synced ? synced : plain).add(l);
      } else if (id == 'SYLT' || id == 'SLT') {
        final l = _sylt(data);
        if (!l.isEmpty) synced.add(l);
      }
    } catch (_) {}
  }
  return [...synced, ...plain];
}

/// A string in [enc] from [b] starting at [at], up to its terminator: (text, where the next thing starts).
(String, int) _terminated(List<int> b, int at, int enc) {
  final wide = enc == 1 || enc == 2;
  var end = at;
  if (wide) {
    while (end + 1 < b.length && !(b[end] == 0 && b[end + 1] == 0)) {
      end += 2;
    }
    return (_text(b.sublist(at, end.clamp(at, b.length)), enc), (end + 2).clamp(0, b.length));
  }
  while (end < b.length && b[end] != 0) {
    end++;
  }
  return (_text(b.sublist(at, end), enc), (end + 1).clamp(0, b.length));
}

String _text(List<int> b, int enc) {
  switch (enc) {
    case 0:
      return latin1.decode(b);
    case 1:
    case 2:
      var le = enc == 1; // UTF-16 with a byte-order mark (little-endian when it says so), or UTF-16BE
      var from = 0;
      if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) {
        le = true;
        from = 2;
      } else if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
        le = false;
        from = 2;
      } else if (enc == 2) {
        le = false;
      }
      final units = <int>[
        for (var i = from; i + 1 < b.length; i += 2) le ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1],
      ];
      return String.fromCharCodes(units);
    default:
      return utf8.decode(b, allowMalformed: true);
  }
}

Lyrics _uslt(List<int> d) {
  if (d.length < 5) return const Lyrics();
  final enc = d[0];
  final (_, next) = _terminated(d, 4, enc); // after the language: a description
  final text = _text(d.sublist(next), enc).replaceAll('\u0000', '');
  return lyricsFromText(text);
}

/// SYLT: timed text, each piece with its time. Pieces starting with a new line begin a line; others (a word at
/// a time) are added to the line before.
Lyrics _sylt(List<int> d) {
  if (d.length < 7) return const Lyrics();
  final enc = d[0], format = d[4];
  if (format != 2) return const Lyrics(); // times in MPEG frames: can't be placed without decoding
  var (_, at) = _terminated(d, 6, enc);
  final pieces = <(String, int)>[];
  while (at < d.length) {
    final (text, next) = _terminated(d, at, enc);
    if (next + 4 > d.length) break;
    pieces.add((text, _be(d, next, 4)));
    at = next + 4;
  }
  if (pieces.isEmpty) return const Lyrics();
  final byLine = pieces.any((x) => x.$1.startsWith('\n') || x.$1.startsWith('\r'));
  final lines = <LyricLine>[];
  for (final (text, ms) in pieces) {
    final starts = !byLine || text.startsWith('\n') || text.startsWith('\r') || lines.isEmpty;
    final clean = text.replaceAll(RegExp(r'^[\r\n]+'), '');
    if (starts) {
      lines.add(LyricLine(Duration(milliseconds: ms), clean.trim()));
    } else {
      final last = lines.removeLast();
      lines.add(LyricLine(last.start, '${last.text}$clean'.trim()));
    }
  }
  lines.sort((a, b) => a.start!.compareTo(b.start!));
  return Lyrics(synced: true, lines: lines);
}

// ── Vorbis comments (FLAC, Ogg Vorbis / Opus) ──
/// The comment block of a FLAC file (its metadata blocks come right after "fLaC").
Future<List<int>?> _flacComments(RandomAccessFile raf) async {
  var pos = 4;
  for (var i = 0; i < 64; i++) {
    await raf.setPosition(pos);
    final h = await raf.read(4);
    if (h.length < 4) return null;
    final last = h[0] & 0x80 != 0, type = h[0] & 0x7F, len = _be(h, 1, 3);
    if (type == 4) return len > _maxRead ? null : await raf.read(len);
    if (last) return null;
    pos += 4 + len;
  }
  return null;
}

/// The comment packet of an Ogg stream (the second packet), put together from its pages.
Future<List<int>?> _oggComments(RandomAccessFile raf) async {
  await raf.setPosition(0);
  final packets = <List<int>>[];
  var cur = <int>[];
  var read = 0;
  while (packets.length < 2 && read < _maxRead) {
    final h = await raf.read(27);
    if (h.length < 27 || String.fromCharCodes(h.sublist(0, 4)) != 'OggS') return null;
    final segs = await raf.read(h[26]);
    final data = await raf.read(segs.fold<int>(0, (a, b) => a + b));
    read += 27 + segs.length + data.length;
    var o = 0;
    for (final s in segs) {
      cur.addAll(data.sublist(o, (o + s).clamp(0, data.length)));
      o += s;
      if (s < 255) {
        packets.add(cur);
        cur = <int>[];
        if (packets.length == 2) break;
      }
    }
  }
  if (packets.length < 2) return null;
  final c = packets[1];
  if (c.length > 7 && c[0] == 3 && String.fromCharCodes(c.sublist(1, 7)) == 'vorbis') return c.sublist(7);
  if (c.length > 8 && String.fromCharCodes(c.sublist(0, 8)) == 'OpusTags') return c.sublist(8);
  return null;
}

int _le(List<int> b, int at) => b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24);

/// The lyrics among a Vorbis comment block's "KEY=value" fields.
List<Lyrics> _comments(List<int>? b) {
  if (b == null || b.length < 8) return const [];
  try {
    var at = 4 + _le(b, 0); // the vendor string
    final n = _le(b, at);
    at += 4;
    final out = <Lyrics>[];
    for (var i = 0; i < n && at + 4 <= b.length; i++) {
      final len = _le(b, at);
      at += 4;
      if (at + len > b.length) break;
      final field = utf8.decode(b.sublist(at, at + len), allowMalformed: true);
      at += len;
      final eq = field.indexOf('=');
      if (eq < 0) continue;
      final key = field.substring(0, eq).toUpperCase().replaceAll(' ', '');
      if (key == 'LYRICS' || key == 'UNSYNCEDLYRICS' || key == 'SYNCEDLYRICS' || key == 'UNSYNCEDLYRIC') {
        final l = lyricsFromText(field.substring(eq + 1));
        if (!l.isEmpty) out.add(l);
      }
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// A .lrc file's text: UTF-8 (with or without a byte-order mark), UTF-16 with one, else Latin-1.
String _decode(List<int> b) {
  if (b.length >= 2 && ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF))) return _text(b, 1);
  if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) b = b.sublist(3);
  try {
    return utf8.decode(b);
  } catch (_) {
    return latin1.decode(b);
  }
}
