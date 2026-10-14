require "hts/tabix"

module AnnotationFixtures
  def self.with_indexed(contents : String, extension = ".bed", preset = :bed, min_shift = 0, &)
    path = File.tempname("d4-plot-annotation", "#{extension}.gz")
    begin
      HTS::Bgzf.open(path, "wz") { |file| file.write(contents) }
      HTS::Tabix.build_index(path, preset: preset, min_shift: min_shift, verbose: false)
      yield path
    ensure
      [path, "#{path}.tbi", "#{path}.csi"].each { |file| File.delete(file) if File.exists?(file) }
    end
  end
end
