require "file_utils"
require "option_parser"
require "yaml"

root = "/"
config_path = "/etc/cu/config.yml"
bootstrap = false
verbose = false
args = [] of String
command = ""

parser = OptionParser.new do |parser|
  parser.banner = "usage: cu [command] [arguments]"

  parser.on("add", "add packages to the system") do
    command = "add"
    parser.banner = "usage: cu add [arguments] [package]"
  end

  parser.on("remove", "remove packages from the system") do
    command = "remove"
    parser.banner = "usage: cu remove [arguments] [package]"
  end

  parser.on("sync", "sync packages or sets") do
    command = "sync"
    parser.banner = "usage: cu sync [arguments] [package|set]"
  end

  parser.on("clean", "clean obolete packages from the system") do
    command = "clean"
    parser.banner = "usage: cu clean"
  end

  parser.on("pull", "pull from upstream package repo to local repo") do
    command = "pull"
    parser.banner = "usage: cu pull"
  end

  parser.on("-r PATH", "--root PATH", "specify alternate root") do |path|
    root = path
  end

  parser.on("-c FILE", "--config=FILE", "specify config file to use") do |file|
    config_path = file
  end

  parser.on("-b", "--bootstrap", "ignore build dependencies") do
    bootstrap = true
  end

  parser.on("-V", "--verbose", "display executed commands and their outputs") do
    verbose = true
  end

  parser.on("-v", "--version", "show version") do
    puts "cu 0.1.0"
    exit
  end

  parser.on("-h", "--help", "show this help") do
    puts parser
    exit
  end

  parser.unknown_args do |_args|
    args = _args
  end
end

parser.parse

def load_config(path : String)
  abort("error: couldn't find #{path}") unless File.exists?(path)
  YAML.parse(File.read(path))
end

def record_path(root : String, name : String) : String
  root + "/var/db/cu/pkgs/" + name + ".yml"
end

def sets_record_path(root : String) : String
  root + "/var/db/cu/sets.yml"
end

def read_record(path : String)
  YAML.parse(File.read(path))
end

def read_sets_record(root)
  YAML.parse(File.read(sets_record_path(root)))
end

def write_record(root : String, name : String, version : String, files : Array(String))
  record = {
    version: version,
    files:   files,
  }

  Dir.mkdir_p(root + "/var/db/cu/pkgs")
  File.write(record_path(root, name), record.to_yaml.sub(/\A---\n/, ""))
end

def append_to_set(root : String, set : String, id : String)
  sets_record = read_sets_record(root)
  sets_record[set].as_a.push(YAML::Any.new(id))

  File.write(sets_record_path(root), sets_record.to_yaml.sub(/\A---\n/, ""))
end

def remove_from_set(root : String, set : String, id : String)
  sets_record = read_sets_record(root)
  sets_record[set].as_a.reject! { |item| item.as_s == id }

  File.write(sets_record_path(root), sets_record.to_yaml.sub(/\A---\n/, ""))
end

def in_set?(root : String, set : String, id : String)
  sets_record = read_sets_record(root)

  return sets_record[set].includes?(id)
end

def staged_files(stagingdir : String) : Array(String)
  Dir.glob(stagingdir + "/**/*")
    .select { |path| File.file?(path) }
    .map { |path| path.sub(stagingdir + "/", "") }
end

def build_package(build_script : String, tmpdir : String, rootdir : String, full_name : String, stdout_behaviour, stderr_behaviour, verbose) : String
  package_dir = tmpdir + "/" + full_name
  stagingdir = package_dir + "/staging"

  FileUtils.rm_rf(package_dir)
  Dir.mkdir_p(package_dir + "/build")
  Dir.mkdir_p(stagingdir)

  puts "building #{full_name}"

  puts "cd #{package_dir}/build" unless !verbose
  puts "#{build_script} #{stagingdir} #{rootdir}" unless !verbose
  result = Process.run(
    build_script,
    [stagingdir, rootdir],
    chdir: package_dir + "/build",
    output: stdout_behaviour,
    error: stderr_behaviour
  )

  raise "failed to build #{full_name}" unless result.exit_code == 0

  puts "successfully built #{full_name}"
  stagingdir
end

def install_package(root : String, name : String, version : String, stagingdir : String, stdout_behaviour, stderr_behaviour, verbose)
  puts "installing #{name}-#{version}"

  puts "cp -a #{stagingdir}/. #{root}" unless !verbose
  Process.run("cp", ["-a", "#{stagingdir}/.", root], output: stdout_behaviour, error: stderr_behaviour)
  write_record(root, name, version, staged_files(stagingdir))

  puts "#{name}-#{version} added to system"
end

def install_repo_package(root : String, repo_dir : String, tmpdir : String, name : String, stdout_behaviour, stderr_behaviour, verbose)
  manifest_path = repo_dir + "/" + name + "/manifest.yml"
  abort("error: package not found in local repo", status = 1) unless File.exists?(manifest_path)

  manifest = YAML.parse(File.read(manifest_path))
  version = manifest["version"].as_s

  stagingdir = build_package(
    repo_dir + "/" + name + "/build.sh",
    tmpdir,
    root,
    "#{name}-#{version}",
    stdout_behaviour,
    stderr_behaviour,
    verbose
  )

  install_package(root, name, version, stagingdir, stdout_behaviour, stderr_behaviour, verbose)
