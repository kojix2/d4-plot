require "./spec_helper"
require "../src/d4_plot/public_genes"

private def await_genes(loader : D4Plot::PublicGeneLoader, id : Int32) : D4Plot::PublicGeneResult
  deadline = Time.instant + 3.seconds
  loop do
    if result = loader.poll
      return result if result.request.id == id
    end
    raise "Timed out waiting for public genes" if Time.instant >= deadline
    sleep 1.millisecond
  end
end

describe D4Plot::PublicGenes do
  it "maps the four supported assemblies and conventional chromosome names" do
    {"hg38", "hg19", "mm39"}.each { |genome| D4Plot::PublicGenes.track_for(genome).should eq("knownGene") }
    D4Plot::PublicGenes.track_for("hs1").should eq("ncbiRefSeq")
    D4Plot::PublicGenes.remote_chromosome("1").should eq("chr1")
    D4Plot::PublicGenes.remote_chromosome("MT").should eq("chrM")
    D4Plot::PublicGenes.remote_chromosome("chrX").should eq("chrX")
    D4Plot::PublicGenes.remote_chromosome("contig1").should be_nil
    region = D4Plot::Region.new("1", 11_u32, 20_u32)
    path = D4Plot::PublicGenes.path("hg38", "chr1", region, 5)
    path.should contain("start=10")
    path.should contain("end=20")
    path.should contain("maxItemsOutput=6")
    D4Plot::PublicGenes.ensembl_host("hg19").should eq("https://grch37.rest.ensembl.org")
    {"hg38", "mm39"}.each { |genome| D4Plot::PublicGenes.ensembl_host(genome).should eq("https://rest.ensembl.org") }
    D4Plot::PublicGenes.ensembl_chromosome("chr1").should eq("1")
    D4Plot::PublicGenes.ensembl_chromosome("chrM").should eq("MT")
    D4Plot::PublicGenes.ensembl_path("mm39", "1", region).should contain("/mus_musculus/1:11-20")
    D4Plot::PublicGenes.ensembl_path("hg38", "1", region).should contain("feature=exon")
  end

  it "converts genePred transcript and exon boundaries into inclusive coordinates" do
    body = %({"knownGene":[{"chrom":"chr1","txStart":10,"txEnd":40,"exonStarts":"10,30,","exonEnds":"20,40,","name":"ENST1","geneName":"GENE1","strand":"+"}]})
    track = D4Plot::PublicGenes.parse(body, "hg38", "1", 10)
    gene = track.genes.first
    {gene.chromosome, gene.start1, gene.end1, gene.name, gene.strand}.should eq({"1", 11_u32, 40_u32, "GENE1", "+"})
    gene.exons.should eq([{11_u32, 20_u32}, {31_u32, 40_u32}])
  end

  it "reads bigGenePred block coordinates and reports a capped response" do
    body = %({"ncbiRefSeq":[{"chromStart":100,"chromEnd":150,"blockSizes":"10,20,","chromStarts":"0,30,","name":"NM_1","geneName":"NM_1","geneName2":"ABC"}]})
    gene = D4Plot::PublicGenes.parse(body, "hs1", "chr2", 10).genes.first
    gene.name.should eq("ABC")
    gene.exons.should eq([{101_u32, 110_u32}, {131_u32, 150_u32}])
    D4Plot::PublicGenes.parse(body, "hs1", "chr2", 0).notice.should eq(D4Plot.t("annotation.too_many", limit: 0))
  end

  it "groups Ensembl transcripts and exons by parent and keeps inclusive coordinates" do
    body = %([{"feature_type":"exon","Parent":"ENST1","start":11,"end":20},{"feature_type":"transcript","id":"ENST1","Parent":"ENSG1","start":10,"end":40,"strand":-1},{"feature_type":"gene","id":"ENSG1","external_name":"GENE1"},{"feature_type":"exon","Parent":"ENST1","start":30,"end":40}])
    track = D4Plot::PublicGenes.parse_ensembl(body, "chr1", 10)
    gene = track.genes.first
    {gene.chromosome, gene.start1, gene.end1, gene.name, gene.strand}.should eq({"chr1", 10_u32, 40_u32, "GENE1", "-"})
    gene.exons.should eq([{11_u32, 20_u32}, {30_u32, 40_u32}])
    D4Plot::PublicGenes.parse_ensembl(body, "chr1", 0).notice.should eq(D4Plot.t("annotation.too_many", limit: 0))
  end
