module D4Plot
  VERSION = {{ read_file("#{__DIR__}/../../shard.yml").split("version: ")[1].lines.first }}
end
