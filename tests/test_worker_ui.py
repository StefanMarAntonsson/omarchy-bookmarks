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
        self.assertIn('(root.altHeld ? "Ctrl+Alt+" : "Ctrl+")', self.ui)
        top_start = self.ui.index("id: topBookmarks")
        search_start = self.ui.index('visible: root.mode === "search" && root.query.trim().length > 0')
        top_region = self.ui[top_start:search_start]
        self.assertIn("width: topBookmarks.width; height: Style.space(58)", top_region)
        self.assertIn("text: modelData.title || root.domain(modelData.originalUrl)", top_region)
        self.assertIn("font.weight: Font.Medium", top_region)
        self.assertIn("modelData.tags.slice(0, 3)", top_region)
        self.assertIn("!root.query.trim() && event.key === Qt.Key_Up", self.ui)
        self.assertIn("!root.query.trim() && event.key === Qt.Key_Down", self.ui)

    def test_empty_library_explains_the_first_use_choices(self):
        self.assertIn("id: emptyLibraryPrompt", self.ui)
        self.assertIn("worker.ready && !root.searchLoading", self.ui)
        self.assertIn("root.results.length === 0", self.ui)
        self.assertIn('text: "Your bookmark library is empty"', self.ui)
        self.assertIn('text: "Add bookmark"', self.ui)
        self.assertIn('onClicked: root.beginAdd("")', self.ui)
        self.assertIn('text: "Import from browser"', self.ui)
        self.assertIn("onClicked: root.beginImport()", self.ui)
        self.assertIn('text: "Load examples"', self.ui)
        self.assertIn("onClicked: root.confirmLoadExamples()", self.ui)
        self.assertIn("!worker.setupRequired && root.results.length > 0", self.ui)

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

    def test_result_hover_selection_requires_pointer_movement(self):
        top_start = self.ui.index("id: topBookmarks")
        search_start = self.ui.index("id: searchResults")
        setup_start = self.ui.index("id: workerSetupPrompt")
        top_region = self.ui[top_start:search_start]
        search_region = self.ui[search_start:setup_start]

        self.assertIn("onPositionChanged:", top_region)
        self.assertIn("!root.pointerPlacementPending && index !== root.selectedIndex", top_region)
        self.assertIn("root.pointerMotionIsIntentional(topPointerArea, event)", top_region)
        self.assertNotIn("onEntered:", top_region)
        self.assertIn("onPositionChanged:", search_region)
        self.assertIn(
            "!root.pointerPlacementPending && !root.editingPreviewUrl && index !== root.selectedIndex",
            search_region,
        )
        self.assertIn("root.pointerMotionIsIntentional(resultPointerArea, event)", search_region)
        self.assertNotIn("onEntered:", search_region)

    def test_opening_places_the_pointer_over_the_settled_search_field(self):
        self.assertIn("import Quickshell.Hyprland", self.ui)
        self.assertIn("property bool pointerPlacementPending: false", self.ui)
        self.assertIn("function maybePlacePointerOverSearchField()", self.ui)
        self.assertIn(
            "searchField.mapToGlobal(searchField.width / 2, searchField.height / 2)",
            self.ui,
        )
        self.assertIn('"hl.dsp.cursor.move({ x = " + x + ", y = " + y + " })"', self.ui)
        self.assertIn('"movecursor " + x + " " + y', self.ui)
        self.assertIn("settlePointerPlacementRequest(response.id)", self.ui)
        self.assertIn("pointerPlacementGuard.restart()", self.ui)
        self.assertIn("function pointerMotionIsIntentional(area, event)", self.ui)
        self.assertIn("area.mapToGlobal(event.x, event.y)", self.ui)

    def test_enter_opens_first_search_result_when_nothing_is_selected(self):
        activate_start = self.ui.index("function activateCurrent(invertOpeningPreference)")
        activate_end = self.ui.index("function activateSelected", activate_start)
        activate_region = self.ui[activate_start:activate_end]
        self.assertIn(
            "if (!item && query.trim() && !searchLoading && results.length)",
            activate_region,
        )
        self.assertIn("selectedIndex = 0", activate_region)
        self.assertIn("item = selectedResult()", activate_region)

    def test_ctrl_enter_uses_the_inverse_opening_preference_for_selection(self):
        self.assertIn(
            "(event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && event.modifiers === Qt.ControlModifier",
            self.ui,
        )
        self.assertIn("root.activateCurrent(true)", self.ui)
        self.assertIn('{key: "Ctrl+Enter"', self.ui)

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

    def test_escape_unwinds_preview_query_and_empty_search_in_order(self):
        self.assertIn("function clearSearchQuery()", self.ui)
        clear_start = self.ui.index("function clearSearchQuery()")
        clear_end = self.ui.index("\n  }", clear_start)
        clear_region = self.ui[clear_start:clear_end]
        self.assertIn('query = ""; searchField.text = ""', clear_region)
        self.assertIn("results = defaultResults", clear_region)
        self.assertIn("searchDebounce.restart()", clear_region)

        preview_escape = (
            "event.key === Qt.Key_Escape && "
            "(root.previewingSelection || root.editingPreviewUrl)"
        )
        query_escape = "event.key === Qt.Key_Escape && root.query.length > 0"
        dismiss_escape = "event.key === Qt.Key_Escape) { root.dismiss()"
        self.assertLess(self.ui.index(preview_escape), self.ui.index(query_escape))
        self.assertLess(self.ui.index(query_escape), self.ui.index(dismiss_escape))
        self.assertIn(
            "visible: root.previewingSelection || root.editingPreviewUrl || root.query.length > 0",
            self.ui,
        )

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
        self.assertIn('{key: "Ctrl+D", label: "Delete"}', self.ui)
        self.assertIn("(bookmarkActions.width - bookmarkActions.spacing * 3) / 4", self.ui)
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
        self.assertIn(
            "root.activateIndex(root.shortcutIndex(directSlot), false)",
            self.ui,
        )
        self.assertIn("index >= results.length) return", self.ui)
        self.assertIn('(root.altHeld ? "Ctrl+Alt+" : "Ctrl+")', self.ui)

    def test_ctrl_hints_only_appear_while_control_is_held(self):
        self.assertIn("property bool controlHeld: false", self.ui)
        self.assertIn("event.key === Qt.Key_Control", self.ui)
        self.assertIn("visible: root.controlHeld", self.ui)
        self.assertIn("component ResultShortcutContent: Item", self.ui)
        for hint in ['"Ctrl+N"', '"Add bookmark"', '"Ctrl+V"', '"Paste"', '"Ctrl+S"', '"Settings"']:
            with self.subTest(hint=hint):
                self.assertIn(hint, self.ui)
        self.assertIn("id: shortcutHintRow", self.ui)
        self.assertEqual(self.ui.count("width: shortcutHintRow.width / 3"), 3)
        self.assertNotIn("color: Util.alpha(Color.menu.text, 0.2)", self.ui)
        self.assertGreaterEqual(self.ui.count("font.pixelSize: Style.font.caption"), 3)
        self.assertIn("cursorVisible: !root.controlHeld", self.ui)
        self.assertNotIn("id: controlOverlay", self.ui)

    def test_ctrl_alt_hint_describes_the_inverse_opening_behavior(self):
        self.assertIn('text: "Ctrl+Alt+Number"', self.ui)
        self.assertIn("id: altShortcutHint", self.ui)
        self.assertIn(
            'root.openInNewWindow ? "Open in new tab" : "Open in new window"',
            self.ui,
        )

    def test_ctrl_alt_digit_opens_the_matching_result_with_inverse_preference(self):
        self.assertIn(
            "event.modifiers === (Qt.ControlModifier | Qt.AltModifier)",
            self.ui,
        )
        self.assertIn(
            "root.activateIndex(root.shortcutIndex(directSlot), true)",
            self.ui,
        )
        self.assertIn('property bool altHeld: false', self.ui)
        self.assertIn('(root.altHeld ? "Ctrl+Alt+" : "Ctrl+")', self.ui)
        self.assertNotIn('Ctrl+T', self.ui)

    def test_multi_browser_opening_is_not_exposed(self):
        for removed in (
            'type: "browsers"',
            'browser_id',
            'type: "open_all"',
            'type: "open_url_all"',
            'All browsers',
        ):
            self.assertNotIn(removed, self.ui)

    def test_open_failures_remain_visible_before_the_overlay_closes(self):
        self.assertIn("function requestOpen(body)", self.ui)
        self.assertIn("openUrlRequestId = worker.request(body)", self.ui)
        self.assertIn('statusMessage = String(response.error || "Could not open URL")', self.ui)
        self.assertIn("if (openUrlRequestId && response.id === openUrlRequestId) { openUrlRequestId = 0; dismiss(); return }", self.ui)

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
        self.assertIn('text: "Empty search shows"', self.ui)
        self.assertIn('text: "Most used"', self.ui)
        self.assertIn('text: "Recently used"', self.ui)
        self.assertIn('defaultResultOrder: draftDefaultResultOrder', self.ui)
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

    def test_settings_support_spatial_arrow_navigation_without_overriding_tab(self):
        self.assertIn("function settingsFocusRows()", self.ui)
        self.assertIn("function moveSettingsFocus(horizontalDelta, verticalDelta)", self.ui)
        self.assertIn("item.mapToItem(settingsPanel, 0, 0)", self.ui)
        self.assertIn("(currentColumn + horizontalDelta + currentControls.length) % currentControls.length", self.ui)
        self.assertIn("Math.abs(targetControls[targetIndex].centerX - sourceX)", self.ui)
        settings_start = self.ui.index("id: settingsPanel")
        settings_end = self.ui.index("id: libraryPanel", settings_start)
        settings_region = self.ui[settings_start:settings_end]
        self.assertIn("event.key === Qt.Key_Left", settings_region)
        self.assertIn("event.key === Qt.Key_Right", settings_region)
        self.assertIn("event.key === Qt.Key_Up", settings_region)
        self.assertIn("event.key === Qt.Key_Down", settings_region)
        self.assertNotIn("event.key === Qt.Key_Tab", settings_region)

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

    def test_metadata_and_tag_suggestions_cannot_leak_into_a_later_form(self):
        self.assertIn("property var metadataRequests: ({})", self.ui)
        self.assertIn("property var suggestionRequests: ({})", self.ui)
        self.assertIn("metadataRequests[requestId] = metadataRequestId", self.ui)
        self.assertIn("suggestionRequests[suggestionId] = metadataRequestId", self.ui)
        self.assertIn("Number(metadataGeneration) !== metadataRequestId", self.ui)
        self.assertIn("Number(suggestionGeneration) === metadataRequestId", self.ui)

    def test_form_and_settings_saves_are_single_flight(self):
        self.assertIn("property int formSaveRequestId: 0", self.ui)
        self.assertIn("if (formSaveRequestId) return", self.ui)
        self.assertIn("if (settingsSaveRequestId) return", self.ui)
        self.assertIn('text: root.formSaveRequestId ? "Saving…"', self.ui)
        self.assertIn('text: root.settingsSaveRequestId ? "Saving…"', self.ui)

    def test_edit_form_can_be_saved_from_keyboard_or_button(self):
        self.assertGreaterEqual(self.ui.count("onAccepted: root.saveForm()"), 3)
        self.assertIn('root.editingBookmark ? "Save" : "Add"', self.ui)
        self.assertIn("onClicked: root.saveForm()", self.ui)
        self.assertIn("urlField.text.trim().length > 0", self.ui)

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
        self.assertIn("utf8Length(encoded) > maxRequestBytes", self.client)
        self.assertIn("readonly property int maxRequestBytes: 64 * 1024", self.client)
        self.assertIn("line.length > root.maxLineCharacters", self.client)
        self.assertIn("Math.min(10000", self.client)
        self.assertIn("root.restartAttempt >= root.maxAutomaticRestarts", self.client)

    def test_worker_only_becomes_ready_after_a_successful_handshake(self):
        started = self.client[self.client.index("onStarted:"):self.client.index("onExited:")]
        hello = self.client[self.client.index("if (parsed.id === root.helloId"):self.client.index("if (parsed.id === 0")]
        self.assertNotIn("root.ready = true", started)
        self.assertIn('(!ready && body.type !== "hello")', self.client)
        self.assertIn("root.handshakeComplete = true", hello)
        self.assertIn("root.ready = true", hello)

    def test_startup_failures_do_not_restart_in_a_loop(self):
        self.assertIn("if (!wasRunning || root.restartAttempt >= root.maxAutomaticRestarts)", self.client)
        self.assertIn("root.handshakeComplete = true", self.client)
        self.assertIn("worker.start()", self.ui)

    def test_worker_setup_returns_to_the_overlay_after_the_terminal_closes(self):
        setup = self.ui[self.ui.index("id: workerSetup"):self.ui.index("PanelWindow {")]
        self.assertIn("onExited: function()", setup)
        self.assertIn('root.shell.summon(root.pluginId, "{}")', setup)
        self.assertIn("Bookmarks returns when the terminal closes.", self.ui)

    def test_every_request_is_resolved_or_times_out(self):
        self.assertIn("pending[id] = Date.now() + effectiveTimeout", self.client)
        self.assertIn("id: watchdog", self.client)
        self.assertIn('root.killReason = "Bookmark worker stopped responding"', self.client)
        self.assertIn("root.abandonPending(", self.client)
        self.assertIn("root.message({version: 1, id: Number(ids[i]), ok: false", self.client)
        self.assertIn("readonly property int libraryRequestTimeoutMs: 120000", self.client)
        self.assertIn("worker.request(body, worker.libraryRequestTimeoutMs)", self.ui)

    def test_worker_failure_releases_ready_state_and_restarts(self):
        self.assertIn("onExited", self.client)
        self.assertIn("root.ready", self.client)
        self.assertIn("restartTimer.restart()", self.client)

    def test_process_output_is_streamed_not_collected(self):
        for path in ROOT.glob("*.qml"):
            with self.subTest(filename=path.name):
                self.assertNotIn("StdioCollector", path.read_text(encoding="utf-8"))

    def test_delete_requires_explicit_confirmation(self):
        self.assertIn('mode = "delete"', self.ui)
        self.assertIn('text: "Enter confirms · Escape cancels"', self.ui)
        self.assertIn("function confirmDelete()", self.ui)
        self.assertIn('type: "delete", bookmark_id: editingBookmark.id', self.ui)
        self.assertIn("if (deleteRequestId || !editingBookmark) return", self.ui)

    def test_successful_delete_restores_search_focus(self):
        delete_result_start = self.ui.index(
            "if (deleteRequestId && response.id === deleteRequestId)",
            self.ui.index("var result = response.result || {}"),
        )
        delete_result_end = self.ui.index("\n    }", delete_result_start)
        delete_result_region = self.ui[delete_result_start:delete_result_end]
        self.assertIn('if (result.deleted) {', delete_result_region)
        self.assertIn('mode = "search"', delete_result_region)
        self.assertIn(
            "Qt.callLater(function() { searchField.forceActiveFocus() })",
            delete_result_region,
        )

    def test_untrusted_titles_are_plain_text(self):
        position = self.ui.index("text: modelData.title || root.domain(modelData.originalUrl)")
        self.assertIn("textFormat: Text.PlainText", self.ui[position:position + 1000])

    def test_every_text_element_is_plain_text(self):
        import re
        for match in re.finditer(r"(?<![A-Za-z.])Text \{", self.ui):
            depth, end = 1, match.end()
            while depth:
                depth += {"{": 1, "}": -1}.get(self.ui[end], 0)
                end += 1
            own_properties = self.ui[match.end():end].split("{")[0]
            with self.subTest(offset=match.start()):
                self.assertIn("textFormat: Text.PlainText", own_properties)
        self.assertNotIn("Controls.Button", self.ui)
        self.assertNotIn("RichText", self.ui)
        self.assertNotIn("StyledText", self.ui)

    def test_library_actions_are_wired_to_the_worker(self):
        for request in ['type: "import_sources"', 'type: "import_preview"', 'type: "import_bookmarks"',
                        'type: "backup_create"', 'type: "backups_list"', 'type: "backup_restore"',
                        'type: "library_clear"', 'type: "library_load_examples"']:
            with self.subTest(request=request):
                self.assertIn(request, self.ui)
        self.assertIn('text: "Library"', self.ui)
        self.assertIn("id: libraryPanel", self.ui)

    def test_library_rows_never_assign_undefined_text(self):
        self.assertIn('String(modelData.browser || "")', self.ui)
        self.assertIn('String(modelData.profile || "")', self.ui)
        self.assertIn('Number(modelData.createdAt || 0)', self.ui)
        self.assertIn('Number(modelData.bookmarks || 0)', self.ui)

    def test_destructive_library_actions_require_confirmation(self):
        clear = self.ui[self.ui.index("function confirmClearLibrary()"):]
        clear = clear[:clear.index("\n  }")]
        self.assertIn("beginLibraryConfirm(", clear)
        examples = self.ui[self.ui.index("function confirmLoadExamples()"):]
        examples = examples[:examples.index("\n  }")]
        self.assertIn("beginLibraryConfirm(", examples)
        restore = self.ui[self.ui.index("} else if (mode === \"restore\") {"):]
        self.assertLess(restore.index("beginLibraryConfirm("), restore.index("libraryRequest("))

    def test_library_failures_release_the_busy_state(self):
        self.assertIn(
            'if (libraryRequestId && response.id === libraryRequestId) { libraryRequestId = 0; libraryBusy = false; statusMessage',
            self.ui,
        )

    def test_hidden_overlay_releases_result_model(self):
        self.assertIn(
            'function close() { opened = false; query = ""; searchField.text = ""; results = []',
            self.ui,
        )

    def test_populated_default_view_has_no_toolbar_or_buttons(self):
        search_start = self.ui.index("id: topBookmarks")
        results_start = self.ui.index('visible: root.mode === "search" && root.query.trim().length > 0')
        default_region = self.ui[search_start:results_start]
        self.assertNotIn("Controls.Button", default_region)
        self.assertNotIn("New", default_region)
        self.assertNotIn("Quit", default_region)


if __name__ == "__main__":
    unittest.main()
