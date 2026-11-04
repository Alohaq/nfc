import 'dart:typed_data';

import 'hex.dart';
import 'lzo.dart';
import 'protocol.dart';

/// One ready-to-send D3 sub-packet plus its bookkeeping.
class TransferPacket {
  const TransferPacket({
    required this.apdu,
    required this.block,
    required this.sub,
    required this.lastInBlock,
  });

  final Uint8List apdu;
  final int block;
  final int sub;
  final bool lastInBlock;

  String get label => 'D3 block $block/$_blockCountLabel packet $sub';

  String get _blockCountLabel => lastInBlock ? 'last' : '-';
}

/// A complete, immutable upload plan for one refresh.
class TransferPlan {
  TransferPlan({
    required this.packets,
    required this.packedBytes,
    required this.compressedBytes,
    required this.blockCount,
  });

  final List<TransferPacket> packets;

  /// SHA-256-sized summary is overkill on device; we keep the packed length and
  /// a cheap FNV-1a fingerprint so a stale plan cannot be sent by accident.
  final Uint8List packedBytes;
  final int compressedBytes;
  final int blockCount;

  int get packetCount => packets.length;

  /// FNV-1a 32-bit fingerprint of the packed frame (displayed in the log).
  String get fingerprint {
    var h = 0x811C9DC5;
    for (final b in packedBytes) {
      h ^= b;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0').toUpperCase();
  }

  /// Builds the plan for a 105984-byte packed 2bpp frame.
  ///
  /// Layout rules taken from the reference implementations:
  ///   * 2000 raw bytes per LZO block -> 53 blocks for 105984 bytes
  ///   * each compressed block is split into 250-byte sub-packets
  ///   * `last` is set on the final sub-packet *of every block*
  static TransferPlan build(Uint8List packed, {int slot = 0}) {
    if (packed.length != frameBytes) {
      throw ArgumentError.value(
          packed.length, 'packed', 'frame must be exactly $frameBytes bytes');
    }
    final blocks = LzoLiteral.compressBlocks(packed);
    if (blocks.length > 256) {
      throw StateError('too many blocks: ${blocks.length}');
    }
    final packets = <TransferPacket>[];
    var compressedTotal = 0;
    for (var b = 0; b < blocks.length; b++) {
      final data = blocks[b];
      compressedTotal += data.length;
      final chunks = <Uint8List>[];
      for (var off = 0; off < data.length; off += strideBytes) {
        final end = (off + strideBytes < data.length) ? off + strideBytes : data.length;
        chunks.add(Uint8List.sublistView(data, off, end));
      }
      for (var s = 0; s < chunks.length; s++) {
        final last = s == chunks.length - 1;
        packets.add(TransferPacket(
          apdu: Apdu.imagePacket(
              slot: slot, block: b, sub: s, lastInBlock: last, chunk: chunks[s]),
          block: b,
          sub: s,
          lastInBlock: last,
        ));
      }
    }
    return TransferPlan(
      packets: List.unmodifiable(packets),
      packedBytes: packed,
      compressedBytes: compressedTotal,
      blockCount: blocks.length,
    );
  }

  /// 552 * 768 pixels at 2 bits per pixel.
  static const int frameBytes = 105984;

  /// Device application stride: fixed at 250 bytes, must not change.
  static const int strideBytes = 250;

  /// Raw bytes fed to LZO per block.
  static const int rawBlockBytes = LzoLiteral.maxBlockBytes;

  String summary() => '${packets.length} packets, $blockCount blocks, '
      '$compressedBytes compressed bytes, fp=$fingerprint';

  /// First N packet hex dumps, for the diagnostic log.
  List<String> headHex([int n = 3]) => packets
      .take(n)
      .map((p) => 'b${p.block}s${p.sub} ${Hex.of(p.apdu, sep: '')}')
      .toList(growable: false);
}
