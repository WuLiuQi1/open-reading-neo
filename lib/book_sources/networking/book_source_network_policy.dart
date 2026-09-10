import 'dart:io';

import '../protocol/book_source_protocol.dart';

typedef BookSourceAddressLookup =
    Future<List<InternetAddress>> Function(String host);

class BookSourceNetworkPolicy {
  const BookSourceNetworkPolicy({
    BookSourceAddressLookup? lookup,
    this.allowPrivateNetwork,
    this.allowSyntheticDns = false,
  }) : _lookup = lookup ?? InternetAddress.lookup;

  /// Live opt-in used when [allowPrivateNetwork] is omitted.
  /// Default stays off so third-party source rules cannot reach the LAN.
  static bool preferredPrivateNetwork = false;

  final BookSourceAddressLookup _lookup;

  /// `null` follows [preferredPrivateNetwork]; an explicit value is for tests
  /// and callers that must pin the decision.
  final bool? allowPrivateNetwork;
  final bool allowSyntheticDns;

  bool get allowsPrivateNetwork =>
      allowPrivateNetwork ?? preferredPrivateNetwork;

  Future<void> validate(Uri uri) async {
    await resolve(uri);
  }

  Future<List<InternetAddress>> resolve(Uri uri) async {
    if (!uri.hasAuthority || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const BookSourceProtocolException(
        'Book source targets must use HTTP or HTTPS.',
      );
    }
    final literal = InternetAddress.tryParse(uri.host);
    final addresses = literal == null ? await _lookup(uri.host) : [literal];
    if (addresses.isEmpty ||
        addresses.any(
          (address) => isDisallowedAddress(
            address,
            allowPrivateNetwork: allowsPrivateNetwork,
            allowSyntheticDns: allowSyntheticDns,
          ),
        )) {
      throw const BookSourceProtocolException(
        'This address is not allowed as a book source target.',
      );
    }
    return addresses;
  }

