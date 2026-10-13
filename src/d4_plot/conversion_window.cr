require "uing"
require "./conversion_draft"
require "./conversion_worker"

module D4Plot
  # Hiding this window does not destroy the draft or cancel its independent job.
  class ConversionWindow
    @window = UIng::Window.new("Create D4", 660, 450, margined: true)
    @draft = ConversionDraft.new
    @input = UIng::Entry.new
    @output = UIng::Entry.new
    @reference = UIng::Entry.new
    @input_browse = UIng::Button.new("Browse…")
    @output_browse = UIng::Button.new("Choose…")
    @reference_browse = UIng::Button.new("Browse…")
    @mode = UIng::Combobox.new
    @mode_hint = UIng::Label.new("")
    @mapq = UIng::Spinbox.new(0, 255, 0)
    @threads = UIng::Spinbox.new(0, 64, 0)
    @exclude = UIng::Entry.new
    @include = UIng::Entry.new
    @groups = UIng::Entry.new
    @minimum = UIng::Entry.new
    @maximum = UIng::Entry.new
    @advanced = UIng::Box.new(:vertical)
    @advanced_toggle = UIng::Button.new("Show advanced options")
    @status = UIng::MultilineEntry.new(read_only: true)
    @progress = UIng::ProgressBar.new
    @progress_slot = UIng::Box.new(:vertical)
    @create = UIng::Button.new("Create D4")
    @cancel = UIng::Button.new("Cancel creation")
    @add = UIng::Button.new("Add to view")
    @close = UIng::Button.new("Close")
    @last_display = ""
    @added = false

    def initialize(@worker : ConversionWorker, @on_add : Proc(String, Bool))
      setup_ui
      setup_handlers
      sync_mode
      poll
    end

    def show
      poll
      @window.show
    end

    def destroy
      @window.destroy
    end

    def poll
      snapshot = @worker.snapshot
      state = snapshot.state
      progress = snapshot.progress
      seconds = snapshot.elapsed.total_seconds.to_i
      display = "#{state}:#{progress}:#{seconds}:#{snapshot.error}:#{@added}"
      return if display == @last_display
      @last_display = display
      editable = state.idle? || state.failed? || state.cancelled?
      [@input, @output, @input_browse, @output_browse, @mode, @mapq,
       @threads, @exclude, @include, @groups, @minimum, @maximum].each do |control|
        editable ? control.enable : control.disable
      end
      sync_reference(editable)
      state.active? ? @create.disable : @create.enable
      state.running? ? @cancel.enable : @cancel.disable
      state.succeeded? && !@added ? @add.enable : @add.disable
      @create.text = state.succeeded? ? "Create another…" : "Create D4"
      @close.text = state.active? ? "Close (keep running)" : "Close"
      if state.active?
        @progress.value = -1
        @progress.show
      else
        @progress.hide
      end
      set_status(case state
      when .idle?
        "Ready. Your current view will not change.\nExisting output files are never overwritten."
      when .running?, .cancelling?
        phase = state.cancelling? ? "Cancelling — waiting for a safe stopping point" : progress.stage
        location = progress.total > 0 ? "#{progress.chromosome} (#{progress.current}/#{progress.total}) · " : ""
        "#{phase}\n#{location}#{progress.records} alignments read · #{seconds}s elapsed\nYou can keep browsing while this runs. Finalizing the index may take time."
      when .succeeded?
        "D4 created · #{seconds}s elapsed\n#{snapshot.output}\n#{@added ? "Added to the current view." : "Review the reference assembly, then choose Add to view when ready."}"
      when .cancelled?
        "Creation cancelled. No output file was published.\nYour settings and current view have been kept."
      else
        "#{snapshot.field || "Creation"}: #{snapshot.error}\nNo output file was published. Adjust the settings and try again."
      end)
    end

    private def row
      UIng::Box.new(:horizontal, padded: true)
    end

    private def path_row(entry, button)
      entry.set_minimum_size(0, -1)
      box = row
      box.append(entry, true)
      box.append(button, false)
      box
    end

    private def setup_ui
      root = UIng::Box.new(:vertical, padded: true)
      root.append(UIng::Label.new("Create a coverage D4 from a local, coordinate-sorted BAM or CRAM."), false)
      form = UIng::Form.new(padded: true)
      form.append("Input", path_row(@input, @input_browse))
      form.append("", UIng::Label.new("Requires a matching BAI / CSI / CRAI index."))
      form.append("Output D4", path_row(@output, @output_browse))
      form.append("CRAM reference", path_row(@reference, @reference_browse))
      form.append("", UIng::Label.new("For CRAM: the matching reference FASTA and its .fai index."))
      ["Standard — aligned bases", "Fast — whole read spans", "Fragments — paired templates"].each { |label| @mode.append(label) }
      @mode.selected = 0
      form.append("Coverage", @mode)
      form.append("", @mode_hint)
      form.append("Minimum MAPQ", @mapq)
      root.append(form, false)
      root.append(@advanced_toggle, false)

      advanced_form = UIng::Form.new(padded: true)
      advanced_form.append("Decompression threads", @threads)
      advanced_form.append("", UIng::Label.new("0 = no extra threads. Coverage calculation uses one worker."))
      @exclude.text = "1796"
      @include.text = "0"
      advanced_form.append("Exclude SAM flags", @exclude)
      advanced_form.append("Include any SAM flag", @include)
      advanced_form.append("", UIng::Label.new("Decimal or 0x hex. Include 0 = no requirement."))
      exclusions = UIng::Label.new("Default excludes unmapped, secondary, QC-failed and duplicate reads.")
      exclusions.set_minimum_size(0, -1)
      exclusions.tooltip = "Default exclude flags: 1796 (0x704). Supplementary alignments are not excluded."
      advanced_form.append("", exclusions)
      advanced_form.append("Read groups", @groups)
      @groups.tooltip = "Comma-separated RG identifiers. Blank includes all read groups."
      lengths = row
      lengths.append(@minimum, true)
      lengths.append(UIng::Label.new("to"), false)
      lengths.append(@maximum, true)
      advanced_form.append("Template length (bp)", lengths)
      advanced_form.append("", UIng::Label.new("Blank = no limit. Filters |TLEN| in every coverage mode."))
      @advanced.append(advanced_form, false)
      root.append(@advanced, false)
      @advanced.hide
      @status.set_minimum_size(0, 76)
      root.append(@status, true)
      @progress_slot.set_minimum_size(0, 12)
      @progress_slot.append(@progress, false)
      root.append(@progress_slot, false)
      buttons = row
      buttons.append(@create, false)
      buttons.append(@cancel, false)
      buttons.append(@add, false)
      buttons.append(UIng::Box.new(:horizontal), true)
      buttons.append(@close, false)
      root.append(buttons, false)
      @window.child = root
    end

    private def setup_handlers
      @input.on_changed do |text|
        @draft.output = @output.text || ""
        @draft.choose_input(text)
        @output.text = @draft.output
        sync_reference(true)
      end
      @input_browse.on_clicked do
        if path = @window.open_file
          @draft.output = @output.text || ""
          @draft.choose_input(path)
          @input.text = path
          @output.text = @draft.output
          sync_reference(true)
        end
      end
      @output_browse.on_clicked { @window.save_file.try { |path| @output.text = path } }
      @reference_browse.on_clicked { @window.open_file.try { |path| @reference.text = path } }
      @mode.on_selected { sync_mode }
      @advanced_toggle.on_clicked do
        @draft.advanced_open = !@draft.advanced_open?
        @draft.advanced_open? ? @advanced.show : @advanced.hide
        update_advanced_label
        width = @window.content_size[0]
        @window.set_content_size(width, @draft.advanced_open? ? 700 : 450)
      end
      [@exclude, @include, @groups, @minimum, @maximum].each { |entry| entry.on_changed { update_advanced_label } }
      @threads.on_changed { update_advanced_label }
      @create.on_clicked { create }
      @cancel.on_clicked { @worker.cancel; poll }
      @add.on_clicked { add_to_view }
      @close.on_clicked { @window.hide }
      @window.on_closing { @window.hide; false }
    end

    private def sync_mode
      @mode_hint.text = case @mode.selected || 0
                        when 1
                          "Includes CIGAR gaps; overlapping mates are counted twice."
                        when 2
                          "Counts proper paired-template spans, including the insert."
                        else
                          "Respects CIGAR gaps; overlapping mates are counted once."
                        end
    end

    private def sync_reference(editable)
      # Keep a provided reference visible when the next input is BAM; only pass
      # it for CRAM. Nonstandard input extensions may also need a reference.
      enabled = editable && !(@input.text || "").downcase.ends_with?(".bam")
      [@reference, @reference_browse].each { |control| enabled ? control.enable : control.disable }
    end

    private def read_draft
      @draft.input = @input.text || ""
      @draft.output = @output.text || ""
      @draft.reference = @reference.enabled? ? (@reference.text || "") : ""
      @draft.mode = CoverageMode.from_value(@mode.selected || 0)
      @draft.mapq = @mapq.value
      @draft.threads = @threads.value
      @draft.exclude_flags = @exclude.text || ""
      @draft.include_flags = @include.text || ""
      @draft.read_groups = @groups.text || ""
      @draft.min_fragment = @minimum.text || ""
      @draft.max_fragment = @maximum.text || ""
    end

    private def update_advanced_label
      read_draft
      action = @draft.advanced_open? ? "Hide" : "Show"
      @advanced_toggle.text = "#{action} advanced options#{@draft.advanced_modified? ? " (modified)" : ""}"
    end

    private def create
      if @worker.snapshot.state.succeeded?
        @worker.reset
        @added = false
        poll
        return
      end
      read_draft
      request = @draft.request
      request.validate!
      @worker.start(request)
      poll
    rescue ex
      field = ex.is_a?(ConversionError) ? ex.field : "Settings"
      set_status("#{field}: #{ex.message}\nCreation has not started.")
    end

    private def add_to_view
      return unless output = @worker.snapshot.output
      return if @added
      if @on_add.call(output)
        @added = true
        poll
      end
    end

    private def set_status(text)
      # The native macOS text view rejects programmatic replacement while
      # read-only. Temporarily enable edits; keep the resulting text selectable.
      @status.read_only = false
      @status.text = text
      @status.font_size = 13
      @status.read_only = true
    end
  end
end
