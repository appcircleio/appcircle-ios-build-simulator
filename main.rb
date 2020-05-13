require 'yaml'
require 'json'
require 'open3'
require 'pathname'

###### Enviroment Variable Check
def env_has_key(key)
  return (ENV[key] != nil && ENV[key] !="") ? ENV[key] : abort("Missing #{key}.")
end

options = {}
options[:repository_path] = ENV["AC_REPOSITORY_DIR"]
options[:temporary_path] = ENV["AC_TEMP_DIR"] || abort('Missing temporary path.')
options[:temporary_path] += "/appcircle_build_ios_simulator"
options[:outputh_path] = ENV["AC_OUTPUT_DIR"] || abort('Missing output path.')
options[:project_path] = ENV["AC_PROJECT_PATH"] || abort('Missing project path.')
options[:scheme] = ENV["AC_SCHEME"] || abort('Missing scheme.')

options[:xcode_list_path] = ENV["AC_XCODE_LIST_DIR"] || abort('Missing xcode list path.')
options[:xcode_version] = ENV["AC_XCODE_VERSION"] || abort('Missing xcode version.')

xcode_build_path = "#{options[:xcode_list_path]}/#{options[:xcode_version]}/Xcode.app/Contents/Developer/usr/bin/xcodebuild"
options[:xcodebuildPath] = File.file?(xcode_build_path) ? xcode_build_path : abort("Missing xcodebuild path.")
ENV["XCODE_DEVELOPER_DIR_PATH"] = "#{options[:xcode_list_path]}/#{options[:xcode_version]}/Xcode.app/Contents/Developer"

$configuration_name = (ENV["AC_CONFIGURATION_NAME"] != nil && ENV["AC_CONFIGURATION_NAME"] !="") ? ENV["AC_CONFIGURATION_NAME"] : nil

#compiler_index_store_enable - Options: YES, NO
$compiler_index_store_enable = env_has_key("AC_COMPILER_INDEX_STORE_ENABLE")

options[:extra_options] = ["-sdk iphonesimulator","-destination generic/platform=iOS","PLATFORM_NAME=iphonesimulator"]

if ENV["AC_ARCHIVE_FLAGS"] != "" && ENV["AC_ARCHIVE_FLAGS"] != nil
  options[:extra_options] = options[:extra_options].concat(ENV["AC_ARCHIVE_FLAGS"].split(","))
end

options[:archive_path] = "#{options[:outputh_path]}/build_simulator.xcarchive"

def archive(args)
  repository_path = args[:repository_path]
  project_path = args[:project_path]
  scheme = args[:scheme]
  extname = File.extname(project_path)
  archive_path = args[:archive_path]
  command = "#{args[:xcodebuildPath]} -scheme \"#{scheme}\" clean archive -archivePath \"#{archive_path}\" -derivedDataPath \"#{args[:temporary_path]}/DerivedData\" CODE_SIGN_IDENTITY=\"\" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO"
  
  if $configuration_name != nil
    command.concat(" ")
    command.concat("-configuration \"#{$configuration_name}\"")
    command.concat(" ")
  end

  if $compiler_index_store_enable != nil
    command.concat(" ")
    command.concat("COMPILER_INDEX_STORE_ENABLE=#{$compiler_index_store_enable}")
    command.concat(" ")
  end

  project_full_path = repository_path ? (Pathname.new repository_path).join(project_path) : project_path
  
  if args[:extra_options].kind_of?(Array)
    args[:extra_options].each do |option|
      command.concat(" ")
      command.concat(option)
      command.concat(" ")
    end
  end

  if extname == ".xcworkspace"
    command.concat(" -workspace \"#{project_full_path}\"")
  elsif extname == ".xcodeproj"
    command.concat(" -project \"#{project_full_path}\"")
  end


  runCommand(command)
end

def runCommand(command)
  puts "@[command] #{command}"
  status = nil
  stdout_str = nil
  stderr_str = nil
  Open3.popen3(command) do |stdin, stdout, stderr, wait_thr|
    stdout.each_line do |line|
      puts line
    end
    stdout_str = stdout.read
    stderr_str = stderr.read
    status = wait_thr.value
  end

  unless status.success?
    raise stderr_str
  end
end

archive(options)

#Write Environment Variable
open(ENV['AC_ENV_FILE_PATH'], 'a') { |f|
  f.puts "AC_SIMULATOR_ARCHIVE_PATH=#{options[:archive_path]}"
}

exit 0