end

def remove_package(root : String, name : String)
  path = record_path(root, name)
  abort("error: package isn't in system", status = 1) unless File.exists?(path)

  record = read_record(path)
  version = record["version"].as_s

  record["files"].as_a.each do |file|
    File.delete(root + "/" + file.as_s)
  end

  File.delete(path)
  puts "removed #{name}-#{version} from system"
end

def resolve_dependencies(dependency_type : String, resolved : Array(String), visiting : Array(String), package : String, repo_dir : String)
  Nil
  if resolved.includes?(package)
    return
  end

  if visiting.includes?(package)
    abort("error: detected dependency cycle", status = 1)
  end

  visiting.push(package)

  manifest_path = repo_dir + "/" + package + "/manifest.yml"
  abort("error: dependecy not found in local repo", status = 1) unless File.exists?(manifest_path)

  manifest = YAML.parse(File.read(manifest_path))

  if manifest["#{dependency_type}-dependencies"]?
    manifest["#{dependency_type}-dependencies"].as_a.each do |dependency|
      resolve_dependencies(dependency_type, resolved, visiting, dependency.as_s, repo_dir)
    end
  end

  visiting.delete(package)
  resolved.push(package)
end

def plan_dependency_resolution(dependency_type : String, package : String, repo_dir : String) : Array(String)
  resolved = [] of String
  visiting = [] of String

  resolve_dependencies(dependency_type, resolved, visiting, package, repo_dir)

  resolved.pop
  return resolved
end

def runtime_dependency_status(package : String, target : String, repo_dir : String, visiting : Array(String)) : Bool?
  return true if package == target
  return nil if visiting.includes?(package)

  manifest_path = repo_dir + "/" + package + "/manifest.yml"
  return nil unless File.exists?(manifest_path)

  manifest = YAML.parse(File.read(manifest_path))
  dependencies = manifest["runtime-dependencies"]?

  return false unless dependencies

  visiting = visiting.dup
  visiting.push(package)
  unknown = false

  dependencies.as_a.each do |dependency|
    status = runtime_dependency_status(
      dependency.as_s, target, repo_dir, visiting
    )

    return true if status == true
    unknown = true if status.nil?
  end

  unknown ? nil : false
end

def runtime_required_by_installed_package?(root : String, repo_dir : String, target : String) : Bool
  records = Dir.glob(root + "/var/db/cu/pkgs/*.yml")
  packages = records.map { |path| File.basename(path, ".yml") }

  packages.each do |package|
    next if package == target

    status = runtime_dependency_status(package, target, repo_dir, [] of String)
    return true unless status == false
  end

  false
end

def remove_temporary_build_dependencies(root : String, repo_dir : String, dependencies : Array(String))
  dependencies.reverse_each do |dependency|
    next unless File.exists?(record_path(root, dependency))

    if runtime_required_by_installed_package?(root, repo_dir, dependency)
      puts "keeping #{dependency}: required by an installed package"
    else
      remove_package(root, dependency)
    end
  end
end

def add_package(root : String, repo_dir : String, tmpdir : String, name : String, bootstrap : Bool, stdout_behaviour, stderr_behaviour, verbose)
  abort("error: package already in system", status = 1) if File.exists?(record_path(root, name))

  manifest_path = repo_dir + "/" + name + "/manifest.yml"
  abort("error: package not found in local repo", status = 1) unless File.exists?(manifest_path)

  puts "checking local repo for #{name}"

  manifest = YAML.parse(File.read(manifest_path))
  version = manifest["version"].as_s

  puts "found #{name}-#{version}"

  build_dependencies = [] of String
  build_dependencies = plan_dependency_resolution("build", name, repo_dir) unless bootstrap
  runtime_dependencies = plan_dependency_resolution("runtime", name, repo_dir)

  temporary_build_dependencies = [] of String
  failure : String? = nil

  begin
    # Install build dependencies first, in dependency order.
    build_dependencies.each do |dependency|
      next if File.exists?(record_path(root, dependency))

      install_repo_package(root, repo_dir, tmpdir, dependency, stdout_behaviour, stderr_behaviour, verbose)

      unless runtime_dependencies.includes?(dependency)
        temporary_build_dependencies.push(dependency)
      end
    end

    # Runtime dependencies remain installed after the build.
    runtime_dependencies.each do |dependency|
      next if File.exists?(record_path(root, dependency))

      install_repo_package(root, repo_dir, tmpdir, dependency, stdout_behaviour, stderr_behaviour, verbose)
    end

    # Finally, build and install the requested package.
    install_repo_package(root, repo_dir, tmpdir, name, stdout_behaviour, stderr_behaviour, verbose)
  rescue ex
    failure = ex.message || "package installation failed"
  ensure
    remove_temporary_build_dependencies(
      root, repo_dir, temporary_build_dependencies
    )
  end

  abort("error: #{failure}", status = 1) if failure
