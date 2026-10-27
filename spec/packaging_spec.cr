require "./spec_helper"
require "file_utils"
require "yaml"

# These sandboxes use POSIX paths and tools; Windows packaging runs in MSYS2.
{% unless flag?(:win32) %}
  private class PackagingSandbox
    getter root : String

    def initialize
      @root = File.tempname("d4 packaging")
      Dir.mkdir(@root)
      %w[scripts bin assets tools Cellar].each { |name| Dir.mkdir(File.join(@root, name)) }
      repository = File.expand_path("..", __DIR__)
      %w[collect-licenses.sh collect-macos-licenses.sh package-macos.sh package-deb.sh].each do |name|
        FileUtils.cp(File.join(repository, "scripts", name), File.join(@root, "scripts", name))
      end
      %w[LICENSE README.md THIRD_PARTY_NOTICES.md shard.yml shard.lock].each do |name|
        FileUtils.cp(File.join(repository, name), File.join(@root, name))
      end
      File.symlink(File.join(repository, "lib"), File.join(@root, "lib"))
      FileUtils.mkdir_p(File.join(@root, "vendor"))
      File.symlink(File.join(repository, "vendor", "igv"), File.join(@root, "vendor", "igv"))
      %w[bin/d4-plot bin/d4-plot-server assets/d4-plot-256.png].each { |name| write(name, "fixture") }
      stub("brew", "printf '%s/Cellar\\n' \"$PWD\"")
      stub("otool", "printf '%s:\\n' \"$2\"; if [[ -f $2.deps ]]; then cat \"$2.deps\"; fi")
    end

    def write(path : String, contents : String)
      target = File.join(@root, path)
      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, contents)
    end

    def stub(name : String, body : String)
      write("tools/#{name}", "#!/bin/bash\nset -euo pipefail\n#{body}\n")
      File.chmod(File.join(@root, "tools", name), 0o755)
    end

    def run(script : String, arguments = [] of String, fail_image : Bool = false)
      output = IO::Memory.new
      error = IO::Memory.new
      status = Process.run("bash", ["scripts/#{script}"] + arguments, chdir: @root,
        env: {"PATH" => "#{@root}/tools:#{ENV["PATH"]}", "D4_TEST_FAIL_IMAGE" => fail_image.to_s},
        output: output, error: error)
      {status: status, output: output.to_s, error: error.to_s}
    end

    def close
      FileUtils.rm_rf(@root)
    end
  end

  private def with_packaging_sandbox(&)
    sandbox = PackagingSandbox.new
    begin
      yield sandbox
    ensure
      sandbox.close
    end
  end

  describe "Packaging scripts" do
    it "includes every runtime shard's license" do
      with_packaging_sandbox do |sandbox|
        result = sandbox.run("collect-licenses.sh", ["licenses"])
        result[:status].success?.should be_true
        dependencies = YAML.parse(File.read(File.join(sandbox.root, "shard.yml")))["dependencies"].as_h
        dependencies.each_key do |dependency|
          File.file?(File.join(sandbox.root, "licenses", dependency.as_s, "LICENSE")).should be_true
        end
        File.file?(File.join(sandbox.root, "licenses/igv.js/LICENSE")).should be_true
      end
    end

    it "collects transitive Homebrew licenses through opt links and rejects missing texts" do
      with_packaging_sandbox do |sandbox|
        sandbox.write("Cellar/gmp/6.3/lib/libgmp.dylib", "library")
        sandbox.write("Cellar/gmp/6.3/COPYING", "GMP")
        sandbox.write("Cellar/openssl@4/4.1/lib/libssl.dylib", "library")
        sandbox.write("Cellar/openssl@4/4.1/LICENSE.txt", "OpenSSL 4")
        FileUtils.mkdir_p(File.join(sandbox.root, "opt"))
        File.symlink("../Cellar/gmp/6.3", File.join(sandbox.root, "opt/gmp"))
        gmp = File.join(sandbox.root, "opt/gmp/lib/libgmp.dylib")
        ssl = File.join(sandbox.root, "Cellar/openssl@4/4.1/lib/libssl.dylib")
        sandbox.write("bin/d4-plot.deps", "\t#{gmp} (compatibility version 1.0.0, current version 1.0.0)\n")
        sandbox.write("Cellar/gmp/6.3/lib/libgmp.dylib.deps", "\t#{ssl} (compatibility version 1.0.0, current version 1.0.0)\n")
        sandbox.write("Cellar/openssl@4/4.1/lib/libssl.dylib.deps", "\t#{gmp} (compatibility version 1.0.0, current version 1.0.0)\n\t/usr/lib/libz.1.dylib (compatibility version 1.0.0, current version 1.0.0)\n")
        result = sandbox.run("collect-macos-licenses.sh", ["licenses", "bin/d4-plot", "bin/d4-plot-server"])
        result[:status].success?.should be_true
        Dir.children(File.join(sandbox.root, "licenses")).sort.should eq(["gmp", "openssl@4"])
        File.read(File.join(sandbox.root, "licenses/gmp/COPYING")).should eq("GMP")
        File.read(File.join(sandbox.root, "licenses/openssl@4/LICENSE.txt")).should eq("OpenSSL 4")

        File.delete(File.join(sandbox.root, "Cellar/openssl@4/4.1/LICENSE.txt"))
        result = sandbox.run("collect-macos-licenses.sh", ["missing-licenses", "bin/d4-plot"])
        result[:status].success?.should be_false
        result[:error].should contain("No license texts found")
      end
    end

    it "rebuilds macOS resources from scratch and preserves outputs when image creation fails" do
      with_packaging_sandbox do |sandbox|
        sandbox.stub("crystal", "touch \"${@: -1}\"")
        sandbox.stub("dylibbundler", ":")
        sandbox.stub("codesign", ":")
        sandbox.stub("ditto", "cp -R \"$1\" \"$2\"")
        sandbox.stub("hdiutil", <<-SH)
        source_directory=
        while (( $# > 1 )); do
          if [[ $1 == -srcfolder ]]; then source_directory=$2; fi
          shift
        done
        [[ $D4_TEST_FAIL_IMAGE != true ]] || exit 1
        test -L "$source_directory/Applications"
        find "$source_directory" -type f > "$1"
        SH
        sandbox.write("dist/d4-plot.app/Contents/Resources/obsolete.txt", "old")
        sandbox.write("dist/d4-plot-vtest-macos-arm64.dmg", "previous image")
        result = sandbox.run("package-macos.sh", ["vtest", "arm64"])
        result[:status].success?.should be_true
        File.exists?(File.join(sandbox.root, "dist/d4-plot.app/Contents/Resources/obsolete.txt")).should be_false
        File.file?(File.join(sandbox.root, "dist/d4-plot.app/Contents/Resources/licenses/bigwig/LICENSE")).should be_true

        sandbox.write("dist/d4-plot.app/Contents/Resources/keep.txt", "previous app")
        sandbox.write("dist/d4-plot-vtest-macos-arm64.dmg", "previous image")
        result = sandbox.run("package-macos.sh", ["vtest", "arm64"], fail_image: true)
        result[:status].success?.should be_false
        File.read(File.join(sandbox.root, "dist/d4-plot.app/Contents/Resources/keep.txt")).should eq("previous app")
        File.read(File.join(sandbox.root, "dist/d4-plot-vtest-macos-arm64.dmg")).should eq("previous image")
        Dir.children(File.join(sandbox.root, "build")).should be_empty
      end
    end

    it "builds Debian packages without old staging files and retains the last successful archive" do
      with_packaging_sandbox do |sandbox|
        sandbox.stub("dpkg-shlibdeps", "echo 'shlibs:Depends=libc6'")
        sandbox.stub("dpkg-deb", <<-SH)
        [[ $D4_TEST_FAIL_IMAGE != true ]] || exit 1
        find "$3" -type f > "$4"
        SH
        sandbox.write("build/package-deb/debian/d4-plot/obsolete.txt", "old")
        result = sandbox.run("package-deb.sh", ["v0.0.8"])
        result[:status].success?.should be_true
        archive = File.join(sandbox.root, "dist/d4-plot_0.0.8_amd64.deb")
        contents = File.read(archive)
        contents.should_not contain("obsolete.txt")
        contents.should contain("licenses/http_proxy/LICENSE")
        result = sandbox.run("package-deb.sh", ["v0.0.8"], fail_image: true)
        result[:status].success?.should be_false
        File.read(archive).should eq(contents)
        Dir.children(File.join(sandbox.root, "build")).should eq(["package-deb"])
      end
    end
  end
{% end %}
