import 'package:flutter_test/flutter_test.dart';
import '../lib/sync_review_school_console.dart';

void main() {
  test('isolated web notice validation accepts both legacy and Actions attempt IDs', () {
    expect(isValidSyntheticReviewNoticeId('synthetic-web-notice-41711974616'), isTrue);
    expect(isValidSyntheticReviewNoticeId('synthetic-web-notice-41877739711-1'), isTrue);
    expect(isValidSyntheticReviewNoticeId('synthetic-web-notice-41877739711-25'), isTrue);
    expect(isValidSyntheticReviewNoticeId('synthetic-web-notice-41877739711-0001'), isFalse);
    expect(isValidSyntheticReviewNoticeId('synthetic-web-notice-0'), isFalse);
    expect(isValidSyntheticReviewNoticeId('synthetic-web-notice-41877739711-other'), isFalse);
    expect(isValidSyntheticReviewNoticeId('synthetic-web-notice-41877739711-1-extra'), isFalse);
    expect(isValidSyntheticReviewNoticeId('real-student-41877739711-1'), isFalse);
    expect(isValidSyntheticReviewNoticeId('synthetic-web-notice-41877739711-1/other'), isFalse);
    expect(isValidSyntheticReviewNoticeId('synthetic-web-notice-99999999999999999999999-1'), isFalse);
  });
}
