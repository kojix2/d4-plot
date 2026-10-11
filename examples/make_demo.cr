require "d4"

# Synthetic signals only; these are not patient data or biological estimates.
directory = ARGV[0]? || "demo"
Dir.mkdir_p(directory)
{"control", "amplification", "deletion", "negative", "replicate"}.each_with_index do |name, index|
  values = Array(Int32).new(20_000) do |i|
    value = 30 + (8 * Math.sin(i / 700.0)).round.to_i
    value += 90 if index == 1 && 8_000 <= i < 12_000
    value = 5 if index == 2 && 8_000 <= i < 12_000
    value -= 35 if index == 3
    value += (5 * Math.cos(i / 300.0)).round.to_i if index == 4
    value
  end
  path = File.join(directory, "#{name}.d4")
  raise "Refusing to overwrite #{path}" if File.exists?(path)
  D4.create(path, chromosomes: [D4::Chromosome.new("chr1", values.size)]) do |writer|
    writer.write_values("chr1", 0, values)
  end
  puts path
end
