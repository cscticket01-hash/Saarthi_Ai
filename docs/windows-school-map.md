# Windows school map pin and attendance boundary

The School Settings map button uses url_launcher externalApplication to open the default browser, replacing explorer.exe. No Google Maps API key or paid map service is introduced.

Select the exact school campus point in Google Maps, right-click to copy the coordinate line, return to the pin dialog and paste. Selected-place links and trusted Google short share links can also be read when they contain a pin. Camera-centre-only URLs, arbitrary address numbers, non-Google redirects and invalid coordinates are rejected. Verify the pin in Google Maps before confirming it. Save School Settings with the existing administrator password confirmation. Existing school branding and records are preserved.

The saved radius is fixed at 200 metres. The shared cloud profile save also writes schools/{school}/school_settings/school_location so the location is available remotely rather than only in the Windows cache. The legacy mobile backend already reads school_location for its geofence; no Android application or public website feature changes are made.

Windows QR attendance requires finite valid coordinates, measured GPS accuracy at most 100 metres and distance plus measured uncertainty at most 200 metres. A selected school map pin does not prove the attendance device is on campus; device GPS remains independently checked. Windows location permission and accurate device positioning are still needed.

Tests cover browser handoff failures, exact point versus camera-centre URLs, short-link redirect restrictions, coordinate validation, 200 metre boundaries/uncertainty and pin-dialog confirmation. Windows runner tests and native build are required before release. Physical PC browser opening and campus GPS must be checked on an actual school device.
