# Build a macOS icon from the checked-in PNG using macOS's sips.
require "file/tempfile"

abort "Usage: crystal run scripts/make-icns.cr -- SOURCE.png OUTPUT.icns" unless ARGV.size == 2
source, output = ARGV

# ICNS stores PNGs for these modern icon sizes, including Retina variants.
entries = {
  "ic07" => 128,
  "ic08" => 256,
  "ic09" => 512,
  "ic10" => 1024,
  "ic11" => 32,
  "ic12" => 64,
  "ic13" => 256,
  "ic14" => 512,
}

images = {} of Int32 => Bytes
parts = entries.map do |code, size|
  data = images[size]? || begin
    tempfile = File.tempfile("d4-plot-icon", ".png")
    tempfile.close
    begin
      status = Process.run("sips", ["-z", size.to_s, size.to_s, source, "--out", tempfile.path])
      raise "sips failed for #{size}x#{size}" unless status.success?
      File.read(tempfile.path).to_slice.dup
    ensure
      tempfile.delete
    end
  end
  images[size] = data
  {code, data}
end

total_size = 8 + parts.sum { |part| 8 + part[1].size }
File.open(output, "wb") do |file|
  file.print "icns"
  file.write_bytes(total_size.to_u32, IO::ByteFormat::BigEndian)
  parts.each do |code, data|
    file.print code
    file.write_bytes((data.size + 8).to_u32, IO::ByteFormat::BigEndian)
    file.write(data)
  end
end