  HttpClient createPinnedHttpClient({SecurityContext? securityContext}) {
    final client = HttpClient(context: securityContext);
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final targetHost = proxyHost ?? uri.host;
      final targetPort = proxyPort ?? uri.port;
      final targetUri = proxyHost == null
          ? uri
          : Uri(scheme: 'http', host: targetHost, port: targetPort);
      final addresses = await resolve(targetUri);
      // Prefer IPv4 on mobile networks, then fall back through every validated
      // address. Pinning only the first DNS answer made a single unreachable
      // IPv6/CDN node fail the whole source, unlike OkHttp's address fallback.
      final ordered = [
        ...addresses.where(
          (address) => address.type == InternetAddressType.IPv4,
        ),
        ...addresses.where(
          (address) => address.type == InternetAddressType.IPv6,
        ),
      ];
      ConnectionTask<Socket>? activeTask;
      Socket? activeSocket;
      var cancelled = false;
      final socket = () async {
        Object? lastError;
        for (final address in ordered) {
          if (cancelled) {
            throw const SocketException('Connection attempt was cancelled.');
          }
          try {
            activeTask = await Socket.startConnect(address, targetPort);
            final connected = await activeTask!.socket.timeout(
              const Duration(seconds: 3),
              onTimeout: () {
                activeTask?.cancel();
                throw SocketException(
                  'Timed out connecting to ${address.address}:$targetPort.',
                );
              },
            );
            activeSocket = connected;
            if (cancelled) {
              connected.destroy();
              throw const SocketException('Connection attempt was cancelled.');
            }
            if (proxyHost != null || uri.scheme != 'https') {
              return connected;
            }
            final secure =
                await SecureSocket.secure(
                  connected,
                  host: uri.host,
                  context: securityContext,
                ).timeout(
                  const Duration(seconds: 3),
                  onTimeout: () {
                    connected.destroy();
                    throw SocketException(
                      'Timed out negotiating TLS with ${uri.host}:$targetPort.',
                    );
                  },
                );
            activeSocket = secure;
            if (cancelled) {
              secure.destroy();
              throw const SocketException('Connection attempt was cancelled.');
            }
            return secure;
          } on TlsException {
            activeSocket?.destroy();
            activeSocket = null;
            rethrow;
          } on Object catch (error) {
            activeSocket?.destroy();
            activeSocket = null;
            lastError = error;
          }
        }
        if (lastError is SocketException) throw lastError;
        throw SocketException(
          'Could not connect to any validated address for $targetHost.',
        );
      }();
      return ConnectionTask.fromSocket(socket, () {
        cancelled = true;
        activeTask?.cancel();
        activeSocket?.destroy();
      });
    };
    return client;
  }

  static bool isDisallowedAddress(
    InternetAddress address, {
    bool? allowPrivateNetwork,
    bool allowSyntheticDns = false,
  }) {
    if (_isAlwaysBlockedAddress(address)) return true;
    final allowPrivate = allowPrivateNetwork ?? preferredPrivateNetwork;
    if (allowPrivate) return false;
    return isBlockedAddress(address, allowSyntheticDns: allowSyntheticDns);
  }

  static bool isBlockedAddress(
    InternetAddress address, {
    bool allowSyntheticDns = false,
  }) {
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return true;
    }

    final bytes = address.rawAddress;
    if (bytes.length == 4) {
      return _isBlockedIpv4(bytes, allowSyntheticDns: allowSyntheticDns);
    }
    if (bytes.length != 16) return true;

    // IPv4-mapped IPv6 addresses must inherit the IPv4 restrictions.
    if (_isIpv4Mapped(bytes)) {
      return _isBlockedIpv4(
        bytes.sublist(12),
        allowSyntheticDns: allowSyntheticDns,
      );
    }

    // Unspecified, loopback, and unique-local (fc00::/7) addresses. Mihomo's
    // documented fdfe:dcba:9876::/64 Fake-IP pool is allowed only through the
    // same explicit synthetic-DNS opt-in as 198.18.0.0/15.
    if (bytes.every((byte) => byte == 0) ||
        (bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1) ||
        ((bytes[0] & 0xfe) == 0xfc &&
            !(allowSyntheticDns && _isMihomoSyntheticIpv6(bytes)))) {
      return true;
    }
    return false;
  }

  static bool isSyntheticDnsAddress(InternetAddress address) {
    final bytes = address.rawAddress;
    if (bytes.length == 4) return _isSyntheticIpv4(bytes);
    if (bytes.length != 16) return false;
    return _isMihomoSyntheticIpv6(bytes) ||
        (_isIpv4Mapped(bytes) && _isSyntheticIpv4(bytes.sublist(12)));
  }

  static bool _isIpv4Mapped(List<int> bytes) =>
      bytes.length == 16 &&
      bytes.take(10).every((byte) => byte == 0) &&
      bytes[10] == 0xff &&
      bytes[11] == 0xff;

  static bool _isSyntheticIpv4(List<int> bytes) =>
      bytes.length == 4 &&
      bytes[0] == 198 &&
      (bytes[1] == 18 || bytes[1] == 19);

  static bool _isMihomoSyntheticIpv6(List<int> bytes) =>
      bytes.length == 16 &&
      bytes[0] == 0xfd &&
      bytes[1] == 0xfe &&
      bytes[2] == 0xdc &&
      bytes[3] == 0xba &&
      bytes[4] == 0x98 &&
      bytes[5] == 0x76 &&
      bytes[6] == 0 &&
      bytes[7] == 0;

  static bool _isAlwaysBlockedAddress(InternetAddress address) {
    if (address.isMulticast) return true;
    final bytes = address.rawAddress;
    if (bytes.every((byte) => byte == 0)) return true;
    return bytes.length == 4 && bytes[0] >= 224;
  }

  static bool _isBlockedIpv4(
    List<int> bytes, {
    bool allowSyntheticDns = false,
  }) {
    final first = bytes[0];
    final second = bytes[1];
    return first == 0 ||
        first == 10 ||
        first == 127 ||
        (first == 100 && (second & 0xc0) == 0x40) ||
        (first == 169 && second == 254) ||
        (first == 172 && (second & 0xf0) == 16) ||
        (first == 192 && second == 168) ||
        (!allowSyntheticDns &&
            first == 198 &&
            (second == 18 || second == 19)) ||
        first >= 224;
  }

  static Uri redirectTarget(Uri current, String? location) {
    if (location == null || location.trim().isEmpty) {
      throw const BookSourceProtocolException(
        'Book source redirect is missing its target.',
      );
    }
    final target = current.resolve(location.trim());
    if (target.scheme != 'http' && target.scheme != 'https') {
      throw const BookSourceProtocolException(
        'Book source redirects must use HTTP or HTTPS.',
      );
    }
    if (current.scheme == 'https' && target.scheme == 'http') {
      throw const BookSourceProtocolException(
        'Book source redirects cannot downgrade HTTPS to HTTP.',
      );
    }
    return target;
  }
}
