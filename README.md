# ink panel writer (Flutter)

NFC writer for FMSC-based 552×768 four-colour ink panels (Huawei phone-case
panels, Good Display modules). The wire protocol is ported byte-for-byte from
[solar2ain/ink-nfc-fmsc-by-pn532](https://github.com/solar2ain/ink-nfc-fmsc-by-pn532)
(GPL-3.0) and [kur0neko/huawei-epd-pn532](https://gitee.com/kur0neko/huawei-epd-pn532)
(PolyForm Noncommercial).

---

## Read this before you flash a panel

**On iPhone this app will most likely never see the panel at all.** That is not
a bug in this code, it is how Core NFC works:

* Core NFC sends `SELECT AID` for each identifier in
  `com.apple.developer.nfc.readersession.iso7816.select-identifiers` and only
  hands you an `NFCISO7816Tag` **after one succeeds**. An FMSC panel has no
  ISO 7816 application directory and answers `6D00`/`6A82` to `00 A4 04 00`,
  so no tag object is ever delivered.
* Neither iOS nor Android can emit 7-bit short frames (`26` / `52` / `7A` /
  `7D`), so the private wake code some Huawei boards need is unreachable from a
  phone radio.
* The panel is powered by the reader field. Phones have small coils; a PN532
  board struggles with these panels too (see issue #2 upstream: upload
  succeeds, `DE` then returns `68CA` low voltage).

What this app *is* good for:

| Platform | Reality |
|---|---|
| Android | Can send arbitrary APDUs over IsoDep. Works for panels that appear in ISO-DEP without a private wake code. |
| iOS | Only if the panel exposes a selectable AID. Use the **Probe** tab to find out in one shot. |
| PN532 / PCR532 bridge | The protocol layer is reusable as-is; see "Porting" below. |

---

## Build in the cloud

The repo has no Gradle project yet — only `ios/`. The workflow builds what
exists:

```bash
git init && git add . && git commit -m "initial"
git remote add origin https://github.com/<you>/<repo>.git
git push -u origin main
```

`.github/workflows/build.yml` then runs `flutter analyze`, `flutter test` and an
unsigned `flutter build ios --no-codesign` on `macos-latest`. The `.app` lands in
the `ios-unsigned` artifact.

To install on a real iPhone you need signing, which CI cannot do for you:

1. Open `ios/Runner.xcworkspace` in Xcode.
2. Select the Runner target → *Signing & Capabilities* → set your Team.
3. Change the bundle id from `com.example.nfc` to something you own.
4. The `NFC Tag Reading` capability must stay enabled — it comes from
   `ios/Runner/Runner.entitlements`, which is already wired into all three
   build configurations.
5. Free Apple IDs cannot use the NFC entitlement; you need a paid developer
   account.

## Run locally

```bash
flutter pub get
flutter analyze
flutter test          # 26 protocol/packing tests, no hardware needed
flutter run           # needs a device with NFC
```

---

## Using it

**Probe tab** — the only thing worth trying first.

Tap `Probe`. If the sheet reports "No usable tag found" and the log shows
nothing, Core NFC never got past `SELECT AID`: stop here. If you get a tag,
the app runs `00 D1` then `F0 D8` and prints the TLV fields and status words.

You can also hand-send any APDU. The three useful ones:

```
00D1000000                        read info (safe)
F0D800000005000000000E           access rights (safe)
F0DE000001                        busy status (safe)
```

**Write tab**

1. Pick an image. Preview is the actual quantised 2bpp result.
2. Adjust: dither (Atkinson / Floyd–Steinberg / off), black-and-white,
   contain/cover, rotation, brightness, contrast, scale.
3. `Upload & refresh`. Expect ~56 packets of 250 bytes each, then `D4`, then
   `DE` polling every 500 ms.

Defaults follow the reference tool: PIN `5265699919`, power-on wait 2000 ms,
refresh budget 60 s.

### What "success" means here

The app only reports a confirmed refresh after `DE` returns idle **and** busy
was observed at least once during the cycle. If `DE` only ever returns `00`,
the log says *refresh unconfirmed* — the panel may not have run at all. This
mirrors `epd_writer.py`, which treats `DE=00` as "state report, not proof".

Failures never auto-retry. A `68CA` is a low-voltage warning: move the phone,
wait, or get a reader with a bigger coil.

---

## Protocol notes

| Step | APDU / frame | Notes |
|---|---|---|
| wake | `7A` / `26`, `52` | 7-bit short frame — **phones cannot send this** |
| info | `00 D1 00 00 00` | TLV: A0 geometry, B1 colours, B2 fw, C0 flags, C1 uid |
| access | `F0 D8 00 00 05 00 00 00 00 0E` | `6985` means a PIN is needed |
| auth | `00 20 00 01 05` + 5 bytes | then re-read `D8` |
| upload | `F0 D3 slot last len block sub` + ≤250 bytes | 2000-byte blocks, LZO |
| refresh | `F0 D4 94 80 00` | P1 bit7 skips detection, low bits = delay/100 ms |
| status | `F0 DE 00 00 01` | `00` idle, `01` busy |

Status words: `9000` ok, `68CA` low voltage, `68CB` refresh timeout,
`6992`/`6993` decompression, `6985` PIN required.

Frame layout is column-major, right-to-left, groups of four pixels
bottom-to-top — see `pack2bpp()` in `lib/src/image/quantizer.dart`.

### LZO

`lib/src/epd/lzo.dart` emits **literal-only LZO1X**, a port of
`literal_lzo()` upstream. It is valid LZO1X, so the panel accepts it, but it
gives no compression: a 105984-byte frame goes out as ~106 k on the wire
(56 packets, the same count a compressed frame uses on these panels, since the
device stride is fixed at 250 bytes regardless).

If you want real compression later, drop in a Dart LZO1X encoder behind the
same `LzoLiteral.compressBlocks()` signature. `TransferPlan.build()` does not
care how the bytes were produced.

---

## Porting the protocol to a PN532 bridge

`lib/src/epd/` has no Flutter dependency except `nfc_session.dart`. To drive a
PN532 from an ESP32 or a desktop tool, implement `TagLink`:

```dart
class Pn532Link implements TagLink {
  @override String get name => 'PN532 HSU';
  @override bool get canSendShortFrames => true;   // this one *can* wake panels

  @override
  Future<ApduResponse> transceive(Uint8List apdu) async { ... }

  @override
  Future<void> close({String? alertMessage, String? errorMessage}) async { ... }
}
```

Then reuse `Writer` unchanged — it only calls `transceive` and `close`. Waking
the panel is the bridge's job, before `Writer` is constructed.

---

## Layout

```
lib/
  main.dart                   UI shell, tabs, settings
  src/epd/
    protocol.dart             APDUs, status words, D1 TLV parsing
    lzo.dart                  literal-only LZO1X encoder
    transfer_plan.dart        2000-byte blocks -> 250-byte packets
    writer.dart               staged flow, no auto-retry
    tag_link.dart             transport abstraction + error kinds
    nfc_session.dart          Core NFC / IsoDep wiring
    hex.dart                  hex helpers
  src/image/
    palette.dart              panel palette (black/white/yellow/red)
    quantizer.dart            dithering, 2bpp packing, frame geometry
    processor.dart            fit/rotate/brightness/contrast pipeline
  src/ui/probe_page.dart      manual APDU console
test/
  protocol_test.dart          26 tests, reference vectors included
```

Tests cover: exact APDU bytes, refresh delay encoding, packet header layout,
status word mapping, D1 TLV parsing (including the 552×1536/2-colour firmware
quirk), LZO literal vectors generated from the Python reference, block/packet
counts, the bit-packing order, and quantiser edge cases.

## Licence

The protocol knowledge and the Atkinson routine derive from the two upstream
projects; `huawei-epd-pn532` is **PolyForm Noncommercial 1.0.0**, so anything
built on this is non-commercial too unless you get separate permission.
