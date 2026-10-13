require "uing"
require "./i18n"
require "./conversion_draft"
require "./conversion_worker"

module D4Plot
  # Hiding this window does not destroy the draft or cancel its independent job.
  class ConversionWindow
    @window = UIng::Window.new(D4Plot.t("conversion.title"), 660, 450, margined: true)
    @draft = ConversionDraft.new
    @input = UIng::Entry.new
    @output = UIng::Entry.new
    @reference = UIng::Entry.new
    @input_browse = UIng::Button.new(D4Plot.t("conversion.browse"))
    @output_browse = UIng::Button.new(D4Plot.t("conversion.choose"))
    @reference_browse = UIng::Button.new(D4Plot.t("conversion.browse"))
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
    @advanced_toggle = UIng::Button.new(D4Plot.t("conversion.show_advanced"))
    @status = UIng::MultilineEntry.new(read_only: true)
    @progress = UIng::ProgressBar.new
    @progress_slot = UIng::Box.new(:vertical)
    @create = UIng::Button.new(D4Plot.t("app.create_d4"))
    @cancel = UIng::Button.new(D4Plot.t("conversion.cancel_creation"))
    @add = UIng::Button.new(D4Plot.t("conversion.add_to_view"))
    @close = UIng::Button.new(D4Plot.t("settings.close"))
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
      editable = state.editable?
      update_controls(state, editable)
      update_progress(state)
      set_status(status_text(snapshot, seconds))
    end

    private def update_controls(state, editable) : Nil
      [@input, @output, @input_browse, @output_browse, @mode, @mapq,
       @threads, @exclude, @include, @groups, @minimum, @maximum].each do |control|
        editable ? control.enable : control.disable
      end
      sync_reference(editable)
      state.active? ? @create.disable : @create.enable
      state.running? ? @cancel.enable : @cancel.disable
      state.succeeded? && !@added ? @add.enable : @add.disable
      @create.text = state.succeeded? ? D4Plot.t("conversion.create_another") : D4Plot.t("app.create_d4")
      @close.text = state.active? ? D4Plot.t("conversion.close_running") : D4Plot.t("settings.close")
    end

    private def update_progress(state) : Nil
      if state.active?
        @progress.value = -1
        @progress.show
      else
        @progress.hide
      end
    end

    private def status_text(snapshot, seconds) : String
      state = snapshot.state
      progress = snapshot.progress
      case state
      when .idle?
        D4Plot.t("conversion.ready")
      when .running?, .cancelling?
        phase = state.cancelling? ? D4Plot.t("conversion.cancelling_wait") : progress.stage
        location = progress.total > 0 ? D4Plot.t("conversion.progress_location", chromosome: progress.chromosome,
          current: progress.current, total: progress.total) : ""
        D4Plot.t("conversion.progress", phase: phase, location: location, records: progress.records, seconds: seconds)
      when .succeeded?
        D4Plot.t("conversion.succeeded", seconds: seconds, output: snapshot.output,
          next_step: D4Plot.t(@added ? "conversion.added" : "conversion.review"))
      when .cancelled?
        D4Plot.t("conversion.cancelled")
      else
        D4Plot.t("conversion.failed", field: snapshot.field || D4Plot.t("conversion.creation"), error: snapshot.error)
      end
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
      root.append(UIng::Label.new(D4Plot.t("conversion.description")), false)
      form = UIng::Form.new(padded: true)
      form.append(D4Plot.t("conversion.input"), path_row(@input, @input_browse))
      form.append("", UIng::Label.new(D4Plot.t("conversion.input_hint")))
      form.append(D4Plot.t("conversion.output"), path_row(@output, @output_browse))
      form.append(D4Plot.t("conversion.reference"), path_row(@reference, @reference_browse))
      form.append("", UIng::Label.new(D4Plot.t("conversion.reference_hint")))
      ["conversion.standard", "conversion.fast", "conversion.fragments"].each { |key| @mode.append(D4Plot.t(key)) }
      @mode.selected = 0
      form.append(D4Plot.t("conversion.coverage"), @mode)
      form.append("", @mode_hint)
      form.append(D4Plot.t("conversion.minimum_mapq"), @mapq)
      root.append(form, false)
      root.append(@advanced_toggle, false)

      advanced_form = UIng::Form.new(padded: true)
      advanced_form.append(D4Plot.t("conversion.decompression_threads"), @threads)
      advanced_form.append("", UIng::Label.new(D4Plot.t("conversion.threads_hint")))
      @exclude.text = "1796"
      @include.text = "0"
      advanced_form.append(D4Plot.t("conversion.exclude_flags"), @exclude)
      advanced_form.append(D4Plot.t("conversion.include_flags"), @include)
      advanced_form.append("", UIng::Label.new(D4Plot.t("conversion.flags_hint")))
      exclusions = UIng::Label.new(D4Plot.t("conversion.default_excludes"))
      exclusions.set_minimum_size(0, -1)
      exclusions.tooltip = D4Plot.t("conversion.default_excludes_tip")
      advanced_form.append("", exclusions)
      advanced_form.append(D4Plot.t("conversion.read_groups"), @groups)
      @groups.tooltip = D4Plot.t("conversion.read_groups_tip")
      lengths = row
      lengths.append(@minimum, true)
      lengths.append(UIng::Label.new(D4Plot.t("conversion.to")), false)
      lengths.append(@maximum, true)
      advanced_form.append(D4Plot.t("conversion.template_length"), lengths)
      advanced_form.append("", UIng::Label.new(D4Plot.t("conversion.template_length_hint")))
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
                          D4Plot.t("conversion.fast_hint")
                        when 2
                          D4Plot.t("conversion.fragments_hint")
                        else
                          D4Plot.t("conversion.standard_hint")
                        end
    end

    private def sync_reference(editable)
      # Keep a provided reference visible when the next input is BAM; only pass
      # it for CRAM. Nonstandard input extensions may also need a reference.
      enabled = editable && !(@input.text || "").downcase.ends_with?(".bam")
      [@reference, @reference_browse].each { |control| enabled ? control.enable : control.disable }
    end

    private def read_draft
      @draft.input = entry_text(@input)
      @draft.output = entry_text(@output)
      @draft.reference = @reference.enabled? ? entry_text(@reference) : ""
      @draft.mode = CoverageMode.from_value(@mode.selected || 0)
      @draft.mapq = @mapq.value
      @draft.threads = @threads.value
      @draft.exclude_flags = entry_text(@exclude)
      @draft.include_flags = entry_text(@include)
      @draft.read_groups = entry_text(@groups)
      @draft.min_fragment = entry_text(@minimum)
      @draft.max_fragment = entry_text(@maximum)
    end

    private def entry_text(entry) : String
      entry.text || ""
    end

    private def update_advanced_label
      read_draft
      @advanced_toggle.text = D4Plot.t(@draft.advanced_open? ? "conversion.hide_advanced" : "conversion.show_advanced") +
                              (@draft.advanced_modified? ? D4Plot.t("conversion.modified") : "")
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
      field = ex.is_a?(ConversionError) ? ex.field : D4Plot.t("fields.settings")
      set_status(D4Plot.t("conversion.not_started", field: field, error: ex.message))
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
