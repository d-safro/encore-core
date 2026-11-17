import 'dart:async';
import 'dart:io';
import 'dart:math';

/// The server answered with something other than the song (404, 500, ...). [permanent]: trying again
/// won't help (the song is gone, or the request is refused).
class DownloadFailed implements Exception {
  DownloadFailed(this.status);
  final int status;
  bool get permanent => status == 400 || status == 401 || status == 403 || status == 404 || status == 410;
  @override
  String toString() => 'DownloadFailed($status)';
}

/// The download was called off (the song was removed, the server or the network changed).
class DownloadCancelled implements Exception {
  @override
  String toString() => 'DownloadCancelled';
}

/// Downloads [url] into [dest]. What has arrived so far is kept in `<dest>.part`, so a download that stops
/// part-way (no signal, the app closed, the phone restarted) carries on from the byte it reached next time.
///
/// Asks the server for only the missing bytes. A server that sends the whole file anyway (Navidrome does
/// for a song it hasn't converted to Opus yet: it converts while it sends) is checked against what's on the
/// phone: the matching start is skipped and the rest appended. Converting gives the same bytes every time;
/// if they ever differ, the file is kept up to where they match and rewritten from there.
///
/// [onProgress] gets (bytes on the phone, total bytes or null when the server doesn't say).
/// [cancelled] is checked as data arrives; true stops the download (the `.part` stays).
/// Throws [DownloadFailed], [DownloadCancelled], or a network error; the `.part` stays for next time,
/// except for a permanent failure.
Future<File> resumableDownload(
  HttpClient http,
  Uri url,
  File dest, {
  void Function(int got, int? total)? onProgress,
  bool Function()? cancelled,
  Duration idle = const Duration(seconds: 60),
}) async {
  final part = File('${dest.path}.part');
  await part.parent.create(recursive: true);
  final have = await part.exists() ? await part.length() : 0;

  final req = await http.getUrl(url);
  if (have > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
  final res = await req.close();

  if (res.statusCode == HttpStatus.requestedRangeNotSatisfiable && have > 0) {
    // asked for bytes past the end: the .part already holds the whole file
    final total = _rangeTotal(res.headers.value(HttpHeaders.contentRangeHeader));
    await res.drain<void>().catchError((_) {});
    if (total == null || total == have) return _finish(part, dest);
    await part.delete(); // it holds more than the file: start over
    return resumableDownload(http, url, dest, onProgress: onProgress, cancelled: cancelled, idle: idle);
  }
  if (res.statusCode != HttpStatus.ok && res.statusCode != HttpStatus.partialContent) {
    await res.drain<void>().catchError((_) {});
    final e = DownloadFailed(res.statusCode);
    if (e.permanent) await _delete(part);
    throw e;
  }

  var pos = 0; // where the next byte from the server goes in the .part
  var checkUntil = 0; // bytes already on the phone that the server is sending again
  int? total;
  if (res.statusCode == HttpStatus.partialContent) {
    final start = _rangeStart(res.headers.value(HttpHeaders.contentRangeHeader));
    if (start != have) {
      // not the range we asked for: start over cleanly
      await res.drain<void>().catchError((_) {});
      await _delete(part);
      return resumableDownload(http, url, dest, onProgress: onProgress, cancelled: cancelled, idle: idle);
    }
    pos = have;
    total = _rangeTotal(res.headers.value(HttpHeaders.contentRangeHeader));
  } else {
    checkUntil = have;
    if (res.contentLength >= 0) total = res.contentLength;
  }

  final raf = await part.open(mode: FileMode.append); // read and write; keeps what's there
  try {
    await raf.setPosition(pos);
    onProgress?.call(max(pos, checkUntil), total);
    await for (final chunk in res.timeout(idle)) {
      if (cancelled?.call() ?? false) throw DownloadCancelled();
      var off = 0;
      if (pos < checkUntil) {
        final n = min(chunk.length, checkUntil - pos);
        await raf.setPosition(pos);
        final old = await raf.read(n);
        var same = 0;
        while (same < old.length && old[same] == chunk[same]) {
          same++;
        }
        pos += same;
        off = same;
        if (same < n) {
          await raf.truncate(pos); // differs from here on: keep the matching start, rewrite the rest
          checkUntil = pos;
        }
        await raf.setPosition(pos);
        if (off == chunk.length) {
          onProgress?.call(max(pos, checkUntil), total);
          continue;
        }
      }
      await raf.writeFrom(chunk, off);
      pos += chunk.length - off;
      onProgress?.call(max(pos, checkUntil), total);
    }
    if (pos < checkUntil) await raf.truncate(pos); // the server's file is shorter than what was kept
    await raf.flush();
  } finally {
    await raf.close();
  }
  if (total != null && pos != total) throw const HttpException('Connection closed before the whole file arrived');
  return _finish(part, dest);
}

Future<File> _finish(File part, File dest) async {
  if (await dest.exists()) await dest.delete();
  return part.rename(dest.path);
}

Future<void> _delete(File f) async {
  try {
    await f.delete();
  } catch (_) {}
}

/// "bytes 500-999/1000" -> 500
int? _rangeStart(String? h) => int.tryParse(RegExp(r'bytes\s+(\d+)-').firstMatch(h ?? '')?.group(1) ?? '');

/// "bytes 500-999/1000" or "bytes */1000" -> 1000
int? _rangeTotal(String? h) => int.tryParse(RegExp(r'/(\d+)\s*$').firstMatch(h ?? '')?.group(1) ?? '');
