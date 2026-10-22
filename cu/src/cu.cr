require "file_utils"
require "option_parser"
require "yaml"

root = "/"
config_path = "/etc/cu/config.yml"
args = [] of String
add = false

parser = OptionParser.new do |parser|
  parser.banner = "usage: cu [command] [arguments]"
  parser.on("add", "add a package to the system") do
    add = true
    parser.banner = "usage: cu add [arguments] [packages]"
    parser.on("-r PATH", "--root PATH", "specify an alternate root") do |path|
      root = path
    end
  end
  parser.on("-c FILE", "--config=FILE", "specify a config file to use") do |file|
    config_path = file
  end
  parser.on("-h", "--help", "show this help") do
    puts parser
    exit
  end
  parser.unknown_args do |_args|
    args = _args
    parser.missing_option do |flag|
      abort("error: #{flag} is missing something")
    end
    parser.invalid_option do |flag|
      abort("error: #{flag} is not valid")
    end
  end
end

parser.parse

if File.exists?(config_path)
  config = YAML.parse(File.read(config_path))
else
  abort("error: couldn't find #{config_path}")
end

root = File.expand_path(root)

repodir = File.expand_path(config["repo-directory"].as_s)
tmpdir = File.expand_path(config["tmp-directory"].as_s)

if add
  if args.empty?
    abort("error: missing packages", status = 1)
  end

  pkgname = args.join(", ")
  pkgmanifest = repodir + '/' + pkgname + "/manifest.yml"
  pkgbuild = repodir + '/' + pkgname + "/build.sh"

  puts "checking local repo for " + pkgname
  if File.exists?(pkgmanifest)
    manifest = YAML.parse(File.read(pkgmanifest))
    pkgver = manifest["version"].as_s
    pkgfull = pkgname + '-' + pkgver
    pkgtmpdir = tmpdir + '/' + pkgfull

    puts "found " + pkgfull

    FileUtils.rm_rf(pkgtmpdir)
    Dir.mkdir_p(pkgtmpdir + "/build")
    Dir.mkdir_p(pkgtmpdir + "/staging")

    puts "running build script for " + pkgfull

    buildstatus = Process.run(pkgbuild, [pkgtmpdir + "/staging"], chdir: pkgtmpdir + "/build")
    if buildstatus.exit_code == 0
      puts "succfully built " + pkgfull

      puts "installing " + pkgfull

      FileUtils.cp_r(pkgtmpdir + "/staging/.", root)

      stagingdir = pkgtmpdir + "/staging"
      stagedfiles = Dir.glob(stagingdir + "/**/*")
        .select { |path| File.file?(path) }
        .map { |path| path.sub(stagingdir + "/", "") } 

      dbdata = {
        version: pkgver,
        files:   stagedfiles,
      }

      dbfile = dbdata.to_yaml.sub(/\A---\n/, "")

      Dir.mkdir_p(root + "/var/lib/cu/system/")
      File.write(root + "/var/lib/cu/system/" + pkgname + ".yml", dbfile)

      puts pkgfull + " added to system"
    else
      abort("failed to build " + pkgfull, status = buildstatus.exit_code)
    end
  else
    abort("package not found in local repo", status = 1)
  end
else
  abort("error: missing command", status = 1)
end
