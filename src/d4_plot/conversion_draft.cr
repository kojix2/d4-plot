require "./conversion"

module D4Plot
  # Presentation rules without native controls: keep a user's chosen output,
  # parse advanced inputs, and make hidden option changes visible.
  class ConversionDraft
    property input = ""
    property output = ""
    property reference = ""
    property mode = CoverageMode::Standard
    property mapq = 0
    property threads = 2
    property exclude_flags = "1796"
    property include_flags = "0"
    property read_groups = ""
    property min_fragment = ""
    property max_fragment = ""
    property? advanced_open = false
    @suggested_output = ""

    def choose_input(path : String)
      @input = path
      suggested = File.join(File.dirname(path), "#{File.basename(path, File.extname(path))}.d4")
      if @output.empty? || @output == @suggested_output
        @output = suggested
      end
      @suggested_output = suggested
    end

    def cram?
      input.downcase.ends_with?(".cram")
    end

    def advanced_modified?
      mapq != 0 || threads != 2 || exclude_flags != "1796" || include_flags != "0" || !read_groups.strip.empty? ||
        !min_fragment.strip.empty? || !max_fragment.strip.empty?
    end

    def request
      ConversionRequest.new(input: File.expand_path(input), output: File.expand_path(output),
        reference: reference.strip.empty? ? "" : File.expand_path(reference), mode: mode,
        mapq: mapq, threads: threads, exclude_flags: flags(exclude_flags, D4Plot.t("fields.exclude_flags")),
        include_flags: flags(include_flags, D4Plot.t("fields.include_flags")),
        read_groups: read_groups.split(',').map(&.strip).reject(&.empty?),
        min_fragment: length(min_fragment), max_fragment: length(max_fragment))
    end

    private def flags(text, field)
      value = text.strip
      parsed = value.downcase.starts_with?("0x") ? value[2..].to_u16?(16) : value.to_u16?
      parsed || raise ConversionError.new(field, D4Plot.t("errors.flags_range"))
    end

    private def length(text)
      return -1 if text.strip.empty?
      value = text.strip.to_i32?
      raise ConversionError.new(D4Plot.t("fields.fragment_length"), D4Plot.t("errors.fragment_length")) unless value && value >= 0
      value
    end
  end
end
