#!/usr/bin/env ruby

require "fileutils"
require "open3"
require "shellwords"

include FileUtils::Verbose

def safe_system(*args)
  puts args.shelljoin
  system(*args) || abort("Fail to run the last command!")
end

class DylibFile
  OTOOL_RX = /\t(.*) \(compatibility version (?:\d+\.)*\d+, current version (?:\d+\.)*\d+\)/

  attr_reader :path, :id, :deps

  def initialize(path)
    @path = path
    parse_otool_L_output!
  end

  def parse_otool_L_output!
    stdout, stderr, status = Open3.capture3("otool -L \"#{path}\"")
    abort(stderr) unless status.success?
    libs = stdout.split("\n")
    libs.shift # first line is the filename
    @id = libs.shift[OTOOL_RX, 1]
    @deps = libs.map { |lib| lib[OTOOL_RX, 1] }.compact
  end

  def ensure_writable
    saved_perms = nil
    unless File.writable_real?(path)
      saved_perms = File.stat(path).mode
      FileUtils.chmod 0644, path
    end
    yield
  ensure
    FileUtils.chmod saved_perms, path if saved_perms
  end

  def change_id!
    ensure_writable do
      safe_system "install_name_tool", "-id", "@rpath/#{File.basename(self.id)}", path
    end
  end

  def change_install_name!(old_name, new_name)
    ensure_writable do
      safe_system "install_name_tool", "-change", old_name, new_name, path
    end
  end
end

search_roots = []
while ARGV.first == "--search-root"
  ARGV.shift
  search_roots << File.expand_path(ARGV.shift || abort("Missing directory after --search-root"))
end

if ARGV.length <= 1
  abort <<~END
    Usage: change_lib_dependencies.rb [--search-root directory ...] prefix libraries...

    If you're using Homebrew, your invocation might look like this:
      $ ./change_lib_dependencies.rb "$(brew --prefix)" "$(brew --prefix mpv-iina)/lib/libmpv.dylib"

    If you're using MacPorts, your invocation might look like this:
      $ port contents mpv | grep '\.dylib$' | xargs ./change_lib_dependencies.rb /opt/local
  END
end

prefix = ARGV.shift
closure_mode = !search_roots.empty?

linked_files = ARGV

proj_path = File.expand_path(File.join(File.dirname(__FILE__), '../'))
lib_folder = File.join(proj_path, "deps/lib/")

libs = []
original_folder = []

rm_rf lib_folder
mkdir lib_folder

linked_files.each do |file|
  # Grab the actual library on disk.
  file = File.realpath(file)

  # Keep the output filename the same as the library's install name
  dylib = DylibFile.new file
  dylib.parse_otool_L_output!
  dest = File.join(lib_folder, File.basename(dylib.id))

  puts "cp -p #{file} #{dest}"
  copy_entry file, dest, preserve: true
  libs << dest
  original_folder << File.dirname(file)
end

fix_count = 0

while !libs.empty?
  file = libs.pop
  folder = original_folder.pop
  puts "=== Fix dependencies for #{file} ==="
  dylib = DylibFile.new file
  dylib.change_id!
  dylib.deps.each do |dep|
    if dep.start_with?(prefix) || dep.start_with?("@rpath") ||
       (closure_mode && dep.start_with?("/") &&
        !dep.start_with?("/usr/lib", "/System"))
      fix_count += 1
      basename = File.basename(dep)
      new_name = "@rpath/#{basename}"
      dylib.change_install_name!(dep, new_name)
      dest = File.join(lib_folder, basename)
      unless File.exist?(dest)
        src =
          if dep.start_with?("@rpath")
            [folder, *search_roots].map { |root| File.join(root, basename) }
                                   .find { |candidate| File.exist?(candidate) }
          else
            [dep, *search_roots.map { |root| File.join(root, basename) }]
              .find { |candidate| File.exist?(candidate) }
          end
        abort("Unable to find dependency #{dep}") unless src && File.exist?(src)
        cp src, lib_folder, preserve: true
        libs << dest
        original_folder << File.dirname(src)
      end
    end
  end
end

errors = []
Dir.glob(File.join(lib_folder, "*.dylib")).sort.each do |file|
  DylibFile.new(file).deps.each do |dep|
    if !dep.start_with?("@rpath", "/usr/lib", "/System")
      errors << "unrelocated: #{file} -> #{dep}"
    elsif dep.start_with?("@rpath") &&
          !File.exist?(File.join(lib_folder, File.basename(dep)))
      errors << "not bundled: #{file} -> #{dep}"
    end
  end
end
abort(errors.join("\n")) unless errors.empty?

puts "Total #{fix_count}"
