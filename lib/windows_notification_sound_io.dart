import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

Future<void> playWarmBell(int volume) async {
  if (!Platform.isWindows || volume <= 0) return;
  await Isolate.run(() => _play(volume));
}

// Reconstruct the selected original Warm Bell sample: two decaying
// C5/G5 tones, 190 ms apart, with gentle harmonic and attack/release envelopes.
// PCM is scaled per notification; the system's master volume is unchanged.
Uint8List warmBellWave(int volume) {
  const rate = 44100, count = 33956;
  final data = ByteData(44 + count * 2);
  void ascii(int offset, String value) {
    for (var i = 0; i < value.length; i++) { data.setUint8(offset+i, value.codeUnitAt(i)); }
  }
  ascii(0, 'RIFF'); data.setUint32(4, 36+count*2, Endian.little); ascii(8, 'WAVE');
  ascii(12, 'fmt '); data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little); data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little); data.setUint32(28, rate*2, Endian.little);
  data.setUint16(32, 2, Endian.little); data.setUint16(34, 16, Endian.little);
  ascii(36, 'data'); data.setUint32(40, count*2, Endian.little);
  double note(double t, double f, double amplitude, double decay, double duration) {
    if (t < 0 || t >= duration) return 0;
    final attack = math.min(1.0, t/.012);
    final release = math.min(1.0, (duration-t)/.025);
    final phase = 2*math.pi*f*t;
    return amplitude*math.exp(-t/decay)*attack*release*
      (math.sin(phase)+.14*math.sin(2*phase)+.04*math.sin(3*phase));
  }
  final gain = volume.clamp(0, 100)/100;
  for (var i=0; i<count; i++) {
    final t=i/rate;
    final sample=(note(t,523.25,.32,.095,.38)+note(t-.19,783.99,.26,.12,.48))*gain;
    data.setInt16(44+i*2, (sample*32767).round().clamp(-32768,32767).toInt(), Endian.little);
  }
  return data.buffer.asUint8List();
}

void _play(int volume) {
  final wave = warmBellWave(volume);
  final kernel = DynamicLibrary.open('kernel32.dll');
  final alloc = kernel.lookupFunction<Pointer<Void> Function(Uint32, IntPtr), Pointer<Void> Function(int,int)>('LocalAlloc');
  final free = kernel.lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>('LocalFree');
  final play = DynamicLibrary.open('winmm.dll').lookupFunction<Int32 Function(Pointer<Void>, IntPtr, Uint32), int Function(Pointer<Void>, int, int)>('PlaySoundW');
  final memory = alloc(0, wave.length);
  if (memory.address == 0) throw StateError('Could not allocate notification audio.');
  try {
    memory.cast<Uint8>().asTypedList(wave.length).setAll(0, wave);
    // SND_MEMORY | SND_NODEFAULT | SND_SYNC, on an isolate.
    if (play(memory, 0, 0x0004 | 0x0002) == 0) throw StateError('Windows audio playback failed.');
  } finally { free(memory); }
}