end

def sync_set(root : String, repo_dir : String, tmpdir : String, set : String, stdout_behaviour, stderr_behaviour, verbose)
  sets_record = read_sets_record(root)

  sets_record[set].as_a.each do |package|
    sync_package(root, repo_dir, tmpdir, package.as_s, stdout_behaviour, stderr_behaviour, verbose)
  end

  puts "#{set} set synced"
end

def sync_package(root : String, repo_dir : String, tmpdir : String, name : String, stdout_behaviour, stderr_behaviour, verbose)
  manifest_path = repo_dir + "/" + name + "/manifest.yml"
  abort("error: package not found in local repo", status = 1) unless File.exists?(manifest_path)

  path = record_path(root, name)
  abort("error: package isn't in system", status = 1) unless File.exists?(path)

  installed = read_record(path)
  installed_version = installed["version"].as_s

  manifest = YAML.parse(File.read(manifest_path))
  repo_version = manifest["version"].as_s

  if installed_version == repo_version
    puts "#{name} is already synced"
    return
  end

  puts "system has #{name}-#{installed_version} while repo has #{name}-#{repo_version}"

  build_dependencies = plan_dependency_resolution("build", name, repo_dir)
  runtime_dependencies = plan_dependency_resolution("runtime", name, repo_dir)

  temporary_build_dependencies = [] of String
  failure : String? = nil

  begin
    # Install missing build dependencies in dependency order.
    build_dependencies.each do |dependency|
      next if File.exists?(record_path(root, dependency))

      install_repo_package(root, repo_dir, tmpdir, dependency, stdout_behaviour, stderr_behaviour, verbose)

      unless runtime_dependencies.includes?(dependency)
        temporary_build_dependencies.push(dependency)
      end
    end

    # Ensure the new version's runtime dependencies are installed.
    runtime_dependencies.each do |dependency|
      next if File.exists?(record_path(root, dependency))

      install_repo_package(root, repo_dir, tmpdir, dependency, stdout_behaviour, stderr_behaviour, verbose)
    end

    # Build before removing the currently installed version.
    stagingdir = build_package(
      repo_dir + "/" + name + "/build.sh",
      tmpdir,
      root,
      "#{name}-#{repo_version}",
      stdout_behaviour,
      stderr_behaviour,
      verbose
    )

    remove_package(root, name)
    install_package(root, name, repo_version, stagingdir, stdout_behaviour, stderr_behaviour, verbose)

    puts "#{name} synced"
  rescue ex
    failure = ex.message || "package sync failed"
  ensure
    remove_temporary_build_dependencies(
      root, repo_dir, temporary_build_dependencies
    )
  end

  abort("error: #{failure}", status = 1) if failure
end

def clean_packages(root : String, repo_dir : String)
  keep = [] of String

  sets_record = read_sets_record(root)

  sets_record["selected"].as_a.each do |package|
    name = package.as_s
    abort("error: selected package #{name} isn't installed", status = 1) unless File.exists?(record_path(root, name))

    keep.concat(plan_dependency_resolution("runtime", name, repo_dir))
    keep.push(name)
  end

  records = Dir.glob(root + "/var/db/cu/pkgs/*.yml")
  packages = records.map { |path| File.basename(path, ".yml") }

  obsolete = packages - keep

  obsolete.uniq.each do |package|
    remove_package(root, package)
  end
end

stdout_behaviour = verbose ? Process::Redirect::Inherit : Process::Redirect::Close
stderr_behaviour = verbose ? Process::Redirect::Inherit : Process::Redirect::Close

config = load_config(config_path)

root = File.expand_path(root)
repo_dir = File.expand_path(config["repo-directory"].as_s)
tmpdir = File.expand_path(config["tmp-directory"].as_s)

case command
when "add"
  abort("error: missing packages", status = 1) if args.empty?
  add_package(root, repo_dir, tmpdir, args[0], bootstrap, stdout_behaviour, stderr_behaviour, verbose)
  append_to_set(root, "selected", args[0])
when "remove"
  abort("error: missing packages", status = 1) if args.empty?
  remove_package(root, args[0])
  remove_from_set(root, "selected", args[0])
when "sync"
  abort("error: missing packages or sets", status = 1) if args.empty?

  if args[0][0] == ':'
    sync_set(root, repo_dir, tmpdir, args[0].sub(':', ""), stdout_behaviour, stderr_behaviour, verbose)
  else
    sync_package(root, repo_dir, tmpdir, args[0], stdout_behaviour, stderr_behaviour, verbose)
  end
when "clean"
  clean_packages(root, repo_dir)
when "pull"
  puts "cd #{repo_dir}" unless !verbose
  puts "git pull" unless !verbose
  result = Process.run(
    "git", ["pull"], chdir: repo_dir, output: stdout_behaviour, error: stderr_behaviour)
  raise "error: failed to pull upstream repo to local repo" unless result.exit_code == 0
  puts "pulled from upstream repo successfully"
else
  abort("error: missing command", status = 1)
end