end

describe D4Plot::PublicGeneLoader do
  it "fetches the same interval again after a repeat request" do
    calls = Atomic(Int32).new(0)
    fetcher = ->(_source : String, _genome : String, _chromosome : String, _region : D4Plot::Region, _limit : Int32) {
      # HTTPS reads crash Crystal 1.22's isolated event loop. Keep network jobs
      # on the concurrent context even when the fetcher is replaced in tests.
      Fiber::ExecutionContext.current.should be_a(Fiber::ExecutionContext::Concurrent)
      calls.add(1)
      %({"knownGene":[]})
    }
    loader = D4Plot::PublicGeneLoader.new(fetcher)
    begin
      region = D4Plot::Region.new("chr1", 1_u32, 10_u32)
      2.times do
        id = loader.submit("ucsc", "hg38", region, 10)
        await_genes(loader, id).track.notice.should eq(D4Plot.t("annotation.no_overlap"))
      end
      calls.get.should eq(2)
    ensure
      loader.close
      loader.wait
    end
  end

  it "keeps only the latest region and converts communication errors to a visible notice" do
    first_started = Atomic(Bool).new(false)
    fetcher = ->(_source : String, _genome : String, _chromosome : String, region : D4Plot::Region, _limit : Int32) {
      if region.start1 == 1_u32
        first_started.set(true)
        sleep 30.milliseconds
      end
      raise "offline" if region.start1 == 30_u32
      %({"knownGene":[{"txStart":#{region.start0},"txEnd":#{region.end1},"name":"NEW"}]})
    }
    loader = D4Plot::PublicGeneLoader.new(fetcher)
    begin
      loader.submit("ucsc", "hg38", D4Plot::Region.new("chr1", 1_u32, 10_u32), 10)
      deadline = Time.instant + 1.second
      until first_started.get
        raise "First public request did not start" if Time.instant >= deadline
        sleep 1.millisecond
      end
      latest = D4Plot::Region.new("chr1", 11_u32, 20_u32)
      id = loader.submit("ucsc", "hg38", latest, 10)
      result = await_genes(loader, id)
      result.request.region.should eq(latest)
      result.track.genes.first.start1.should eq(11_u32)
      id = loader.submit("ucsc", "hg38", D4Plot::Region.new("chr1", 30_u32, 40_u32), 10)
      await_genes(loader, id).track.notice.as(String).should contain("offline")
      id = loader.submit("ucsc", "hg38", D4Plot::Region.new("chr1", 1_u32, 5_000_002_u32), 10)
      await_genes(loader, id).track.notice.should eq(D4Plot.t("annotation.zoom_in"))
    ensure
      loader.close
      loader.wait
    end
  end

  it "discards a stale source response and reports unsupported Ensembl hs1" do
    started = Atomic(Bool).new(false)
    fetcher = ->(source : String, _genome : String, _chromosome : String, _region : D4Plot::Region, _limit : Int32) {
      if source == "ucsc"
        started.set(true)
        sleep 30.milliseconds
        %({"knownGene":[]})
      else
        %([{"feature_type":"transcript","id":"ENST1","start":2,"end":9}])
      end
    }
    loader = D4Plot::PublicGeneLoader.new(fetcher)
    begin
      region = D4Plot::Region.new("1", 1_u32, 10_u32)
      loader.submit("ucsc", "hg38", region, 10)
      deadline = Time.instant + 1.second
      until started.get
        raise "First public request did not start" if Time.instant >= deadline
        sleep 1.millisecond
      end
      id = loader.submit("ensembl", "hg38", region, 10)
      result = await_genes(loader, id)
      result.request.source.should eq("ensembl")
      result.track.genes.first.start1.should eq(2_u32)
      id = loader.submit("ensembl", "hs1", region, 10)
      await_genes(loader, id).track.notice.as(String).should contain("UCSC")
      id = loader.submit("ucsc", "hg38", D4Plot::Region.new("contig1", 1_u32, 10_u32), 10)
      await_genes(loader, id).track.notice.should eq(D4Plot.t("annotation.public_chromosome_unsupported", chromosome: "contig1".inspect))
    ensure
      loader.close
      loader.wait
    end
  end
end
