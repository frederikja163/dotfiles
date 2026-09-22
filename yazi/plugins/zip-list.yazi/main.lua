-- Preview a zip's contents with unzip, in place of yazi's stock `archive`
-- previewer.
--
-- The stock one (yazi-plugin/preset/plugins/archive.lua) goes through
-- archive.spawn_7z, which tries `7zz` then `7z` and gives up with "Do you have
-- 7-zip installed?" when neither is there. This machine has unzip and not
-- 7-zip, so hovering a zip filled the preview pane with that error. The same
-- reasoning routes Enter to bin/unzip-here; see yazi/yazi.toml.
--
-- Only zips. yazi.toml prepends this for application/zip alone, so every other
-- archive still reaches the stock previewer and still says it wants 7-zip,
-- which for rar and friends is the truth.
--
-- `unzip -Z1` rather than `-l` or `-Z`: it prints one entry per line and
-- nothing else. `-l` wraps the list in a header and a totals footer, and `-Z`
-- adds a summary line too, so both would need their own lines stripped before
-- paging -- and the columns they add are laid out for a terminal width this
-- pane does not have. Names alone is also what the question usually is.

local M = {}

-- Scrolling is the same shape as every other text previewer: `job.skip` is how
-- far down the list the pane has been scrolled and `job.area.h` is how many
-- rows fit. Asking unzip again on each scroll is cheap -- it reads the central
-- directory at the end of the file, not the contents -- so there is nothing
-- here worth caching.
function M:peek(job)
	local limit = job.area.h

	local output, err = Command("unzip")
		:arg({ "-Z1", "--", tostring(job.file.path) })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:output()

	if not output then
		return require("empty").msg(job, string.format("Failed to start `unzip`, error: %s", err))
	end

	local lines, total = {}, 0
	for name in output.stdout:gmatch("[^\n]+") do
		total = total + 1
		if total > job.skip and #lines < limit then
			lines[#lines + 1] = name
		end
	end

	-- A non-zero exit with nothing listed is a real failure -- not a zip, or
	-- truncated. A non-zero exit that still listed entries is not worth
	-- reporting over the listing itself, which is what the pane is for.
	if total == 0 then
		local reason = output.stderr:gsub("%s+$", "")
		if reason == "" then
			reason = output.status.success and "Empty archive"
				or string.format("`unzip` exited with error code %s", output.status.code)
		end
		return require("empty").msg(job, reason)
	end

	-- Scrolled past the end, which happens when a long archive is left scrolled
	-- and a shorter one comes under the cursor. Ask for the last full page
	-- instead of drawing nothing.
	if job.skip > 0 and total < job.skip + limit then
		return ya.emit("peek", {
			math.max(0, total - limit),
			only_if = job.file.url,
			upper_bound = true,
		})
	end

	ya.preview_widget(job, ui.Text(lines):area(job.area))
end

-- Verbatim from the stock archive previewer, so a zip scrolls exactly like
-- every other archive: a wheel notch moves a tenth of the pane, and at least
-- one row when the pane is short enough for a tenth to round to zero.
function M:seek(job)
	local h = cx.active.current.hovered
	if not h or h.url ~= job.file.url then
		return
	end

	local step = math.floor(job.units * job.area.h / 10)
	step = step == 0 and ya.clamp(-1, job.units, 1) or step

	ya.emit("peek", {
		math.max(0, cx.active.preview.skip + step),
		only_if = job.file.url,
	})
end

return M
