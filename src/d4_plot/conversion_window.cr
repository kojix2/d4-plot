require "uing"
require "./i18n"
require "./conversion_draft"
require "./conversion_worker"

module D4Plot
  # Hiding this window does not destroy the draft or cancel its independent job.
  class ConversionWindow
    @window = UIng::Window.new(D4Plot.t("conversion.title"), 720, 600, margined: true)
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
    @tabs = UIng::Tab.new
    @advanced = UIng::Box.new(:vertical, padded: true)
    @advanced_notice = UIng::Label.new("")
    @reference_section = UIng::Box.new(:vertical, padded: true)
    @idle_note = UIng::Label.new(D4Plot.t("conversion.ready"))
    @status = UIng::MultilineEntry.new(read_only: true)
    @progress = UIng::ProgressBar.new
    @progress_slot = UIng::Box.new(:vertical)
    @create = UIng::Button.new(D4Plot.t("app.create_d4"))
    @cancel = UIng::Button.new(D4Plot.t("conversion.cancel_creation"))
    @add = UIng::Button.new(D4Plot.t("conversion.add_to_view"))
    @close = UIng::Button.new(D4Plot.t("settings.close"))
    @last_display = ""
    @added = false
    @adding = false
    @destroyed = false

    def initialize(@worker : ConversionWorker, @on_add : Proc(String, Proc(Bool, Nil), Bool))
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
      @destroyed = true
      @window.destroy
    end

    def poll
      snapshot = @worker.snapshot
      state = snapshot.state
      progress = snapshot.progress
      seconds = snapshot.elapsed.total_seconds.to_i
      display = "#{state}:#{progress}:#{seconds}:#{snapshot.error}:#{@added}:#{@adding}"
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
        set_enabled(control, editable)
      end
      sync_reference(editable)
      set_enabled(@create, !state.active? && !@adding)
      set_enabled(@cancel, state.running?)
      set_enabled(@add, state.succeeded? && !@added && !@adding)
      @add.text = D4Plot.t(@adding ? "conversion.adding" : "conversion.add_to_view")
      @create.text = state.succeeded? ? D4Plot.t("conversion.create_another") : D4Plot.t("conversion.start_creation")
      @close.text = state.active? ? D4Plot.t("conversion.close_running") : D4Plot.t("settings.close")
      set_visible(@create, !state.active?)
      set_visible(@cancel, state.active?)
      set_visible(@add, state.succeeded?)
    end

    private def set_enabled(control, enabled : Bool) : Nil
      enabled ? control.enable : control.disable
    end

    private def set_visible(control, visible : Bool) : Nil
      visible ? control.show : control.hide
    end

    private def update_progress(state) : Nil
      if state.active?
        @progress.value = -1
        @progress.show
        @progress_slot.show
      else
        @progress.hide
        @progress_slot.hide
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
      button.set_minimum_size(76, -1)
      box = row
      box.append(entry, true)
      box.append(button, false)
      box
    end

    private def setup_ui
      root = UIng::Box.new(:vertical, padded: true)
      header = row
      title = UIng::Label.new(D4Plot.t("conversion.title"))
      title.font_size = 20
      header.append(title, true)
      @advanced_notice.font_size = 11
      header.append(@advanced_notice, false)
      @advanced_notice.hide
      root.append(header, false)
      root.append(hint("conversion.description"), false)
      @tabs.append(D4Plot.t("conversion.basic_settings"), basic_settings, margined: true)
      setup_advanced
      @tabs.append(D4Plot.t("conversion.advanced_settings"), @advanced, margined: true)
      root.append(@tabs, true)
      root.append(UIng::Separator.new(:horizontal), false)
      @idle_note.font_size = 12
      @idle_note.set_minimum_size(0, -1)
      root.append(@idle_note, false)
      @status.set_minimum_size(0, 88)
      root.append(@status, false)
      @status.hide
      @progress_slot.append(@progress, false)
      root.append(@progress_slot, false)
      @progress_slot.hide
      buttons = row
      buttons.append(@close, false)
      buttons.append(UIng::Box.new(:horizontal), true)
      buttons.append(@cancel, false)
      buttons.append(@create, false)
      buttons.append(@add, false)
      root.append(buttons, false)
      @window.child = root
    end

    private def hint(key : String) : UIng::Label
      label = UIng::Label.new(D4Plot.t(key))
      label.font_size = 11
      label.set_minimum_size(0, -1)
      label.tooltip = D4Plot.t(key)
      label
    end

    private def group(title : String, content : UIng::Control) : UIng::Group
      section = UIng::Group.new(D4Plot.t(title), margined: true)
      section.child = content
      section
    end

    private def compact(control : UIng::Control, width = 100) : UIng::Box
      control.set_minimum_size(width, -1)
      box = row
      box.append(control, false)
      box.append(UIng::Box.new(:horizontal), true)
      box
    end

    private def basic_settings : UIng::Box
      page = UIng::Box.new(:vertical, padded: true)
      files = UIng::Box.new(:vertical, padded: true)
      form = UIng::Form.new(padded: true)
      form.append(D4Plot.t("conversion.input"), path_row(@input, @input_browse))
      form.append("", hint("conversion.input_hint"))
      form.append(D4Plot.t("conversion.output"), path_row(@output, @output_browse))
      files.append(form, false)
      reference_form = UIng::Form.new(padded: true)
      reference_form.append(D4Plot.t("conversion.reference"), path_row(@reference, @reference_browse))
      reference_form.append("", hint("conversion.reference_hint"))
      @reference_section.append(reference_form, false)
      files.append(@reference_section, false)
      page.append(group("conversion.files_section", files), false)

      coverage = UIng::Box.new(:vertical, padded: true)
      ["conversion.standard", "conversion.fast", "conversion.fragments"].each { |key| @mode.append(D4Plot.t(key)) }
      @mode.selected = 0
      coverage.append(@mode, false)
      @mode_hint.font_size = 11
      @mode_hint.set_minimum_size(0, -1)
      coverage.append(@mode_hint, false)
      page.append(group("conversion.coverage", coverage), false)
      page.append(UIng::Box.new(:vertical), true)
      page
    end

    private def setup_advanced
      filters = UIng::Form.new(padded: true)
      filters.append(D4Plot.t("conversion.minimum_mapq"), compact(@mapq))
      @exclude.text = "1796"
      @include.text = "0"
      @exclude.tooltip = "#{D4Plot.t("conversion.flags_hint")}\n#{D4Plot.t("conversion.default_excludes")}\n#{D4Plot.t("conversion.default_excludes_tip")}"
      @include.tooltip = D4Plot.t("conversion.flags_hint")
      filters.append(D4Plot.t("conversion.exclude_flags"), compact(@exclude, 120))
      filters.append(D4Plot.t("conversion.include_flags"), compact(@include, 120))
      filters.append(D4Plot.t("conversion.read_groups"), @groups)
      @groups.tooltip = D4Plot.t("conversion.read_groups_tip")
      @groups.set_minimum_size(0, -1)
      lengths = row
      @minimum.set_minimum_size(0, -1)
      @maximum.set_minimum_size(0, -1)
      @minimum.tooltip = D4Plot.t("conversion.template_length_hint")
      @maximum.tooltip = D4Plot.t("conversion.template_length_hint")
      lengths.append(@minimum, true)
      lengths.append(UIng::Label.new(D4Plot.t("conversion.to")), false)
      lengths.append(@maximum, true)
      filters.append(D4Plot.t("conversion.template_length"), lengths)
      filters.append("", hint("conversion.template_length_hint"))
      @advanced.append(group("conversion.filters_section", filters), false)
      processing = UIng::Form.new(padded: true)
      processing.append(D4Plot.t("conversion.decompression_threads"), compact(@threads))
      processing.append("", hint("conversion.threads_hint"))
      @advanced.append(group("conversion.processing_section", processing), false)
      @advanced.append(UIng::Box.new(:vertical), true)
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
      @tabs.on_selected { |index| @draft.advanced_open = index == 1 }
      [@exclude, @include, @groups, @minimum, @maximum].each { |entry| entry.on_changed { update_advanced_label } }
      @threads.on_changed { update_advanced_label }
      @mapq.on_changed { update_advanced_label }
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
      @mode_hint.tooltip = @mode_hint.text
    end

    private def sync_reference(editable)
      # Keep a provided reference visible when the next input is BAM; only pass
      # it for CRAM. Nonstandard input extensions may also need a reference.
      enabled = editable && !(@input.text || "").downcase.ends_with?(".bam")
      path = (@input.text || "").strip.downcase
      needed = (!path.empty? && !path.ends_with?(".bam")) || !entry_text(@reference).empty?
      needed ? @reference_section.show : @reference_section.hide
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
      @advanced_notice.text = D4Plot.t("conversion.advanced_settings") + D4Plot.t("conversion.modified")
      @draft.advanced_modified? ? @advanced_notice.show : @advanced_notice.hide
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
      return if @added || @adding
      @adding = true
      poll
      accepted = @on_add.call(output, ->(success : Bool) {
        @adding = false
        @added = success
        poll unless @destroyed
        nil
      })
      unless accepted
        @adding = false
        poll unless @destroyed
      end
    end

    private def set_status(text)
      if @worker.snapshot.state.idle? && text == D4Plot.t("conversion.ready")
        @status.hide
        @idle_note.show
        return
      end
      @idle_note.hide
      @status.show
      # The native macOS text view rejects programmatic replacement while
      # read-only. Temporarily enable edits; keep the resulting text selectable.
      @status.read_only = false
      @status.text = text
      @status.font_size = 12
      @status.read_only = true
    end
  end
end
