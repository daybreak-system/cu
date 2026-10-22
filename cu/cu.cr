require "file_utils"
require "option_parser"
require "yaml"

config_path = "/etc/cu/config.yml"
args = [] of String
add = false

parser = OptionParser.new do |parser|
  parser.banner = "usage: cu [command] [arguments]"
  parser.on("add", "add a package to the system") do
    add = true
    parser.banner = "usage: cu add [arguments] [packages]"
  end
  parser.on("-c FILE", "--config=FILE", "specify a config file to use") do |path|
    config_path = path
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

def create_pkgtmpdir(path)
  stagingdir = path + "/staging"
  Dir.mkdir_p(path + "/build")
  Dir.mkdir_p(stagingdir)
  Dir.mkdir_p(stagingdir + "/usr/bin/")
end

if File.exists?(config_path)
  config = YAML.parse(File.read(config_path))
else
  abort("error: couldn't find #{config_path}")
end

repodir = File.expand_path(config["repo-directory"].as_s)
tmpdir = File.expand_path(config["tmp-directory"].as_s)

if add
  if args.empty?
    abort("error: missing packages", status = 1)
  end

  pkgname = args.join(", ")
  pkgver = "5.02"

  pkgfull = pkgname + '-' + pkgver
  pkgmanifest = repodir + '/' + pkgfull + "/manifest.yml"
  pkgbuild = repodir + '/' + pkgfull + "/build.sh"
  pkgtmpdir = tmpdir + '/' + pkgfull

  puts "checking local repo for " + pkgfull
  if File.exists?(pkgmanifest)
    FileUtils.rm_rf(pkgtmpdir)
    create_pkgtmpdir(pkgtmpdir)
    puts "running build script for " + pkgfull
    buildstatus = Process.run(pkgbuild, [pkgtmpdir + "/staging"], chdir: pkgtmpdir + "/build")
    if buildstatus.exit_code == 0
      puts "succfully built " + pkgfull
    else
      abort("failed to build " + pkgfull, status = buildstatus.exit_code)
    end
  else
    abort("package not found in local repo", status = 1)
  end
else
  abort("error: missing command", status = 1)
end
