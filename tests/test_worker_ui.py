from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class WorkerUiContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ui = (ROOT / "Bookmarks.qml").read_text(encoding="utf-8")
        cls.client = (ROOT / "WorkerClient.qml").read_text(encoding="utf-8")

    def test_empty_query_requests_top_bookmarks_and_search_is_paginated(self):
        self.assertIn('type: "search", query: query, scope: searchScope, limit: resultCount, offset: 0', self.ui)
        self.assertIn('limit: resultCount', self.ui)
        self.assertIn("offset: loadedBookmarkCount()", self.ui)
        self.assertIn("results.concat(next)", self.ui)
        self.assertIn("searchHasMore", self.ui)

    def test_empty_query_uses_normal_result_rows(self):
        self.assertIn("id: topBookmarks", self.ui)
        self.assertIn("model: root.results", self.ui)
        self.assertIn('text: "Ctrl+" + root.resultShortcutKey(index)', self.ui)
        top_start = self.ui.index("id: topBookmarks")
        search_start = self.ui.index('visible: root.mode === "search" && root.query.trim().length > 0')
        top_region = self.ui[top_start:search_start]
        self.assertIn("width: topBookmarks.width; height: Style.space(58)", top_region)
        self.assertIn("text: modelData.title || root.domain(modelData.originalUrl)", top_region)
        self.assertIn("font.weight: Font.Medium", top_region)
        self.assertIn("modelData.tags.slice(0, 3)", top_region)
        self.assertIn("!root.query.trim() && event.key === Qt.Key_Up", self.ui)
        self.assertIn("!root.query.trim() && event.key === Qt.Key_Down", self.ui)

    def test_search_input_aligns_with_result_titles(self):
        self.assertIn(
            "leftPadding: Style.spacing.md; rightPadding: Style.spacing.md",
            self.ui,
        )
        self.assertGreaterEqual(
            self.ui.count("anchors.leftMargin: Style.spacing.md"),
            2,
        )

    def test_obsolete_search_responses_are_rejected(self):
        self.assertIn("response.id === latestSearchId", self.ui)
        self.assertIn('String(result.query || "") !== query', self.ui)
        self.assertIn('String(result.scope || "all") !== searchScope', self.ui)

    def test_tab_switches_between_default_and_tag_search(self):
        self.assertIn('property string searchScope: "all"', self.ui)
        self.assertIn('searchScope === "all" ? "tags" : "all"', self.ui)
        self.assertIn('event.key === Qt.Key_Tab', self.ui)
        self.assertIn('root.searchScope === "tags" ? "Search tags"', self.ui)
        self.assertIn(': "Search bookmarks"', self.ui)
        self.assertNotIn("Search bookmarks or paste a URL", self.ui)
        self.assertIn('visible: root.searchScope === "tags"', self.ui)
        self.assertIn('anchors.margins: Style.space(3)', self.ui)

    def test_keyboard_navigation_previews_the_current_result(self):
        self.assertIn("property int selectedIndex: -1", self.ui)
        self.assertIn("delta > 0 ? 0 : results.length - 1", self.ui)
        self.assertIn("searchField.text = String(item.originalUrl", self.ui)

    def test_preview_can_restore_the_original_search(self):
        self.assertIn("property bool previewingSelection: false", self.ui)
        self.assertIn("property bool editingPreviewUrl: false", self.ui)
        self.assertIn("function restoreSearchQuery()", self.ui)
        self.assertIn("searchField.text = query", self.ui)
        self.assertIn(
            "event.key === Qt.Key_Escape && (root.previewingSelection || root.editingPreviewUrl)",
            self.ui,
        )
        self.assertIn('id: escapeHint', self.ui)
        self.assertIn('text: "esc"', self.ui)

    def test_query_matches_are_highlighted_without_rich_text(self):
        self.assertIn("component HighlightedText: Item", self.ui)
        self.assertIn("sourceLower.indexOf(searchLower, cursor)", self.ui)
        self.assertIn("while (matchIndex >= 0)", self.ui)
        self.assertIn("appendPart(parts", self.ui)
        self.assertIn("needle: root.query", self.ui)
        self.assertIn("searchField.select(matchIndex", self.ui)
        highlighted_region = self.ui[
            self.ui.index("component HighlightedText: Item"):self.ui.index("WorkerClient {")
        ]
        self.assertGreaterEqual(highlighted_region.count("textFormat: Text.PlainText"), 2)
        self.assertNotIn("Text.RichText", highlighted_region)

    def test_editing_a_preview_turns_it_into_a_direct_url(self):
        self.assertIn(
            "root.previewingSelection = false; root.editingPreviewUrl = true; root.selectedIndex = -1",
            self.ui,
        )
        self.assertIn(
            "if (editingPreviewUrl) { requestOpenUrl(searchField.text",
            self.ui,
        )
        self.assertIn('type: "open_url"', self.ui)
        self.assertIn("result.isUrl && !result.exactMatch", self.ui)
        self.assertIn('action: "open_url", title: "Open URL"', self.ui)
        self.assertIn("Ctrl+N to add bookmark", self.ui)

    def test_ctrl_n_validates_and_checks_a_url_before_prefilling_add(self):
        self.assertIn("function requestAddCurrentUrl()", self.ui)
        self.assertIn('type: "duplicate", url: candidate', self.ui)
        self.assertIn('statusMessage = "Already bookmarked"', self.ui)
        self.assertIn("beginAdd(urlToAdd)", self.ui)

    def test_ctrl_d_deletes_and_plain_delete_remains_a_text_edit_key(self):
        self.assertIn(
            "event.key === Qt.Key_D && event.modifiers === Qt.ControlModifier",
            self.ui,
        )
        self.assertNotIn("event.key === Qt.Key_Delete", self.ui)

    def test_down_at_loaded_page_end_fetches_and_selects_the_next_result(self):
        self.assertIn("selectedIndex === results.length - 1 && searchHasMore", self.ui)
        self.assertIn("pendingSelectionIndex = results.length", self.ui)
        self.assertIn("loadNextSearchPage()", self.ui)
        self.assertIn("previewSelection(pending)", self.ui)
        self.assertIn("positionViewAtIndex(pending, ListView.Contain)", self.ui)

    def test_ctrl_digit_opens_the_matching_result(self):
        self.assertIn("key >= Qt.Key_1 && key <= Qt.Key_9", self.ui)
        self.assertIn("return key === Qt.Key_0 ? 9 : -1", self.ui)
        self.assertIn("root.activateIndex(root.shortcutIndex(directSlot))", self.ui)
        self.assertIn("index >= results.length) return", self.ui)
        self.assertIn('text: "Ctrl+" + root.resultShortcutKey(index)', self.ui)

    def test_ctrl_hints_only_appear_while_control_is_held(self):
        self.assertIn("property bool controlHeld: false", self.ui)
        self.assertIn("event.key === Qt.Key_Control", self.ui)
        self.assertIn("visible: root.controlHeld", self.ui)
        self.assertIn("component ResultShortcutContent: Item", self.ui)
        self.assertIn('text: "Ctrl+N   Add bookmark     Ctrl+S   Settings"', self.ui)
        self.assertNotIn("id: controlOverlay", self.ui)

    def test_ctrl_alt_replaces_bookmark_actions_with_browser_actions(self):
        self.assertIn("property bool altHeld: false", self.ui)
        self.assertIn("function updateModifierState(event, pressed)", self.ui)
        self.assertIn("event.nativeVirtualKey", self.ui)
        self.assertIn("event.nativeScanCode", self.ui)
        self.assertIn("visible: !controller.altHeld", self.ui)
        self.assertIn(
            "visible: controller.altHeld && controller.alternateBrowsers.length > 0",
            self.ui,
        )
        self.assertIn('text: "Ctrl+Alt+" + (index + 1)', self.ui)

    def test_alternate_browsers_are_loaded_and_have_shortcuts(self):
        self.assertIn('worker.request({type: "browsers"})', self.ui)
        self.assertIn("root.browsers.filter", self.ui)
        self.assertIn('sequence: "Ctrl+Alt+" + String(index + 1)', self.ui)
        self.assertIn("root.activateCurrentInBrowser(modelData.id)", self.ui)
        self.assertIn('browser_id: String(browserId)', self.ui)

    def test_nonempty_results_use_a_configurable_scrollable_viewport(self):
        self.assertIn("id: searchResults", self.ui)
        self.assertIn("resultWindowHeight: Style.space(58) * root.resultCount", self.ui)
        self.assertIn("root.noResultsState ? Style.space(44) : root.resultWindowHeight", self.ui)
        self.assertIn("height: root.resultWindowHeight", self.ui)
        self.assertIn("snapMode: ListView.SnapToItem", self.ui)
        self.assertIn("visibleStartIndex + slot", self.ui)

    def test_settings_shortcut_form_and_persistence_are_wired(self):
        self.assertIn('sequence: "Ctrl+S"', self.ui)
        self.assertIn('root.mode === "settings"', self.ui)
        self.assertIn('type: "get_settings"', self.ui)
        self.assertIn('type: "save_settings"', self.ui)
        self.assertIn('text: "Default search"', self.ui)
        self.assertIn('text: "Visible results"', self.ui)
        self.assertIn("Math.min(10", self.ui)
        self.assertIn("model: root.maximumResultCount - 2", self.ui)
        self.assertIn('text: "Open bookmarks"', self.ui)
        self.assertIn('text: "Details for pasted URLs"', self.ui)
        self.assertIn("url && fetchPageDetails", self.ui)
        self.assertIn(
            "invertOpeningPreference ? !openInNewWindow : openInNewWindow",
            self.ui,
        )
        self.assertIn(
            'controller.openInNewWindow ? "Open in new tab" : "Open in new window"',
            self.ui,
        )
        self.assertIn('text: "In a new tab"', self.ui)

    def test_no_result_resize_commits_with_the_completed_response(self):
        self.assertNotIn("noResultsResizeDelay", self.ui)
        self.assertNotIn("compactNoResults", self.ui)
        self.assertIn("noResultsState = query.trim().length > 0 && next.length === 0", self.ui)
        self.assertIn("height: root.noResultsState ? Style.space(44) : root.resultWindowHeight", self.ui)

    def test_search_keeps_rendered_rows_until_the_replacement_is_ready(self):
        perform_start = self.ui.index("function performSearch()")
        perform_end = self.ui.index("function loadNextSearchPage()")
        perform_region = self.ui[perform_start:perform_end]
        self.assertNotIn("results = []", perform_region)
        self.assertIn("results = defaultResults", perform_region)
        self.assertIn("property var defaultResults: []", self.ui)
        self.assertIn("!query.trim()) defaultResults = next", self.ui)
        self.assertIn("root.results = root.defaultResults", self.ui)

    def test_late_metadata_cannot_overwrite_edited_fields(self):
        self.assertIn("if (!titleEdited", self.ui)
        self.assertIn("if (!descriptionEdited", self.ui)
        self.assertIn("Number(result.metadataRequestId) !== metadataRequestId", self.ui)

    def test_edit_form_can_be_saved_from_keyboard_or_button(self):
        self.assertGreaterEqual(self.ui.count("onAccepted: root.saveForm()"), 3)
        self.assertIn('text: root.editingBookmark ? "Save" : "Add"', self.ui)
        self.assertIn("onClicked: root.saveForm()", self.ui)
        self.assertIn("enabled: urlField.text.trim().length > 0", self.ui)

    def test_tab_leaves_the_multiline_description_field(self):
        description_start = self.ui.index("id: descriptionField")
        tags_start = self.ui.index("id: tagsField", description_start)
        description_region = self.ui[description_start:tags_start]
        self.assertIn("Keys.priority: Keys.BeforeItem", description_region)
        self.assertIn("e.key === Qt.Key_Tab", description_region)
        self.assertIn("tagsField.forceActiveFocus()", description_region)
        self.assertIn("e.key === Qt.Key_Backtab", description_region)
        self.assertIn("titleField.forceActiveFocus()", description_region)

    def test_worker_protocol_and_restart_are_bounded(self):
        self.assertIn("stdinEnabled: true", self.client)
        self.assertIn("SplitParser", self.client)
        self.assertIn("encoded.length > 64 * 1024", self.client)
        self.assertIn("line.length > root.maxLineCharacters", self.client)
        self.assertIn("Math.min(10000", self.client)
        self.assertIn("Math.min(root.restartAttempt + 1, 6)", self.client)

    def test_default_view_has_no_toolbar_or_buttons(self):
        search_start = self.ui.index("id: searchField")
        results_start = self.ui.index('visible: root.mode === "search" && root.query.trim().length > 0')
        default_region = self.ui[search_start:results_start]
        self.assertNotIn("Controls.Button", default_region)
        self.assertNotIn("New", default_region)
        self.assertNotIn("Quit", default_region)


if __name__ == "__main__":
    unittest.main()
