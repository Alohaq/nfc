import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc/src/epd/hex.dart';
import 'package:nfc/src/epd/lzo.dart';
import 'package:nfc/src/epd/protocol.dart';
import 'package:nfc/src/epd/transfer_plan.dart';
import 'package:nfc/src/image/palette.dart';
import 'package:nfc/src/image/quantizer.dart';

void main() {
  group('APDU construction', () {
    test('fixed APDUs match the reference byte strings', () {
      expect(Hex.of(Apdu.readInfo, sep: ''), '00D1000000');
      expect(Hex.of(Apdu.checkAccess, sep: ''), 'F0D8000005000000000E');
      expect(Hex.of(Apdu.readStatus, sep: ''), 'F0DE000001');
      expect(Hex.of(Apdu.clearStored, sep: ''), 'F0DB020000');
    });

    test('refresh sets P1 bit 7 and encodes the delay in 100ms units', () {
      expect(Hex.of(Apdu.refresh(powerOnDelayMs: 2000), sep: ''), 'F0D4948000');
      expect(Hex.of(Apdu.refresh(powerOnDelayMs: 100), sep: ''), 'F0D4818000');
      expect(Hex.of(Apdu.refresh(powerOnDelayMs: 12700), sep: ''), 'F0D4FF8000');
    });

    test('refresh rejects out-of-range delays', () {
      expect(() => Apdu.refresh(powerOnDelayMs: 50), throwsArgumentError);
      expect(() => Apdu.refresh(powerOnDelayMs: 20150), throwsArgumentError);
      expect(() => Apdu.refresh(powerOnDelayMs: 2050), throwsArgumentError);
    });

    test('PIN APDU is 00 20 00 01 05 plus five bytes', () {
      final apdu = Apdu.verifyPin(const [0x52, 0x65, 0x69, 0x99, 0x19]);
      expect(Hex.of(apdu, sep: ''), '0020000105' '5265699919');
      expect(apdu.length, 10);
      expect(() => Apdu.verifyPin(const [1, 2, 3]), throwsArgumentError);
    });

    test('image packet header layout', () {
      final chunk = Uint8List.fromList(List.generate(250, (i) => i & 0xFF));
      final first = Apdu.imagePacket(slot: 0, block: 7, sub: 0, lastInBlock: false, chunk: chunk);
      expect(first.length, 257);
      expect(first[0], 0xF0);
      expect(first[1], 0xD3);
      expect(first[2], 0); // slot
      expect(first[3], 0); // not last in block
      expect(first[4], 252); // 250 + 2
      expect(first[5], 7); // block
      expect(first[6], 0); // sub
      expect(first.sublist(7), chunk);

      final last = Apdu.imagePacket(slot: 1, block: 7, sub: 3, lastInBlock: true, chunk: chunk);
      expect(last[2], 1);
      expect(last[3], 1);
      expect(last[6], 3);
    });

    test('image packet rejects oversized chunks', () {
      expect(
        () => Apdu.imagePacket(
            slot: 0, block: 0, sub: 0, lastInBlock: true, chunk: Uint8List(254)),
        throwsArgumentError,
      );
    });
  });

  group('status words', () {
    test('known codes are described', () {
      expect(StatusWords.meaning(0x9000), '成功');
      expect(StatusWords.meaning(0x68CA), contains('低电压'));
      expect(StatusWords.meaning(0x6985), contains('PIN'));
      expect(StatusWords.meaning(0x1234), '');
    });

    test('requireOk throws with the status word in the message', () {
      final bad = ApduResponse(Uint8List(0), 0x68CA);
      expect(bad.isOk, isFalse);
      expect(
        () => bad.requireOk('D4'),
        throwsA(isA<FmscStatusException>()
            .having((e) => e.swHex, 'swHex', '68CA')
            .having((e) => e.toString(), 'message', contains('低电压'))),
      );
      expect(ApduResponse(Uint8List(0), 0x9000).requireOk('ok').isOk, isTrue);
    });
  });

  group('device info parsing', () {
    Uint8List tlv({int width = 552, int height = 768, int colors = 4, int c0 = 0x08}) {
      final bytes = BytesBuilder();
      void field(int tag, List<int> data) {
        bytes.add([tag, data.length]);
        bytes.add(data);
      }

      field(0xA0, [0x20, 0x03, 0x00, height >> 8, height & 0xFF, width >> 8, width & 0xFF]);
      field(0xB1, [colors]);
      field(0xB2, [7]);
      field(0xC0, [0, 0, 0, c0]);
      field(0xC1, [0x11, 0x22, 0x33, 0x44]);
      return bytes.toBytes();
    }

    test('parses a well-formed D1 response', () {
      final info = DeviceInfo.parse(ApduResponse(tlv(), 0x9000));
      expect(info.width, 552);
      expect(info.height, 768);
      expect(info.colors, 4);
      expect(info.supportsCompression, isTrue);
      expect(info.firmware, 7);
      expect(info.uidHex, '11 22 33 44');
      expect(info.isTargetPanel, isTrue);
    });

    test('applies the observed 552x1536/2-colour firmware correction', () {
      final info = DeviceInfo.parse(
          ApduResponse(tlv(width: 552, height: 1536, colors: 2), 0x9000));
      expect(info.height, 768);
      expect(info.colors, 4);
    });

    test('rejects a missing mandatory field', () {
      final only = BytesBuilder();
      only.add([0xA0, 7, 0x20, 0x03, 0x00, 0x03, 0x00, 0x02, 0x28]);
      expect(
        () => DeviceInfo.parse(ApduResponse(only.toBytes(), 0x9000)),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a truncated TLV', () {
      final truncated = Uint8List.fromList([0xA0, 7, 0x20, 0x03]);
      expect(
        () => DeviceInfo.parse(ApduResponse(truncated, 0x9000)),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('literal LZO', () {
    // Vectors produced with literal_lzo() from ink_nfc_fmsc/protocol.py.
    test('short form for <=238 bytes', () {
      final out = LzoLiteral.compress(Uint8List.fromList([0xAA]));
      expect(Hex.of(out, sep: ''), '12AA110000');

      final counter = Uint8List.fromList(List.generate(238, (i) => i & 0xFF));
      final packed = LzoLiteral.compress(counter);
      expect(packed.length, 242);
      expect(packed[0], 0xFF); // 17 + 238
      expect(Hex.of(packed.sublist(packed.length - 3), sep: ''), '110000');
    });

    test('long form crosses at 239 bytes', () {
      final counter = Uint8List.fromList(List.generate(239, (i) => i & 0xFF));
      final packed = LzoLiteral.compress(counter);
      expect(packed.length, 244);
      expect(packed[0], 0x00);
      expect(packed[1], 0xDD); // 239 - 18
    });

    test('2000-byte block uses repeated zero length escapes', () {
      final zeros = Uint8List(2000);
      final packed = LzoLiteral.compress(zeros);
      expect(packed.length, 2012);
      // header 8 zero bytes then 0xC5 remainder, as the reference emits.
      expect(packed.sublist(0, 8), everyElement(0));
      expect(packed[8], 0xC5);
    });

    test('rejects empty and oversized blocks', () {
      expect(() => LzoLiteral.compress(Uint8List(0)), throwsArgumentError);
      expect(() => LzoLiteral.compress(Uint8List(2001)), throwsArgumentError);
    });
  });

  group('transfer plan', () {
    test('a flat frame yields 53 blocks and the expected packet count', () {
      final packed = Uint8List(TransferPlan.frameBytes); // all zeros
      final plan = TransferPlan.build(packed);
      expect(plan.blockCount, 53);
      // 2000 raw bytes -> 2012 compressed -> ceil(2012/250) = 9 packets/block
      // except the final 1984-byte block (1996 compressed -> 8 packets).
      expect(plan.packetCount, 52 * 9 + 8);
      expect(plan.packets.first.block, 0);
      expect(plan.packets.first.sub, 0);
      expect(plan.packets.first.lastInBlock, isFalse);
      expect(plan.packets[8].lastInBlock, isTrue);
      expect(plan.packets.last.block, 52);
      expect(plan.packets.last.lastInBlock, isTrue);

      final rebuilt = plan.packets.expand((p) => p.apdu.sublist(7)).toList();
      expect(rebuilt.length, plan.compressedBytes);
    });

    test('rejects a wrong frame size', () {
      expect(() => TransferPlan.build(Uint8List(1000)), throwsArgumentError);
      expect(() => TransferPlan.build(Uint8List(TransferPlan.frameBytes + 1)),
          throwsArgumentError);
    });

    test('fingerprint is stable and depends on content', () {
      final a = TransferPlan.build(Uint8List(TransferPlan.frameBytes));
      final b = TransferPlan.build(Uint8List(TransferPlan.frameBytes));
      expect(a.fingerprint, b.fingerprint);
      final changed = Uint8List(TransferPlan.frameBytes)..[0] = 0xFF;
      expect(TransferPlan.build(changed).fingerprint, isNot(a.fingerprint));
    });
  });

  group('packing', () {
    test('column-major, right-to-left, bottom-to-top', () {
      final codes = Uint8List(FrameGeometry.pixels);
      // Put distinct codes in the bottom four pixels of the last column,
      // which must land in the two highest bytes of the first output byte.
      const w = FrameGeometry.width;
      const h = FrameGeometry.height;
      codes[(h - 1) * w + (w - 1)] = 1;
      codes[(h - 2) * w + (w - 1)] = 2;
      codes[(h - 3) * w + (w - 1)] = 3;
      codes[(h - 4) * w + (w - 1)] = 0;
      final packed = pack2bpp(codes);
      expect(packed.length, FrameGeometry.packedBytes);
      // lowest pixel (y=h-1) -> bits 7..6 = 01, next -> 10, next -> 11, top -> 00
      expect(packed[0], 0x40 | 0x20 | 0x0C);
    });

    test('rejects wrong input size and out-of-range codes', () {
      expect(() => pack2bpp(Uint8List(10)), throwsArgumentError);
      final bad = Uint8List(FrameGeometry.pixels)..[0] = 4;
      expect(() => pack2bpp(bad), throwsArgumentError);
    });
  });

  group('quantisation', () {
    test('nearest maps exact palette colours back to their codes', () {
      final rgb = Uint8List(FrameGeometry.pixels * 3);
      for (var i = 0; i < FrameGeometry.pixels; i++) {
        final c = Palette.fourColor[i % 4];
        rgb[i * 3] = c.r;
        rgb[i * 3 + 1] = c.g;
        rgb[i * 3 + 2] = c.b;
      }
      final codes = Quantizer.nearest(rgb, Palette.fourColor);
      for (var i = 0; i < FrameGeometry.pixels; i++) {
        expect(codes[i], i % 4);
      }
    });

    test('all-white input yields only white codes with Atkinson', () {
      final rgb = Uint8List(FrameGeometry.pixels * 3)..fillRange(0, FrameGeometry.pixels * 3, 255);
      final codes = Quantizer.atkinson(rgb, Palette.fourColor);
      expect(codes.every((c) => c == 1), isTrue);
    });

    test('all-black input yields only black codes with Atkinson', () {
      final rgb = Uint8List(FrameGeometry.pixels * 3);
      final codes = Quantizer.atkinson(rgb, Palette.fourColor);
      expect(codes.every((c) => c == 0), isTrue);
    });

    test('monochrome palette never emits colour codes', () {
      final rgb = Uint8List(FrameGeometry.pixels * 3);
      for (var i = 0; i < FrameGeometry.pixels * 3; i++) {
        rgb[i] = (i * 7) & 0xFF;
      }
      final codes = Quantizer.atkinson(rgb, Palette.mono);
      expect(codes.every((c) => c < 2), isTrue);
    });

    test('rejects malformed RGB buffers', () {
      expect(() => Quantizer.atkinson(Uint8List(100), Palette.fourColor),
          throwsArgumentError);
    });
  });
}
