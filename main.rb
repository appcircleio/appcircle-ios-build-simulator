require 'yaml'
require 'json'
require 'open3'
require 'pathname'

###### Enviroment Variable Check
def env_has_key(key)
  return (ENV[key] != nil && ENV[key] !="") ? ENV[key] : abort("Missing #{key}.")
end

def get_env_variable(key)
	return (ENV[key] == nil || ENV[key] == "") ? nil : ENV[key]
end

def start_simulator(simulator_name)
  # Start the simulator using the specified name
  puts "Starting simulator: #{simulator_name}"
  _, stdout, stderr, wait_thr = Open3.popen3("xcrun simctl boot \"#{simulator_name}\"")

  # Wait for the simulator to start
  while (line = stdout.gets)
    puts line
    break if line.include?('booted')
  end

  # Check for any errors
  error_message = stderr.gets
  if error_message
    puts "Error starting simulator: #{simulator_name}"
    puts error_message
    return false
  end

  puts "Simulator started: #{simulator_name}"
  return true
end

# Function to install the app
def install_app(simulator_name, app_path)
  # Install the app on the specified simulator
  puts "Installing app on simulator: #{simulator_name}"
  _, stdout, stderr, wait_thr = Open3.popen3("xcrun simctl install \"#{simulator_name}\" \"#{app_path}\"")

  # Check for any errors
  error_message = stderr.gets
  if error_message
    puts "Error installing app on simulator: #{simulator_name}"
    puts error_message
    return false
  end

  puts "App installed on simulator: #{simulator_name}"
  return true
end

options = {}
options[:repository_path] = ENV["AC_REPOSITORY_DIR"]
options[:temporary_path] = ENV["AC_TEMP_DIR"] || abort('Missing temporary path.')
options[:temporary_path] += "/appcircle_build_ios_simulator"
options[:outputh_path] = env_has_key("AC_OUTPUT_DIR_PATH")
options[:project_path] = ENV["AC_PROJECT_PATH"] || abort('Missing project path.')
options[:scheme] = ENV["AC_SCHEME"] || abort('Missing scheme.')

$configuration_name = (ENV["AC_CONFIGURATION_NAME"] != nil && ENV["AC_CONFIGURATION_NAME"] !="") ? ENV["AC_CONFIGURATION_NAME"] : nil

#compiler_index_store_enable - Options: YES, NO
$compiler_index_store_enable = env_has_key("AC_COMPILER_INDEX_STORE_ENABLE")
architecture = ENV["AC_SIMULATOR_ARCH"] || 'x86_64'
options[:extra_options] = ["ONLY_ACTIVE_ARCH=NO","-arch #{architecture}"]
simulator_name = get_env_variable('AC_SIMULATOR_NAME')
if simulator_name 
  options[:extra_options] = ["ONLY_ACTIVE_ARCH=NO"]
  options[:simulator_name] = simulator_name
end

if ENV["AC_ARCHIVE_FLAGS"] != "" && ENV["AC_ARCHIVE_FLAGS"] != nil
  options[:extra_options] = options[:extra_options].concat(ENV["AC_ARCHIVE_FLAGS"].split("|"))
end

options[:xcode_build_dir] = "#{options[:temporary_path]}/SimulatorBuildDir"

def archive(args)
  repository_path = args[:repository_path]
  project_path = args[:project_path]
  scheme = args[:scheme]
  extname = File.extname(project_path)
  command = "xcodebuild -scheme \"#{scheme}\" -sdk iphonesimulator BUILD_DIR=\"#{args[:xcode_build_dir]}\" -derivedDataPath \"#{args[:temporary_path]}/SimulatorDerivedData\""
  if $configuration_name != nil
    command.concat(" ")
    command.concat("-configuration \"#{$configuration_name}\"")
    command.concat(" ")
  end
  simulator_name = args[:simulator_name]
  if simulator_name != nil 
    command.concat(" ")
    command.concat("-destination 'platform=iOS Simulator,OS=latest,name=#{simulator_name}'")
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
  puts "@@[command] #{command}"
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
#Move app file to AC_OUTPUT_DIR

simulator_dir = "#{options[:outputh_path]}/build_simulator"
create_simulator_folder_command = "mkdir -p #{simulator_dir}"
runCommand(create_simulator_folder_command)
ac_simulator_app_path = "#{simulator_dir}/build_simulator.app"

if $configuration_name != nil
  options[:xcode_build_dir] = "#{options[:xcode_build_dir]}/#{$configuration_name}-iphonesimulator"
else
  options[:xcode_build_dir] = "#{options[:xcode_build_dir]}/Debug-iphonesimulator"
end

target = Dir["#{options[:xcode_build_dir]}/*.app"].select{ |f| File.exist? f }.map{ |f| File.absolute_path f }[0]
move_command = "mv \"#{target}\" \"#{ac_simulator_app_path}\""
runCommand(move_command)

puts "AC_SIMULATOR_APP_PATH : #{ac_simulator_app_path}"

# Optionally install the app
if options[:simulator_name]
  start_simulator(options[:simulator_name])
  install_app(options[:simulator_name],ac_simulator_app_path)
end

#Write Environment Variable
open(ENV['AC_ENV_FILE_PATH'], 'a') { |f|
  f.puts "AC_SIMULATOR_APP_PATH=#{ac_simulator_app_path}"
}

exit 0