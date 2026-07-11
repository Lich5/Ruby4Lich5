# frozen_string_literal: true

require 'ruby4lich5/gem_manifest_generator'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'digest'
require 'open3'
require 'rubygems/package'

# Real subprocess integration test for bin/generate_gem_manifest.rb -- proves
# the CLI's own ARGV-parsing/wiring (StagedGemSpecFinder,
# NativeGemDigestFetcher, JSON output, exit codes) works end to end as an
# actual external process, not just via internal Ruby doubles the way
# gem_manifest_generator_spec.rb already covers the generator's own logic.
#
# Deliberately native-gems-only, no pure gems: a pure gem's digest check
# calls out to the real RubyGems.org API (RubygemsClient's real HTTP
# default), which this suite otherwise never does (every other pure-gem
# digest spec injects a stub). Keeping this one network-free means it stays
# fast and doesn't make CI depend on RubyGems.org being reachable -- the
# pure-gem cross-check path itself is already locked at the unit level in
# gem_manifest_generator_spec.rb.
RSpec.describe 'bin/generate_gem_manifest.rb (CLI integration)' do
  def build_real_gem(dir, name, version)
    spec = Gem::Specification.new(name, version) { |s| s.summary = 'fixture'; s.authors = ['fixture']; s.files = [] }
    Dir.chdir(dir) { Gem::Package.build(spec) }
  end

  # A minimal fake `gh`, first on PATH for the subprocess -- returns a
  # canned "release view"-shaped response naming the real sha256 of the
  # staged .gem file its own tag argument refers to, so the CLI's own
  # NativeGemDigestFetcher gets a real, verifiable digest without touching
  # a real GitHub API. Keyed by the *exact* tag NativeGemDigestFetcher
  # constructs (+"R4L5-<name>-<version>-<platform>"+), not a name prefix --
  # a loose prefix match would wrongly resolve e.g. "cairo-gobject"'s tag to
  # plain "cairo"'s digest, since one is a real string prefix of the other.
  def write_fake_gh(bin_dir, pkg_dir, name_versions, platform: 'x64-mingw-ucrt')
    digests = name_versions.to_h do |name, version|
      path = File.join(pkg_dir, "#{name}-#{version}.gem")
      tag = "R4L5-#{name}-#{version}-#{platform}"
      [tag, "sha256:#{Digest::SHA256.file(path).hexdigest}"]
    end

    script = <<~RUBY
      #!/usr/bin/env ruby
      require 'json'
      tag_arg = ARGV.find { |a| a.start_with?('repos/') }
      tag = tag_arg.split('/').last
      digests = #{digests.inspect}
      digest = digests[tag]
      abort "fake gh: no canned digest for tag \#{tag}" unless digest
      puts({ assets: [{ name: "\#{tag}.gem", digest: digest }] }.to_json)
    RUBY
    path = File.join(bin_dir, 'gh')
    File.write(path, script)
    FileUtils.chmod('+x', path)
  end

  around do |example|
    Dir.mktmpdir('generate-gem-manifest-cli-spec-') do |root|
      @pkg_dir = File.join(root, 'pkg')
      @bin_dir = File.join(root, 'bin')
      @out_path = File.join(root, 'manifest.json')
      FileUtils.mkdir_p(@pkg_dir)
      FileUtils.mkdir_p(@bin_dir)
      example.run
    end
  end

  it 'generates a real manifest from real staged .gem files via a real subprocess' do
    all_native = Ruby4Lich5::GemManifestGenerator::GTK3_STACK + %w[sqlite3]
    versions = all_native.to_h { |name| [name, '1.0.0'] }
    versions.each { |name, version| build_real_gem(@pkg_dir, name, version) }
    write_fake_gh(@bin_dir, @pkg_dir, versions)

    cli_path = File.expand_path('../../bin/generate_gem_manifest.rb', __dir__)
    env = { 'PATH' => "#{@bin_dir}:#{ENV.fetch('PATH', nil)}" }
    args = ['sqlite3', '', '4.0', 'x64-mingw-ucrt', 'Lich5/Ruby4Lich5', 'R4L5-gem-bundle-x64-mingw-ucrt-candidate',
            'R4L5-gem-bundle-x64-mingw-ucrt.zip', "sha256:#{'c' * 64}", @pkg_dir, @out_path]

    stdout_and_err, status = Open3.capture2e(env, 'ruby', cli_path, *args)

    expect(status).to be_success, "CLI failed: #{stdout_and_err}"
    expect(File.exist?(@out_path)).to be(true)

    manifest = JSON.parse(File.read(@out_path))
    units = manifest['targets'].first['units']
    expect(units.map { |u| u['id'] }).to contain_exactly('gtk3-runtime', 'sqlite3')

    sqlite3_unit = units.find { |u| u['id'] == 'sqlite3' }
    expect(sqlite3_unit['artifact']['archive']).to eq('gem')
    expected_digest = "sha256:#{Digest::SHA256.file(Dir.glob(File.join(@pkg_dir, 'sqlite3-*.gem')).first).hexdigest}"
    expect(sqlite3_unit['packages'].first['sha256']).to eq(expected_digest)

    # The bundle-artifact unit must carry *this run's own* tag (the
    # candidate passed on the command line), never a hardcoded live one --
    # the real bug this whole design fixes (2026-07-10 review finding).
    gtk3_unit = units.find { |u| u['id'] == 'gtk3-runtime' }
    expect(gtk3_unit['artifact']['url']).to start_with(
      'https://github.com/Lich5/Ruby4Lich5/releases/download/R4L5-gem-bundle-x64-mingw-ucrt-candidate/'
    )
  end

  it 'exits nonzero and writes nothing when a declared native gem was never staged' do
    write_fake_gh(@bin_dir, @pkg_dir, {})
    cli_path = File.expand_path('../../bin/generate_gem_manifest.rb', __dir__)
    env = { 'PATH' => "#{@bin_dir}:#{ENV.fetch('PATH', nil)}" }
    args = ['sqlite3', '', '4.0', 'x64-mingw-ucrt', 'Lich5/Ruby4Lich5', 'R4L5-gem-bundle-x64-mingw-ucrt-candidate',
            'R4L5-gem-bundle-x64-mingw-ucrt.zip', "sha256:#{'c' * 64}", @pkg_dir, @out_path]

    _stdout_and_err, status = Open3.capture2e(env, 'ruby', cli_path, *args)

    expect(status).not_to be_success
    expect(File.exist?(@out_path)).to be(false)
  end
end
