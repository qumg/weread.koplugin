-- Locate WeRead chapter + in-chapter position from the open KOReader document.
-- Upload uses the current viewport's ~20 characters as `sm`; pull searches that
-- text in the open file. HTML rune offsets from the cached chapter source are
-- only a fallback. Never jump by whole-book GotoPercent.

local Source = require("weread.lib.annotation_source")

local ProgressLocator = {}

local SUMMARY_CHARS = 20

local function utf8_char_len(byte)
    if not byte then return 1 end
    if byte < 128 then return 1 elseif byte < 224 then return 2
    elseif byte < 240 then return 3 else return 4 end
end

local function utf8_substr(value, max_chars)
    local text = tostring(value or "")
    local limit = math.max(0, math.floor(tonumber(max_chars) or 0))
    local index = 1
    local count = 0
    while index <= #text and count < limit do
        local size = utf8_char_len(text:byte(index))
        index = index + size
        count = count + 1
    end
    return text:sub(1, index - 1)
end

local function split_runes(text)
    text = tostring(text or "")
    local runes = {}
    local i = 1
    while i <= #text do
        local size = utf8_char_len(text:byte(i))
        runes[#runes + 1] = text:sub(i, i + size - 1)
        i = i + size
    end
    return runes
end

local function pcall_method(object, name, ...)
    if type(object) ~= "table" or type(object[name]) ~= "function" then
        return nil
    end
    local ok, value = pcall(object[name], object, ...)
    if ok then return value end
    return nil
end

local function document_path(document)
    if not document then return nil end
    return document.file
        or (type(document.getFilePath) == "function" and document:getFilePath())
end

function ProgressLocator.normalize_needle(text)
    local value = tostring(text or "")
    value = value:gsub("·", "."):gsub("．", "."):gsub("•", ".")
    value = value:gsub("%s+", "")
    return value
end

function ProgressLocator.needle_variants(text)
    local raw = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if raw == "" then return {} end
    raw = utf8_substr(raw, SUMMARY_CHARS)
    local variants = { raw }
    local as_dot = raw:gsub("·", ".")
    local as_mid = raw:gsub("%.", "·")
    if as_dot ~= raw then variants[#variants + 1] = as_dot end
    if as_mid ~= raw then variants[#variants + 1] = as_mid end
    for _, count in ipairs({ 16, 12, 8 }) do
        local prefix = utf8_substr(raw, count)
        if prefix ~= "" and prefix ~= raw then
            variants[#variants + 1] = prefix
        end
    end
    return variants
end

function ProgressLocator.doc_fragment_index(xpointer)
    return tonumber(tostring(xpointer or ""):match("DocFragment%[(%d+)%]"))
end

function ProgressLocator.chapter_file_index(value)
    return tonumber(tostring(value or ""):match("chapter%-(%d+)"))
end

function ProgressLocator.packed_chapters(book, path)
    local docs = book and book.annotation_documents
    if type(docs) ~= "table" or not path then return nil end
    local entry = docs[path]
    if type(entry) == "table" and type(entry.chapters) == "table"
        and #entry.chapters > 0 then
        return entry.chapters
    end
    return nil
end

function ProgressLocator.current_xpointer(document)
    return pcall_method(document, "getXPointer")
end

function ProgressLocator.cover_fragment_shift(document)
    if type(document) ~= "table" then return 0 end
    local start_xp = "/body/DocFragment[1]"
    local end_xp = "/body/DocFragment[2]"
    local text = pcall_method(document, "getTextFromXPointers", start_xp, end_xp)
    if type(text) ~= "string" then return 0 end
    local flat = text:gsub("%s+", "")
    if flat == "" or #flat < 8 then return 1 end
    return 0
end

local function catalog_chapter(chapters, uid)
    if uid == nil then return nil end
    for _, chapter in ipairs(type(chapters) == "table" and chapters or {}) do
        local chapter_uid = chapter.chapterUid or chapter.chapterId
        if tostring(chapter_uid) == tostring(uid) then
            return chapter
        end
    end
    return nil
end

local function file_name_hint(document, xpointer)
    return pcall_method(document, "getFileNameFromXPointer", xpointer)
        or pcall_method(document, "getPageFileName")
        or pcall_method(document, "getDocumentFile")
end

function ProgressLocator.resolve_chapter(document, book, chapters, options)
    options = options or {}
    if options.current_chapter and options.is_full_book ~= true then
        return options.current_chapter
    end

    local path = document_path(document)
    local packed = ProgressLocator.packed_chapters(book, path)
        or (options.is_full_book == true and chapters) or nil
    local xp = ProgressLocator.current_xpointer(document)
    local file_index = ProgressLocator.chapter_file_index(
        file_name_hint(document, xp) or xp)
    local packed_index = file_index
    if not packed_index then
        local fragment = ProgressLocator.doc_fragment_index(xp)
        if fragment then
            packed_index = fragment - ProgressLocator.cover_fragment_shift(document)
        end
    end
    if packed and packed_index and packed[packed_index] then
        local uid = packed[packed_index].chapterUid
            or packed[packed_index].chapterId
        local chapter = catalog_chapter(chapters, uid) or packed[packed_index]
        if chapter then return chapter end
    end
    return options.current_chapter
end

function ProgressLocator.chapter_start_xpointer(document, book, chapter, options)
    options = options or {}
    if options.is_full_book ~= true then
        return "/body/DocFragment[1]"
    end
    local path = document_path(document)
    local packed = ProgressLocator.packed_chapters(book, path)
    if not packed and type(options.chapters) == "table" then
        packed = options.chapters
    end
    local uid = chapter and (chapter.chapterUid or chapter.chapterId)
    local packed_index
    for index, item in ipairs(type(packed) == "table" and packed or {}) do
        if tostring(item.chapterUid or item.chapterId) == tostring(uid) then
            packed_index = index
            break
        end
    end
    if not packed_index then return nil end
    local fragment = packed_index + ProgressLocator.cover_fragment_shift(document)
    return string.format("/body/DocFragment[%d]", fragment)
end

function ProgressLocator.viewport_summary(document, max_chars)
    max_chars = max_chars or SUMMARY_CHARS
    if type(document) ~= "table" then return "" end
    local start_xp = ProgressLocator.current_xpointer(document)
    if not start_xp then return "" end
    local end_xp = start_xp
    local current = start_xp
    for _ = 1, max_chars + 40 do
        local next_xp = pcall_method(document, "getNextVisibleChar", current)
        if not next_xp then break end
        current = next_xp
        end_xp = next_xp
    end
    local text = pcall_method(document, "getTextFromXPointers", start_xp, end_xp)
    if type(text) ~= "string" or text == "" then return "" end
    text = text:gsub("[\r\n]+", ""):gsub("^%s+", "")
    return utf8_substr(text, max_chars)
end

function ProgressLocator.offset_from_source(spans, needle)
    local needle_runes = split_runes(ProgressLocator.normalize_needle(needle))
    if #needle_runes == 0 or type(spans) ~= "table" then return nil end

    local visible = {}
    local html_at = {}
    for _, span in ipairs(spans) do
        if type(span) == "table" and type(span[3]) == "string" then
            local text = span[3]
            local html_off = tonumber(span[1]) or 0
            local i = 1
            while i <= #text do
                local size = utf8_char_len(text:byte(i))
                visible[#visible + 1] = text:sub(i, i + size - 1)
                html_at[#html_at + 1] = html_off
                html_off = html_off + 1
                i = i + size
            end
        end
    end

    for start = 1, #visible do
        local needle_index = 1
        local cursor = start
        local matched = true
        while needle_index <= #needle_runes do
            if cursor > #visible then
                matched = false
                break
            end
            local normalized = ProgressLocator.normalize_needle(visible[cursor])
            if normalized == "" then
                cursor = cursor + 1
            elseif normalized == needle_runes[needle_index] then
                needle_index = needle_index + 1
                cursor = cursor + 1
            else
                matched = false
                break
            end
        end
        if matched then return html_at[start] end
    end
    return nil
end

function ProgressLocator.load_chapter_source(settings, book, uid)
    if not settings or type(book) ~= "table" or uid == nil then return nil end
    local ok_store, Store = pcall(require, "weread.lib.annotation_store")
    if not ok_store or type(Store) ~= "table" then return nil end
    local ok_new, store = pcall(Store.new, Store, settings)
    if not ok_new or type(store) ~= "table" then return nil end
    local book_id = book.book_id or book.bookId
    local ok_get, spans = pcall(store.get, store, book_id, "original", tostring(uid))
    if ok_get then return spans end
    return nil
end

function ProgressLocator.find_text(document, needle)
    if type(document) ~= "table" or type(document.findAllText) ~= "function" then
        return nil
    end
    if type(needle) ~= "string" or needle == "" then return nil end
    local ok, results = pcall(document.findAllText, document, needle, true, 0,
        8, false, 0)
    if type(document.clearSelection) == "function" then
        pcall(document.clearSelection, document)
    end
    if ok and type(results) == "table" and results[1] and results[1].start then
        return results[1].start
    end
    return nil
end

function ProgressLocator.goto_remote(document, remote, options)
    options = options or {}
    if type(remote) ~= "table" then return false, "remote_invalid" end
    local function jump(xpointer)
        if not xpointer or xpointer == "" then
            return false, "xpointer_missing"
        end
        if type(options.goto_xpointer) == "function" then
            local ok, err = options.goto_xpointer(xpointer)
            if ok then return true end
            return false, err or "jump_failed"
        end
        if type(document) == "table" and type(document.gotoXPointer) == "function" then
            local ok, err = pcall(document.gotoXPointer, document, xpointer)
            if ok then return true end
            return false, err or "jump_failed"
        end
        return false, "goto_unavailable"
    end

    for _, needle in ipairs(ProgressLocator.needle_variants(remote.summary)) do
        local xpointer = ProgressLocator.find_text(document, needle)
        if xpointer then return jump(xpointer) end
    end

    local spans = options.chapter_source
    if not spans and type(options.get_chapter_source) == "function"
        and remote.chapter_uid ~= nil then
        spans = options.get_chapter_source(remote.chapter_uid)
    end
    local offset = tonumber(remote.chapter_offset)
    if type(spans) == "table" and offset then
        local quoted = Source.quote(spans, string.format("%d-%d",
            offset, offset + SUMMARY_CHARS))
        for _, needle in ipairs(ProgressLocator.needle_variants(quoted)) do
            local xpointer = ProgressLocator.find_text(document, needle)
            if xpointer then return jump(xpointer) end
        end
    end

    if options.chapter_start_xpointer then
        return jump(options.chapter_start_xpointer)
    end
    return false, "summary_not_found"
end

function ProgressLocator.document_supports_location(document)
    return type(document) == "table" and (
        type(document.getXPointer) == "function"
        or type(document.findAllText) == "function"
        or type(document.getTextFromXPointers) == "function"
    )
end

function ProgressLocator.extract_from_document(document, book, chapters, options)
    options = options or {}
    if type(document) ~= "table" then return nil, "document_unavailable" end
    if not ProgressLocator.document_supports_location(document) then
        return nil, "document_position_unavailable"
    end
    local chapter = ProgressLocator.resolve_chapter(
        document, book, chapters, options)
    if type(chapter) ~= "table" then
        return nil, "current_chapter_not_found"
    end
    local summary = ProgressLocator.viewport_summary(document, SUMMARY_CHARS)
    local uid = chapter.chapterUid or chapter.chapterId
    local spans = options.chapter_source
    if not spans and type(options.get_chapter_source) == "function" then
        spans = options.get_chapter_source(uid)
    end
    local offset = ProgressLocator.offset_from_source(spans, summary)
    return {
        chapter_uid = uid,
        chapter_idx = tonumber(chapter.chapterIdx or chapter.chapterIndex) or 0,
        chapter_offset = math.max(0, tonumber(offset) or 0),
        has_chapter_offset = offset ~= nil,
        summary = summary,
        chapter = chapter,
    }
end

return ProgressLocator
