# frozen_string_literal: true

require 'fileutils'

# Purpose-built for ruby4-bundled-gems-suite.yml's "Build GTK3 binary gem
# suite" step specifically -- not a general gem-build framework. That step
# invokes `Rake::Task['build:gem'].invoke(gem_name)` from a harness root
# where gem sources (already classified/normalized/patched by
# Ruby4Lich5::NativeGemPreparer) have been copied to gems/<gem_name>/, and
# expects the built .gem to land in ./pkg/ -- the calling PowerShell takes
# it from there (copies it to the real package dir, runs `gem install
# --local`). DLL vendoring is deliberately NOT this Rakefile's job: the same
# workflow step already does a real, verified, consolidated DLL-closure walk
# (Add-DllClosure/Add-DllDependenciesFromPath) once, after every gem in this
# run has been built -- duplicating that per-gem here would be redundant at
# best and conflicting at worst.

GEMS_DIR = 'gems'
PKG_DIR = 'pkg'

# @param gem_name [String]
# @return [Boolean] true if this gem has a native extension to compile,
#   false for GObject-Introspection-only gems (atk/gdk3/gdk_pixbuf2) that
#   just need packaging
def has_native_extension?(gem_name)
  File.exist?(File.join(GEMS_DIR, gem_name, 'ext', gem_name, 'extconf.rb'))
end

namespace :build do
  desc 'Compile (if a native extension exists) and package a single gem, leaving the result in ./pkg/'
  task :gem, [:name] do |_t, args|
    gem_name = args.fetch(:name)
    gem_dir = File.join(GEMS_DIR, gem_name)
    abort "gem source not found: #{gem_dir}" unless Dir.exist?(gem_dir)

    # Computed *before* the chdir below -- has_native_extension? builds a path
    # relative to GEMS_DIR, which only resolves correctly from the harness
    # root. Calling it again from inside Dir.chdir(gem_dir) silently
    # double-applies gem_dir to the path and always returns false (caught by
    # a local smoke test before this ever touched real CI, not by inspection).
    native = has_native_extension?(gem_name)

    pkg_dir = File.expand_path(PKG_DIR)
    FileUtils.mkdir_p(pkg_dir)

    Dir.chdir(gem_dir) do
      if native
        ext_dir = File.join('ext', gem_name)
        Dir.chdir(ext_dir) do
          system('ruby', 'extconf.rb') or abort "extconf.rb failed for #{gem_name}"
          system('make') or abort "make failed for #{gem_name}"
        end

        module_name = gem_name.tr('-', '_')
        dlext = RbConfig::CONFIG.fetch('DLEXT')
        so_file = Dir.glob(File.join(ext_dir, "#{module_name}.#{dlext}")).first
        abort "no compiled #{module_name}.#{dlext} found under #{ext_dir}" unless so_file

        ruby_abi = RUBY_VERSION.split('.')[0, 2].join('.')
        lib_dir = File.join('lib', gem_name, ruby_abi)
        FileUtils.mkdir_p(lib_dir)
        FileUtils.cp(so_file, File.join(lib_dir, "#{module_name}.#{dlext}"))
      end

      system('gem', 'build', "#{gem_name}.gemspec") or abort "gem build failed for #{gem_name}"
      built = Dir.glob("#{gem_name}-*.gem").max_by { |path| File.mtime(path) }
      abort "no built .gem found for #{gem_name}" unless built

      FileUtils.mv(built, File.join(pkg_dir, File.basename(built)))
    end
  end
end
