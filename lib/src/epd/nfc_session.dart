import 'dart:async';
import 'dart:typed_data';

import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';
import 'package:nfc_manager/nfc_manager_ios.dart';

import 'protocol.dart';
import 'tag_link.dart';

/// One NFC discovery session bound to a single tag.
///
/// Both platforms surface a tag through [NfcManager.startSession]; the concrete
/// [TagLink] chosen inside depends on which tag type came back.
class NfcSession {
  NfcSession._(this.link, this.rawTag);

  final TagLink link;
  final NfcTag rawTag;

  /// True when the discovered tag was handed to us as an ISO-DEP / ISO 7816 tag
  /// rather than as a bare NfcA tag.
  bool get isIsoDep => link is IsoDepLink || link is Iso7816Link;

  static Future<bool> isAvailable() async {
    final availability = await NfcManager.instance.checkAvailability();
    return availability == NfcAvailability.enabled;
  }

  /// Starts a session and completes with the first tag that can carry APDUs.
  ///
  /// [onRejected] is invoked when a tag is found but cannot be used, so the UI
  /// can explain the failure instead of just hanging.
  static Future<NfcSession> start({
    required String alertMessage,
    void Function(LinkException reason)? onRejected,
    Duration timeout = const Duration(seconds: 60),
  }) {
    final completer = Completer<NfcSession>();

    void finish(NfcSession session) {
      if (!completer.isCompleted) completer.complete(session);
    }

    void fail(LinkException error) {
      if (!completer.isCompleted) completer.completeError(error);
    }

    NfcManager.instance.startSession(
      pollingOptions: const {NfcPollingOption.iso14443},
      alertMessageIos: alertMessage,
      // Keep the session alive: upload takes tens of seconds.
      invalidateAfterFirstReadIos: false,
      onDiscovered: (tag) async {
        if (completer.isCompleted) return;
        final link = _linkFor(tag);
        if (link == null) {
          final failure = LinkException(
            LinkErrorKind.notIsoDep,
            'Tag found but it does not expose ISO-DEP, so APDUs cannot be sent.',
          );
          onRejected?.call(failure);
          // Keep listening: the user may present a different tag.
          return;
        }
        try {
          await NfcManager.instance.stopSession();
        } catch (_) {
          // Ignore: some platforms reject a stop before any command is sent.
        }
        finish(NfcSession._(link, tag));
      },
      onSessionErrorIos: (error) {
        fail(LinkException(LinkErrorKind.other, 'NFC session error: $error'));
      },
    ).catchError((Object e) {
      fail(LinkException(LinkErrorKind.other, 'Could not start NFC session: $e', e));
    });

    // A session that never reports a tag would otherwise wait forever.
    Future<void>.delayed(timeout).then((_) {
      if (!completer.isCompleted) {
        fail(LinkException(
          LinkErrorKind.timedOut,
          'No usable tag found within ${timeout.inSeconds} s.',
        ));
        NfcManager.instance.stopSession(errorMessageIos: 'No tag found').catchError((_) {});
      }
    });

    return completer.future;
  }

  static TagLink? _linkFor(NfcTag tag) {
    final isoDep = IsoDepAndroid.from(tag);
    if (isoDep != null) return IsoDepLink(isoDep);

    final iso7816 = Iso7816Ios.from(tag);
    if (iso7816 != null) return Iso7816Link(iso7816);

    // A bare NfcA tag exists (e.g. panel not yet in ISO-DEP state). We surface
    // it so the UI can tell the user to place the phone differently, but there
    // is no APDU path on it.
    return null;
  }
}

/// Android: transactions go straight through IsoDep, which lets us send any
/// APDU we like, including 00 D1, F0 D3 and F0 D4.
class IsoDepLink implements TagLink {
  IsoDepLink(this._tag);

  final IsoDepAndroid _tag;
  bool _closed = false;

  @override
  String get name => 'Android IsoDep';

  @override
  bool get canSendShortFrames => false;

  @override
  Future<ApduResponse> transceive(Uint8List apdu) async {
    if (_closed) {
      throw LinkException(LinkErrorKind.tagLost, 'Tag session already closed.');
    }
    final Uint8List response;
    try {
      response = await _tag.transceive(apdu);
    } catch (e) {
      throw LinkException(LinkErrorKind.tagLost, 'IsoDep transceive failed: $e', e);
    }
    return _split(response);
  }

  @override
  Future<void> close({String? alertMessage, String? errorMessage}) async {
    _closed = true;
  }
}

/// iOS: Core NFC hands us an ISO 7816 tag only after its own SELECT AID step
/// succeeded, which is why FMSC panels usually never appear here.
class Iso7816Link implements TagLink {
  Iso7816Link(this._tag);

  final Iso7816Ios _tag;
  bool _closed = false;

  @override
  String get name => 'iOS ISO 7816 (AID=${_tag.initialSelectedAID})';

  @override
  bool get canSendShortFrames => false;

  @override
  Future<ApduResponse> transceive(Uint8List apdu) async {
    if (_closed) {
      throw LinkException(LinkErrorKind.tagLost, 'Tag session already closed.');
    }
    final Iso7816ResponseApduIos response;
    try {
      response = await _tag.sendCommandRaw(data: apdu);
    } catch (e) {
      throw LinkException(LinkErrorKind.tagLost, 'ISO 7816 sendCommand failed: $e', e);
    }
    final payload = Uint8List.fromList(response.payload);
    final sw = (response.statusWord1 << 8) | response.statusWord2;
    return ApduResponse(payload, sw);
  }

  @override
  Future<void> close({String? alertMessage, String? errorMessage}) async {
    _closed = true;
  }
}

/// Splits a raw response into payload and the trailing status word.
ApduResponse _split(Uint8List raw) {
  if (raw.length < 2) {
    throw LinkException(
      LinkErrorKind.other,
      'Response too short to contain a status word (${raw.length} bytes).',
    );
  }
  final payload = Uint8List.sublistView(raw, 0, raw.length - 2);
  final sw = (raw[raw.length - 2] << 8) | raw[raw.length - 1];
  return ApduResponse(Uint8List.fromList(payload), sw);
}
