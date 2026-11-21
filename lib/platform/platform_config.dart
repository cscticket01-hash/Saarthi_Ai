const developerStaging = bool.fromEnvironment('SAARTHI_DEVELOPER_STAGING');
const platformProjectId = developerStaging
    ? 'saarthi-ai-staging'
    : 'saarthi-ai-df12b';
// Public Firebase configuration. Never place a service account in an app.
const platformApiKey = developerStaging
    ? 'AIzaSyCaAn35-HyY74udMwrugMUBkz6Sy6ACvzk'
    : 'AIzaSyDherXWiNIbKzO8EFuf1VdpHvu7U6R-W3A';
const platformFirestoreUrl =
    'https://firestore.googleapis.com/v1/projects/$platformProjectId/databases/(default)/documents';
