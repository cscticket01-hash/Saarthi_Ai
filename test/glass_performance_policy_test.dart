import 'package:flutter_test/flutter_test.dart';
import '../lib/liquid_glass_theme.dart';

void main() {
  Iterable<Duration> frames(int count, int milliseconds) =>
      List.filled(count, Duration(milliseconds: milliseconds));
  test('low RAM caps visual quality even with fast frames', () {
    final policy = GlassPerformancePolicy();
    policy.setMemoryBytes(4 * 1024 * 1024 * 1024);
    expect(policy.mode, GlassPerformanceMode.low);
    policy.observe(frames(600, 8));
    expect(policy.mode, GlassPerformanceMode.low);
  });
  test('high RAM starts balanced, promotes only after sustained good frames', () {
    final policy = GlassPerformancePolicy();
    policy.setMemoryBytes(16 * 1024 * 1024 * 1024);
    policy.observe(frames(239, 8));
    expect(policy.mode, GlassPerformanceMode.balanced);
    expect(policy.observe(frames(1, 8)), isTrue);
    expect(policy.mode, GlassPerformanceMode.high);
    expect(policy.observe(frames(60, 45)), isTrue);
    expect(policy.mode, GlassPerformanceMode.low);
    policy.observe(frames(240, 8));
    expect(policy.mode, GlassPerformanceMode.balanced);
  });
  test('unknown RAM uses measured frames and middle tier caps effects', () {
    final policy = GlassPerformancePolicy();
    policy.setMemoryBytes(null);
    policy.observe(frames(240, 8));
    expect(policy.mode, GlassPerformanceMode.high);
    policy.setMemoryBytes(6 * 1024 * 1024 * 1024);
    expect(policy.mode, GlassPerformanceMode.balanced);
    policy.observe(frames(600, 8));
    expect(policy.mode, GlassPerformanceMode.balanced);
  });
}
