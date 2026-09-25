const { onDocumentCreated } = require('firebase-functions/v2/firestore');
const { logger } = require('firebase-functions');
const admin = require('firebase-admin');

admin.initializeApp();

function cleanText(value, fallback = '') {
  const text = String(value ?? '').trim();
  return text || fallback;
}

function shortBody(value, maxLength = 180) {
  const text = cleanText(
    value,
    'Open Vidya Saarthi to read the notice.',
  );

  if (text.length <= maxLength) return text;

  return `${text.slice(0, maxLength - 1).trimEnd()}…`;
}

exports.sendSchoolNoticePush = onDocumentCreated(
  {
    document: 'school_notices/{noticeId}',
    region: 'asia-south1',
    retry: true,
  },
  async (event) => {
    const snapshot = event.data;

    if (!snapshot) {
      logger.warn(
        'school_notices create event had no document snapshot.',
      );
      return;
    }

    const data = snapshot.data() || {};
    const noticeId = event.params.noticeId;

    const category = cleanText(
      data.category,
      'Notice',
    );

    const title = cleanText(
      data.title,
      'New School Notice',
    );

    const body = shortBody(
      data.description,
    );

    const message = {
      topic: 'school_notices',

      notification: {
        title: `${category} • ${title}`,
        body,
      },

      data: {
        type: 'school_notice',
        noticeId,
        category,
        title,
      },

      android: {
        priority: 'high',

        notification: {
          sound: 'default',
          visibility: 'public',
          tag: `school_notice_${noticeId}`,
        },
      },
    };

    const messageId =
      await admin.messaging().send(message);

    logger.info(
      'School notice push sent.',
      {
        noticeId,
        messageId,
        category,
        title,
      },
    );
  },
);
