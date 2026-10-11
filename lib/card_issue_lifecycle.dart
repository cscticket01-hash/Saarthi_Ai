/// Inactive QR2 preparation. This immutable planner is not a durable registry,
/// a credential, or server authorization. Integrators must enforce school/admin
/// proof and persist transitions atomically before exposing an issued card.
enum CardIssueStatus { active, expired, revoked, superseded, revocationUnknown }

enum CardIssueAction { issue, revoke, reissue }

class CardPersonScope {
  CardPersonScope(this.schoolId, this.personId, this.sessionId) {
    if ([schoolId, personId, sessionId].any((v) => v.trim().isEmpty)) {
      throw ArgumentError('School, person and academic session are required');
    }
  }
  final String schoolId, personId, sessionId;
  bool matches(CardPersonScope other) =>
      schoolId == other.schoolId &&
      personId == other.personId &&
      sessionId == other.sessionId;
}

class CardIssue {
  const CardIssue._(
    this.id,
    this.scope,
    this.issuedAt,
    this.expiresAt, {
    this.revokedAt,
    this.supersededBy,
  });
  final String id;
  final CardPersonScope scope;
  final DateTime issuedAt, expiresAt;
  final DateTime? revokedAt;
  final String? supersededBy;

  /// Unknown offline revocation fails closed even before printed expiry.
  CardIssueStatus statusAt(
    DateTime now, {
    required bool onlineRevocationVerified,
  }) {
    if (revokedAt != null) return CardIssueStatus.revoked;
    if (supersededBy != null) return CardIssueStatus.superseded;
    if (!now.isBefore(expiresAt)) return CardIssueStatus.expired;
    if (now.isBefore(issuedAt) || !onlineRevocationVerified) {
      return CardIssueStatus.revocationUnknown;
    }
    return CardIssueStatus.active;
  }

  bool canAdmitAttendance(
    DateTime now, {
    required bool onlineRevocationVerified,
  }) =>
      statusAt(now, onlineRevocationVerified: onlineRevocationVerified) ==
      CardIssueStatus.active;
}

/// The caller supplies a verified authorization context, never a QR/password.
class CardIssueAdmin {
  const CardIssueAdmin({
    required this.schoolId,
    required this.actorId,
    required this.authorized,
  });
  final String schoolId, actorId;
  final bool authorized;
}

class CardIssueCommand {
  CardIssueCommand({
    required this.operationId,
    required this.action,
    required this.scope,
    required this.issueId,
    required this.at,
    this.expiresAt,
    this.previousIssueId,
  }) {
    if (operationId.trim().isEmpty || issueId.trim().isEmpty) {
      throw ArgumentError('Stable operation and issue identity required');
    }
  }
  final String operationId, issueId;
  final CardIssueAction action;
  final CardPersonScope scope;
  final DateTime at;
  final DateTime? expiresAt;
  final String? previousIssueId;
  bool sameAs(CardIssueCommand other) =>
      operationId == other.operationId &&
      action == other.action &&
      scope.matches(other.scope) &&
      issueId == other.issueId &&
      at == other.at &&
      expiresAt == other.expiresAt &&
      previousIssueId == other.previousIssueId;
}

class CardIssueEvent {
  const CardIssueEvent._(this.command, this.actorId);
  final CardIssueCommand command;
  final String actorId;
}

class CardIssueLedger {
  static const schemaVersion = 2;
  CardIssueLedger._(Map<String, CardIssue> issues, List<CardIssueEvent> history)
    : issues = Map.unmodifiable(issues),
      history = List.unmodifiable(history);
  factory CardIssueLedger.empty() => CardIssueLedger._({}, []);
  final Map<String, CardIssue> issues;
  final List<CardIssueEvent> history;

  /// Pure atomic transition proposal. Unchanged operation replay returns this
  /// exact ledger; conflicting replay fails without altering immutable history.
  CardIssueLedger apply(CardIssueCommand command, CardIssueAdmin admin) {
    if (!admin.authorized ||
        admin.actorId.trim().isEmpty ||
        admin.schoolId != command.scope.schoolId) {
      throw StateError('Verified same-school administrator required');
    }
    for (final event in history) {
      if (event.command.operationId == command.operationId) {
        if (event.actorId == admin.actorId && event.command.sameAs(command))
          return this;
        throw StateError('Operation replay conflicts with retained history');
      }
    }
    final next = Map<String, CardIssue>.of(issues);
    if (command.action == CardIssueAction.revoke) {
      final existing = next[command.issueId];
      if (existing == null ||
          !existing.scope.matches(command.scope) ||
          command.at.isBefore(existing.issuedAt) ||
          command.expiresAt != null ||
          command.previousIssueId != null ||
          existing.revokedAt != null ||
          existing.supersededBy != null) {
        throw StateError('Invalid scoped revocation transition');
      }
      next[existing.id] = CardIssue._(
        existing.id,
        existing.scope,
        existing.issuedAt,
        existing.expiresAt,
        revokedAt: command.at,
      );
    } else {
      final expiry = command.expiresAt;
      if (next.containsKey(command.issueId) ||
          expiry == null ||
          !expiry.isAfter(command.at))
        throw StateError('Invalid unique issue or validity');
      if (command.action == CardIssueAction.reissue) {
        final previous = next[command.previousIssueId];
        if (previous == null ||
            !previous.scope.matches(command.scope) ||
            previous.supersededBy != null ||
            command.at.isBefore(previous.issuedAt)) {
          throw StateError(
            'Reissue must reference the same stable scoped person',
          );
        }
        next[previous.id] = CardIssue._(
          previous.id,
          previous.scope,
          previous.issuedAt,
          previous.expiresAt,
          revokedAt: previous.revokedAt,
          supersededBy: command.issueId,
        );
      } else if (command.previousIssueId != null ||
          next.values.any((issue) => issue.scope.matches(command.scope))) {
        throw StateError('Existing identity requires an explicit reissue');
      }
      next[command.issueId] = CardIssue._(
        command.issueId,
        command.scope,
        command.at,
        expiry,
      );
    }
    return CardIssueLedger._(next, [
      ...history,
      CardIssueEvent._(command, admin.actorId),
    ]);
  }
}
