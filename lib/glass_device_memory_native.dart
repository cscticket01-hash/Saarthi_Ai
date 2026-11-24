import 'dart:ffi';
import 'dart:io';

/// Optional local physical RAM probe; no startup subprocess or network call.
Future<int?>? _probe;
Future<int?> readGlassDeviceMemory() => _probe ??= _read();

final class _MemoryStatusEx extends Struct {
  @Uint32()
  external int length;
  @Uint32()
  external int memoryLoad;
  @Uint64()
  external int totalPhysical;
  @Uint64()
  external int availablePhysical;
  @Uint64()
  external int totalPageFile;
  @Uint64()
  external int availablePageFile;
  @Uint64()
  external int totalVirtual;
  @Uint64()
  external int availableVirtual;
  @Uint64()
  external int availableExtendedVirtual;
}

int? _windowsTotalMemory() {
  final kernel = DynamicLibrary.open('kernel32.dll');
  final getHeap = kernel.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('GetProcessHeap');
  final alloc = kernel.lookupFunction<Pointer<Void> Function(Pointer<Void>, Uint32, UintPtr), Pointer<Void> Function(Pointer<Void>, int, int)>('HeapAlloc');
  final free = kernel.lookupFunction<Int32 Function(Pointer<Void>, Uint32, Pointer<Void>), int Function(Pointer<Void>, int, Pointer<Void>)>('HeapFree');
  final status = kernel.lookupFunction<Int32 Function(Pointer<_MemoryStatusEx>), int Function(Pointer<_MemoryStatusEx>)>('GlobalMemoryStatusEx');
  final heap = getHeap();
  if (heap == nullptr) return null;
  final memory = alloc(heap, 8 /* HEAP_ZERO_MEMORY */, sizeOf<_MemoryStatusEx>());
  if (memory == nullptr) return null;
  try {
    final value = memory.cast<_MemoryStatusEx>();
    value.ref.length = sizeOf<_MemoryStatusEx>();
    return status(value) != 0 ? value.ref.totalPhysical : null;
  } finally {
    free(heap, 0, memory);
  }
}

Future<int?> _read() async {
  try {
    if (Platform.isWindows) return _windowsTotalMemory();
    if (Platform.isAndroid || Platform.isLinux) {
      final text = await File('/proc/meminfo').readAsString();
      final kb = int.tryParse(RegExp(r'^MemTotal:\s+(\d+)\s+kB', multiLine: true).firstMatch(text)?.group(1) ?? '');
      return kb == null ? null : kb * 1024;
    }
  } catch (_) { /* Unsupported platform or probe failure: measured frames remain authoritative. */ }
  return null;
}
