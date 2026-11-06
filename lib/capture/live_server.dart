import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Serves the web viewer and talks to it over a WebSocket.
///
/// Server to browser: one binary message per frame,
/// `[uint32 LE header length][header JSON][pad to even][int16 LE grid]`.
/// The grid holds temperatures in 0.1 °C, sensor orientation, row-delta
/// coded (first value of a row absolute, then differences to the left
/// neighbour) so it compresses well. Pixels without a value are filled from
/// their neighbour and listed nowhere; they are rare.
/// The browser colours and annotates the image itself, so it stays sharp at
/// any size.
///
/// Browser to server: JSON commands (`{"c": "ack"}` after each drawn frame,
/// plus remote-control commands handed to [onCommand]).
class LiveServer {
  LiveServer({this.port = 8080, required this.page});

  final int port;

  /// HTML of the web viewer.
  final Future<String> Function() page;

  /// File name and content of the current CSV log, or null if none.
  Future<(String, String)?> Function()? csvProvider;

  /// Called for every command except "ack". Returns an optional message
  /// shown to that viewer.
  Future<String?> Function(Map<String, dynamic> command)? onCommand;

  HttpServer? _server;
  final Set<LiveClient> _clients = <LiveClient>{};

  bool get running => _server != null;
  bool get hasViewers => _clients.isNotEmpty;
  int get viewerCount => _clients.length;
  Iterable<LiveClient> get clients => _clients;

  Future<void> start() async {
    if (_server != null) return;
    final HttpServer server = await HttpServer.bind(
      InternetAddress.anyIPv4,
      port,
      shared: true,
    );
    _server = server;
    server.listen(_handle, onError: (Object _) {});
  }

  Future<void> stop() async {
    for (final LiveClient c in _clients.toList()) {
      await c.close();
    }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
  }

  /// `http://WIFI-ADDRESS:PORT/`, or null when no network address exists.
  Future<String?> url() async {
    final List<NetworkInterface> interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    InternetAddress? pick;
    for (final NetworkInterface i in interfaces) {
      for (final InternetAddress a in i.addresses) {
        if (a.isLoopback) continue;
        if (i.name.startsWith('wlan')) return 'http://${a.address}:$port/';
        pick ??= a;
      }
    }
    return pick == null ? null : 'http://${pick.address}:$port/';
  }

  Future<void> _handle(HttpRequest request) async {
    final HttpResponse r = request.response;
    try {
      switch (request.uri.path) {
        case '/ws':
          if (!WebSocketTransformer.isUpgradeRequest(request)) {
            r.statusCode = HttpStatus.badRequest;
            await r.close();
            return;
          }
          // Compressed: the phone's Wi-Fi upload is the bottleneck, and the
          // row-delta temperature grid shrinks several times.
          final WebSocket socket = await WebSocketTransformer.upgrade(
            request,
            compression: CompressionOptions.compressionDefault,
          );
          final LiveClient client = LiveClient(socket);
          _clients.add(client);
          socket.listen(
            (dynamic data) => _onMessage(client, data),
            onDone: () => _clients.remove(client),
            onError: (Object _) => _clients.remove(client),
            cancelOnError: true,
          );
        case '/csv':
          final (String, String)? csv = await csvProvider?.call();
          if (csv == null) {
            r.statusCode = HttpStatus.notFound;
            r.write('No CSV log yet');
          } else {
            r.headers
              ..contentType = ContentType('text', 'csv', charset: 'utf-8')
              ..set(
                'Content-Disposition',
                'attachment; filename="${csv.$1}"',
              );
            r.write(csv.$2);
          }
          await r.close();
        case '/':
          r.headers
            ..contentType = ContentType.html
            ..set(HttpHeaders.cacheControlHeader, 'no-store');
          r.write(await page());
          await r.close();
        default:
          r.statusCode = HttpStatus.notFound;
          await r.close();
      }
    } catch (_) {
      try {
        await r.close();
      } catch (_) {}
    }
  }

  Future<void> _onMessage(LiveClient client, dynamic data) async {
    if (data is! String) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } catch (_) {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    if (decoded['c'] == 'ack') {
      if (client.inFlight > 0) client.inFlight--;
      return;
    }
    final String? message = await onCommand?.call(decoded);
    if (message != null) client.sendText(<String, Object>{'c': 'toast', 'msg': message});
  }
}

class LiveClient {
  LiveClient(this.socket);

  final WebSocket socket;

  /// Frames sent but not yet confirmed by the viewer.
  int inFlight = 0;

  /// Up to this many frames may travel at once, which hides the network
  /// round trip without letting a slow viewer pile up a backlog.
  static const int maxInFlight = 2;

  bool get ready => inFlight < maxInFlight;

  /// Palette the viewer already has, so its colour table is sent once.
  String? paletteSent;

  void sendFrame(Uint8List payload) {
    inFlight++;
    socket.add(payload);
  }

  void sendText(Map<String, Object> message) => socket.add(jsonEncode(message));

  Future<void> close() async {
    try {
      await socket.close();
    } catch (_) {}
  }
}

/// Converts a grid of temperatures in 1/50 °C (-32768 = no value) into
/// row-delta coded 0.1 °C values.
Int16List deltaEncodeTenths(Int16List fiftieths, int width) {
  final Int16List out = Int16List(fiftieths.length);
  for (int row = 0; row < fiftieths.length; row += width) {
    int previous = 0;
    for (int i = row; i < row + width; i++) {
      final int raw = fiftieths[i];
      final int v = raw == -32768 ? previous : (raw / 5).round();
      out[i] = i == row ? v : v - previous;
      previous = v;
    }
  }
  return out;
}

/// Packs header JSON and the temperature grid into one binary message.
Uint8List encodeFrame(Map<String, Object?> header, Int16List temps) {
  final Uint8List json = utf8.encode(jsonEncode(header));
  final int headerEnd = 4 + json.length;
  final int dataStart = headerEnd + (headerEnd.isOdd ? 1 : 0);
  final Uint8List out = Uint8List(dataStart + temps.lengthInBytes);
  ByteData.sublistView(out).setUint32(0, json.length, Endian.little);
  out.setRange(4, headerEnd, json);
  out.setRange(
    dataStart,
    out.length,
    temps.buffer.asUint8List(temps.offsetInBytes, temps.lengthInBytes),
  );
  return out;
}
