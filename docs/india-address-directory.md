# Offline India address directory

Source: National Portal of India, https://www.india.gov.in/directory/web-directory/districts

Retrieved 27 October 2026 using the page's public directory APIs. The complete response contained 784 district entries and the state response contained 36 states/UTs. All entries are bundled in `lib/india_locations.dart`; forms never need a network request to open the lists.

The source is a website directory snapshot, not a guarantee that a government reorganisation has already reached every source system. Refresh the snapshot from the same source when administrative names change. Existing saved state/district strings are displayed without being silently renamed or deleted. Only an explicit State change clears the selected District. Existing foreign-country records remain intact until the operator explicitly chooses an Indian State.

The selector changes form controllers only. Existing school-scoped record saving, pending operations and sync ownership continue to persist the country/state/district fields. No data migration is performed.
