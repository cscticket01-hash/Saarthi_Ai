# Compact developer Theme workspace

Preset pictures and RGB/HEX/HSV edits remain drafts until the explicit Save Theme action. Reset restores the last confirmed saved revision and preset; failed saves retain the draft for retry. Navigation arrows and four page dots change only the visible screenshot and never publish.

The bounded Theme route replaces its outer ListView with a viewport-sized workspace. The complete canvas scales down on shorter laptop displays, keeping all six cards, RGB/HEX controls, Save and preview arrows visible. Other portal routes retain their existing scrolling behavior.

Each of the six presets has four static screenshots generated from the actual isolated Windows widgets (Dashboard, Student Records, Fees, Settings), using the same native appearance implementation and preset identity. Custom RGB uses a hue preview of the baseline screenshots. No school data or live backend is contacted by the screenshot generator. There is no interactive Windows app embedded in the developer page.

The existing backend publication protocol and Windows App Lock password-unlock activation are unchanged. This update needs only a hosting release; no Windows installer or backend redeploy is required.
