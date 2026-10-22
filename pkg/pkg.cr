require "file_utils"

# these will be defined in a config file later
repodir = File.expand_path("./")
tmpdir = "/tmp"

# these will be passed in as arguments later
pkgname = "sl"
pkgver = "5.02"

pkgfull = pkgname + '-' + pkgver
pkgmanifest = repodir + "/daybreak-repo/" + pkgfull + "/manifest.yml"
pkgbuild = repodir + "/daybreak-repo/" + pkgfull + "/build.sh"
pkgtmpdir = tmpdir + "/daybreak-tmp/" + pkgfull

def create_pkgtmpdir(path)
  stagingdir = path + "/staging"
  Dir.mkdir_p(path + "/build")
  Dir.mkdir_p(stagingdir)
  Dir.mkdir_p(stagingdir + "/usr/bin/")
end

puts "checking local repo for " + pkgfull
if File.exists?(pkgmanifest)
  FileUtils.rm_rf(pkgtmpdir)
  create_pkgtmpdir(pkgtmpdir)
  puts "running build script for " + pkgfull
  buildstatus = Process.run("/usr/bin/sh", [pkgbuild, pkgtmpdir + "/staging"], shell: true, chdir: pkgtmpdir + "/build")
  if buildstatus.exit_code == 0
    puts "succfully built " + pkgfull
  else
    abort("failed to build " + pkgfull, status = buildstatus.exit_code)
  end
else
  abort("package not found in local repo", status = 1)
end
