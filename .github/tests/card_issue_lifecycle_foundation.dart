import '../../lib/card_issue_lifecycle.dart';

void check(bool condition, String label) {
  if (!condition) throw StateError(label);
}

void rejects(void Function() operation, String label) {
  try {
    operation();
  } on StateError {
    return;
  } on ArgumentError {
    return;
  } on UnsupportedError {
    return;
  }
  throw StateError('Unexpected acceptance: $label');
}

void main() {
  final scope = CardPersonScope('school-a', 'student-42', '2026-27');
  final now = DateTime.utc(2026, 10, 11);
  const admin = CardIssueAdmin(
    schoolId: 'school-a',
    actorId: 'admin-7',
    authorized: true,
  );
  CardIssueCommand command(
    String op,
    String id,
    CardIssueAction action, {
    CardPersonScope? person,
    DateTime? at,
    DateTime? expiry,
    String? previous,
  }) => CardIssueCommand(
    operationId: op,
    issueId: id,
    action: action,
    scope: person ?? scope,
    at: at ?? now,
    expiresAt: expiry,
    previousIssueId: previous,
  );
  final issue = command(
    'op-1',
    'issue-1',
    CardIssueAction.issue,
    expiry: now.add(const Duration(days: 365)),
  );
  final empty = CardIssueLedger.empty();
  final first = empty.apply(issue, admin);
  check(
    empty.history.isEmpty && first.history.length == 1,
    'Immutable prior ledger',
  );
  check(CardIssueLedger.schemaVersion == 2, 'Versioned foundation');
  check(identical(first.apply(issue, admin), first), 'Idempotent exact replay');
  rejects(
    () => first.apply(
      command(
        'op-1',
        'issue-2',
        CardIssueAction.issue,
        expiry: now.add(const Duration(days: 365)),
      ),
      admin,
    ),
    'Conflicting replay',
  );
  for (final wrong in [
    const CardIssueAdmin(
      schoolId: 'school-a',
      actorId: 'admin-7',
      authorized: false,
    ),
    const CardIssueAdmin(
      schoolId: 'school-b',
      actorId: 'admin-7',
      authorized: true,
    ),
    const CardIssueAdmin(schoolId: 'school-a', actorId: '', authorized: true),
  ]) {
    rejects(() => empty.apply(issue, wrong), 'Administrator scope');
  }
  rejects(
    () => first.apply(
      issue,
      const CardIssueAdmin(
        schoolId: 'school-a',
        actorId: 'different',
        authorized: true,
      ),
    ),
    'Replay actor',
  );
  final card = first.issues['issue-1']!;
  check(
    card.statusAt(now, onlineRevocationVerified: true) ==
        CardIssueStatus.active,
    'Active',
  );
  check(
    !card.canAdmitAttendance(now, onlineRevocationVerified: false),
    'Offline unknown fails closed',
  );
  check(
    card.statusAt(card.expiresAt, onlineRevocationVerified: true) ==
        CardIssueStatus.expired,
    'Exact expiry boundary',
  );
  check(
    !card.canAdmitAttendance(
      now.subtract(const Duration(seconds: 1)),
      onlineRevocationVerified: true,
    ),
    'Before issuance fails closed',
  );
  rejects(
    () => first.apply(
      command('op-2', 'issue-2', CardIssueAction.issue, expiry: card.expiresAt),
      admin,
    ),
    'Duplicate scoped identity needs reissue',
  );
  rejects(
    () => empty.apply(
      command('invalid', 'bad', CardIssueAction.issue, expiry: now),
      admin,
    ),
    'Nonpositive validity',
  );
  final second = first.apply(
    command(
      'op-reissue',
      'issue-2',
      CardIssueAction.reissue,
      previous: 'issue-1',
      expiry: card.expiresAt,
    ),
    admin,
  );
  check(
    first.issues['issue-1']!.supersededBy == null,
    'Prior snapshot unchanged',
  );
  check(
    second.issues['issue-1']!.statusAt(now, onlineRevocationVerified: true) ==
        CardIssueStatus.superseded,
    'Old card superseded',
  );
  check(
    second.issues['issue-2']!.scope.matches(scope),
    'Stable person/session retained',
  );
  rejects(
    () => first.apply(
      command(
        'foreign',
        'issue-3',
        CardIssueAction.reissue,
        person: CardPersonScope('school-a', 'student-99', '2026-27'),
        previous: 'issue-1',
        expiry: card.expiresAt,
      ),
      admin,
    ),
    'Cross-person reissue',
  );
  rejects(
    () => first.apply(
      command(
        'session',
        'issue-3',
        CardIssueAction.reissue,
        person: CardPersonScope('school-a', 'student-42', '2027-28'),
        previous: 'issue-1',
        expiry: card.expiresAt,
      ),
      admin,
    ),
    'Cross-session reissue',
  );
  final revoke = command('op-revoke', 'issue-2', CardIssueAction.revoke);
  final third = second.apply(revoke, admin);
  check(
    third.issues['issue-2']!.statusAt(now, onlineRevocationVerified: false) ==
        CardIssueStatus.revoked,
    'Known revocation remains denied offline',
  );
  check(identical(third.apply(revoke, admin), third), 'Revocation replay');
  check(
    third.history.length == 3 && first.history.length == 1,
    'Append-only immutable history',
  );
  rejects(() => third.issues.clear(), 'Read-only map');
  rejects(() => third.history.clear(), 'Read-only history');
  print(
    'PASS: QR2 pure lifecycle foundation; no durable/server/device acceptance claimed',
  );
}
