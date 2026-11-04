import 'dart:typed_data';

import '../epd/protocol.dart';

/// Why a transport could not be opened, in terms the UI can explain.
enum LinkErrorKind {
  unavailable,
  disabled,

  /// iOS: the tag never surfaced because Core NFC's mandatory SELECT AID
  /// step did not succeed. This is the expected failure for FMSC panels.
  iosAidSelectFailed,

  /// The tag does not expose ISO-DEP (SAK bit 5 clear), so APDUs are impossible.
  notIsoDep,

  timedOut,
  tagLost,
  cancelled,
  other,
}

class LinkException implements Exception {
  LinkException(this.kind, this.message, [this.cause]);
  final LinkErrorKind kind;
  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

/// Raw APDU channel to the panel.
///
/// Deliberately dumb: no retries, no framing knowledge, no state machine. The
/// orchestrator owns the application flow so both platforms behave identically.
abstract class TagLink {
  /// Human-readable transport name for the log header.
  String get name;

  /// Sends one APDU and returns payload + status word.
  Future<ApduResponse> transceive(Uint8List apdu);

  /// Closes the session (and, on iOS, dismisses the system sheet).
  Future<void> close({String? alertMessage, String? errorMessage});

  /// Whether this transport can send 7-bit short frames (REQA/WUPA/private
  /// wake codes). Phones cannot, so this is always false; PN532 bridges set it.
  bool get canSendShortFrames => false;
}
