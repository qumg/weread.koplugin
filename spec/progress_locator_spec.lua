-- Unit tests for weread/lib/progress_locator.lua.
-- Run from the repo root with:
--   lua spec/progress_locator_spec.lua

package.path = "./?.lua;" .. package.path
package.preload["util"] = function()
    return { htmlEntitiesToUtf8 = function(text) return text end }
end
local Locator = require("weread.lib.progress_locator")
local Source = require("weread.lib.annotation_source")

local failures, checks = 0, 0
local current_test

local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL [%s] %s: got %s, want %s",
            current_test, label, tostring(got), tostring(want)))
    end
end

local function test(name, fn)
    current_test = name
    fn()
end

test("normalize unifies mid-dot and whitespace", function()
    eq(Locator.normalize_needle("贝克兰德，皇后区。奥黛丽.霍尔"),
        Locator.normalize_needle("贝克兰德，皇后区。奥黛丽·霍尔"),
        "dot variants match")
    eq(Locator.normalize_needle("贝克 兰德"), "贝克兰德", "spaces stripped")
end)

test("HTML source offset finds the viewport needle", function()
    local html = "<html><body><p>第一百一十二章 阿兹克的解释</p>"
        .. "<p>贝克兰德，皇后区。奥黛丽.霍尔坐在阴凉角</p></body></html>"
    local spans = Source.index(html)
    local offset = Locator.offset_from_source(spans, "贝克兰德，皇后区。奥黛丽.霍尔坐在阴凉角")
    eq(type(offset) == "number", true, "offset found")
    local quoted = Source.quote(spans, string.format("%d-%d", offset, offset + 20))
    eq(Locator.normalize_needle(quoted),
        Locator.normalize_needle("贝克兰德，皇后区。奥黛丽.霍尔坐在阴凉角"),
        "quoted source matches the needle")
end)

test("full-book chapter file index skips the cover fragment", function()
    local packed = {
        { chapterUid = 113, chapterIdx = 113 },
        { chapterUid = 114, chapterIdx = 114 },
    }
    local book = {
        annotation_documents = {
            ["/cache/book.epub"] = { chapters = packed, clean = true },
        },
    }
    local chapters = {
        { chapterUid = 113, chapterIdx = 113, title = "112" },
        { chapterUid = 114, chapterIdx = 114, title = "113" },
    }
    local document = {
        file = "/cache/book.epub",
        getXPointer = function()
            return "/body/DocFragment[2]/body/p[1]"
        end,
        getFileNameFromXPointer = function()
            return "text/chapter-001.xhtml"
        end,
        getTextFromXPointers = function(_self, start_xp)
            if start_xp == "/body/DocFragment[1]" then return "" end
            return "第一百一十二章"
        end,
    }
    local chapter = Locator.resolve_chapter(document, book, chapters, {
        is_full_book = true,
    })
    eq(chapter and chapter.chapterUid, 113, "chapter-001 is the first packed chapter")
end)

test("goto prefers summary search over HTML offset", function()
    local jumps = {}
    local searched = {}
    local document = {
        findAllText = function(_self, needle)
            searched[#searched + 1] = needle
            if needle:find("贝克兰德", 1, true) then
                return { { start = "/body/DocFragment[2]/p[2]", ["end"] = "x" } }
            end
            return {}
        end,
        clearSelection = function() end,
    }
    local ok = Locator.goto_remote(document, {
        summary = "贝克兰德，皇后区。奥黛丽.霍尔坐在阴凉角",
        chapter_offset = 644,
        chapter_uid = 113,
    }, {
        goto_xpointer = function(xp)
            jumps[#jumps + 1] = xp
            return true
        end,
    })
    eq(ok, true, "jump succeeded")
    eq(jumps[1], "/body/DocFragment[2]/p[2]", "jumped to summary match")
    eq(#searched > 0, true, "searched the document")
end)

test("extract requires CRE location APIs", function()
    local located, reason = Locator.extract_from_document({
        file = "/cache/chapter.epub",
        getCurrentPage = function() return 1 end,
        getPageCount = function() return 10 end,
    }, {}, {}, { current_chapter = { chapterUid = 1 }, is_full_book = false })
    eq(located, nil, "page-only document is not located")
    eq(reason, "document_position_unavailable", "reason")
end)

print(string.format("progress_locator_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
