local M = {}

local LEFT_CAP = ""
local RIGHT_CAP = ""

M.reaction_types = {
  "like",
  "dislike",
  "heart",
  "hooray",
  "laugh",
  "confused",
}

local default_reaction_icons = {
  like = "👍",
  dislike = "👎",
  heart = "❤️",
  hooray = "🎉",
  laugh = "😄",
  confused = "😕",
}

local icon_aliases = {
  like = "thumbs_up",
  dislike = "thumbs_down",
}

local reaction_highlights = {
  like = { cap = "TaskmeisterReactionLikeCap", body = "TaskmeisterReactionLikeBadge" },
  dislike = { cap = "TaskmeisterReactionDislikeCap", body = "TaskmeisterReactionDislikeBadge" },
  heart = { cap = "TaskmeisterReactionHeartCap", body = "TaskmeisterReactionHeartBadge" },
  hooray = { cap = "TaskmeisterReactionHoorayCap", body = "TaskmeisterReactionHoorayBadge" },
  laugh = { cap = "TaskmeisterReactionLaughCap", body = "TaskmeisterReactionLaughBadge" },
  confused = { cap = "TaskmeisterReactionConfusedCap", body = "TaskmeisterReactionConfusedBadge" },
}

local function trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function append_all(target, source)
  for _, chunk in ipairs(source) do
    table.insert(target, chunk)
  end
end

function M.parse_tags(value)
  local tags = {}
  if type(value) ~= "string" or value == "" then
    return tags
  end
  for tag in value:gmatch("[^;]+") do
    tag = trim(tag)
    if tag ~= "" then
      table.insert(tags, tag)
    end
  end
  return tags
end

function M.badge_chunks(text, cap_hl, body_hl)
  return {
    { LEFT_CAP, cap_hl },
    { tostring(text or ""), body_hl },
    { RIGHT_CAP, cap_hl },
  }
end

function M.tag_chunks(value)
  local tags = type(value) == "table" and value or M.parse_tags(value)
  local chunks = {}
  for index, tag in ipairs(tags) do
    if index > 1 then
      table.insert(chunks, { " ", "Normal" })
    end
    append_all(chunks, M.badge_chunks(tag, "TaskmeisterTagBadgeCap", "TaskmeisterTagBadge"))
  end
  return chunks
end

function M.decorate_tag_field(bufnr, ns, line, value, start_col, prefix_chunks)
  if type(value) ~= "string" or value == "" then
    if prefix_chunks and #prefix_chunks > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, ns, line, start_col or 0, {
        virt_text = prefix_chunks,
        virt_text_pos = "inline",
      })
    end
    return
  end
  start_col = start_col or 0
  local text = value:sub(start_col + 1)
  local segment_start = 1
  local rendered_first_badge = false

  while segment_start <= #text do
    local sep_start, sep_end = text:find(";", segment_start, true)
    local segment_end = sep_start and sep_start - 1 or #text
    local raw = text:sub(segment_start, segment_end)
    local leading = raw:match("^%s*") or ""
    local trailing = raw:match("%s*$") or ""
    local tag_start = segment_start + #leading
    local tag_end = segment_end - #trailing

    if tag_start <= tag_end then
      local absolute_start = start_col + tag_start - 1
      local absolute_end = start_col + tag_end
      local line_text = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ""
      if absolute_start <= #line_text then
        vim.api.nvim_buf_add_highlight(bufnr, ns, "TaskmeisterTagBadge", line, absolute_start, absolute_end)
        local start_chunks = {}
        if not rendered_first_badge and prefix_chunks then
          append_all(start_chunks, prefix_chunks)
        end
        table.insert(start_chunks, { LEFT_CAP, "TaskmeisterTagBadgeCap" })
        vim.api.nvim_buf_set_extmark(bufnr, ns, line, absolute_start, {
          virt_text = start_chunks,
          virt_text_pos = "inline",
        })
        vim.api.nvim_buf_set_extmark(bufnr, ns, line, math.min(absolute_end, #line_text), {
          virt_text = {
            { RIGHT_CAP, "TaskmeisterTagBadgeCap" },
          },
          virt_text_pos = "inline",
        })
        rendered_first_badge = true
      end
    end

    if not sep_start then
      break
    end
    segment_start = sep_end + 1
  end

  if not rendered_first_badge and prefix_chunks and #prefix_chunks > 0 then
    vim.api.nvim_buf_set_extmark(bufnr, ns, line, start_col, {
      virt_text = prefix_chunks,
      virt_text_pos = "inline",
    })
  end
end

function M.reaction_icon(reaction, icons)
  icons = icons or {}
  return icons[reaction]
    or icons[icon_aliases[reaction] or ""]
    or default_reaction_icons[reaction]
    or reaction
end

local function append_reaction(chunks, reaction, count, icons)
  if #chunks > 0 then
    table.insert(chunks, { "  ", "Normal" })
  end
  local highlights = reaction_highlights[reaction]
    or { cap = "TaskmeisterReactionDefaultCap", body = "TaskmeisterReactionDefaultBadge" }
  append_all(chunks, M.badge_chunks(M.reaction_icon(reaction, icons), highlights.cap, highlights.body))
  table.insert(chunks, { " " .. tostring(count), "TaskmeisterReactionCount" })
end

function M.reaction_chunks(reactions, icons)
  local chunks = {}
  if type(reactions) ~= "table" then
    return chunks
  end

  local known = {}
  for _, reaction in ipairs(M.reaction_types) do
    known[reaction] = true
    local count = tonumber(reactions[reaction]) or 0
    if count > 0 then
      append_reaction(chunks, reaction, count, icons)
    end
  end

  local extras = {}
  for reaction, count in pairs(reactions) do
    if not known[reaction] and (tonumber(count) or 0) > 0 then
      table.insert(extras, reaction)
    end
  end
  table.sort(extras)

  for _, reaction in ipairs(extras) do
    append_reaction(chunks, reaction, tonumber(reactions[reaction]) or reactions[reaction], icons)
  end

  return chunks
end

return M
