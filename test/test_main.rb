# frozen_string_literal: true

# ─── Coverage (must start before loading main.rb) ─────────────────────────────
unless defined?(Coverage) && Coverage.running?
  require 'coverage'
  Coverage.start
end

# ─── Dependencies ─────────────────────────────────────────────────────────────
require 'rspec'
require 'rspec/core/formatters/base_formatter'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'stringio'
require 'pathname'
require 'rbconfig'

MAIN_RB      = File.expand_path('../main.rb', __dir__)
PROJECT_ROOT = File.dirname(MAIN_RB)

# Top-level execution is guarded by __FILE__ == $PROGRAM_NAME, so requiring the
# step here defines the functions without running the build.
require MAIN_RB

# ─── Custom Formatter ─────────────────────────────────────────────────────────
class ReadableFormatter < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register(
    self,
    :example_group_started,
    :example_group_finished,
    :example_passed,
    :example_failed,
    :example_pending,
    :dump_summary
  )

  PASS  = "\e[32;1m[ PASS ]\e[0m"
  FAIL  = "\e[31;1m[ FAIL ]\e[0m"
  ERROR = "\e[31;1m[ERROR ]\e[0m"
  SKIP  = "\e[33;1m[ SKIP ]\e[0m"

  DIVIDER     = "\e[90m#{'─' * 72}\e[0m"
  DIVIDER_FAT = "\e[90m#{'═' * 72}\e[0m"

  GROUP_COLORS = [
    "\e[34;1m",
    "\e[35;1m",
    "\e[36;1m",
    "\e[33;1m"
  ].freeze

  def initialize(output)
    super
    @depth   = 0
    @top_idx = -1
    @failures = []
    @counts  = { passed: 0, failed: 0, pending: 0 }
  end

  def example_group_started(notification)
    group = notification.group
    if group.parent_groups.size <= 1
      output.puts if @depth.zero?
      @top_idx = (@top_idx + 1) % GROUP_COLORS.size
      output.puts "  #{GROUP_COLORS[@top_idx]}#{group.description}\e[0m"
    else
      output.puts "    #{'  ' * (@depth - 1)}\e[90m▸ \e[0m\e[37m#{group.description}\e[0m"
    end
    @depth += 1
  end

  def example_group_finished(_notification)
    @depth -= 1 if @depth > 0
  end

  def example_passed(notification)
    @counts[:passed] += 1
    print_example(PASS, notification.example)
  end

  def example_failed(notification)
    @counts[:failed] += 1
    ex    = notification.example
    exc   = ex.execution_result.exception
    badge = exc.is_a?(RSpec::Expectations::ExpectationNotMetError) ? FAIL : ERROR
    print_example(badge, ex)
    @failures << notification
  end

  def example_pending(notification)
    @counts[:pending] += 1
    ex = notification.example
    output.puts "    #{'  ' * [0, @depth - 1].max}#{SKIP}  #{ex.description}"
  end

  def dump_summary(notification)
    output.puts
    output.puts DIVIDER_FAT

    unless @failures.empty?
      output.puts "\n  \e[1;31mFailures:\e[0m\n"
      @failures.each_with_index do |n, i|
        ex  = n.example
        exc = ex.execution_result.exception
        output.puts "  \e[1m#{i + 1}) #{ex.full_description}\e[0m"
        exc.message.lines.first(6).each { |line| output.puts "     \e[31m#{line.rstrip}\e[0m" }
        output.puts "     \e[90m# #{ex.location}\e[0m"
        output.puts
      end
      output.puts DIVIDER
    end

    t   = notification.examples.size
    p   = @counts[:passed]
    f   = @counts[:failed]
    s   = @counts[:pending]
    sec = format('%.3fs', notification.duration)

    parts = ["\e[32m#{p} passed\e[0m"]
    parts << "\e[31m#{f} failed\e[0m"  if f > 0
    parts << "\e[33m#{s} pending\e[0m" if s > 0

    overall = f.zero? ? "\e[32;1m✔  All #{t} tests passed\e[0m" : "\e[31;1m✖  #{f} of #{t} tests failed\e[0m"
    output.puts "\n  #{overall}"
    output.puts "  #{parts.join('  |  ')}  \e[90m(#{sec})\e[0m"
    output.puts DIVIDER_FAT
  end

  private

  def print_example(badge, example)
    indent = '  ' * [0, @depth - 1].max
    time   = format('%.3fs', example.execution_result.run_time)
    output.puts "    #{indent}#{badge}  #{example.description}  \e[90m(#{time})\e[0m"
  end
end

# ─── Subprocess Helpers ───────────────────────────────────────────────────────

# A fake `xcodebuild` that succeeds without touching the real toolchain. It is
# placed first on PATH so main.rb's shell-out resolves to it instead of Xcode.
XCODEBUILD_STUB_SOURCE = <<~SH
  #!/bin/sh
  echo "stub-xcodebuild invoked"
  exit 0
SH

# A fake `xcodebuild` that fails, to exercise the runCommand error branch.
XCODEBUILD_FAILING_STUB_SOURCE = <<~SH
  #!/bin/sh
  echo "stub-xcodebuild failure details" >&2
  exit 65
SH

# A fake `xcrun` so the optional simctl boot/install path never reaches a real
# simulator. It reports a booted device and writes nothing to stderr.
XCRUN_STUB_SOURCE = <<~SH
  #!/bin/sh
  echo "booted"
  exit 0
SH

def with_tool_stubs(xcodebuild_source)
  stub_dir = Dir.mktmpdir('ios_simulator_stub')
  { 'xcodebuild' => xcodebuild_source, 'xcrun' => XCRUN_STUB_SOURCE }.each do |name, source|
    path = File.join(stub_dir, name)
    File.write(path, source)
    FileUtils.chmod(0o755, path)
  end
  yield stub_dir
ensure
  FileUtils.rm_rf(stub_dir)
end

# Run main.rb in a child process with a controlled ENV.
# Keys left as nil are explicitly unset in the child, which isolates the
# missing-variable tests from the ambient environment.
def run_main(env = {}, stub_source: XCODEBUILD_STUB_SOURCE)
  with_tool_stubs(stub_source) do |stub_dir|
    clean_env = {
      'AC_REPOSITORY_DIR'              => nil,
      'AC_TEMP_DIR'                    => nil,
      'AC_OUTPUT_DIR_PATH'             => nil,
      'AC_PROJECT_PATH'                => nil,
      'AC_SCHEME'                      => nil,
      'AC_CONFIGURATION_NAME'          => nil,
      'AC_COMPILER_INDEX_STORE_ENABLE' => nil,
      'AC_SIMULATOR_ARCH'              => nil,
      'AC_SIMULATOR_NAME'              => nil,
      'AC_ARCHIVE_FLAGS'               => nil,
      'AC_ENV_FILE_PATH'               => nil,
      'PATH'                           => "#{stub_dir}:#{ENV.fetch('PATH', '')}"
    }.merge(env)

    Open3.capture3(clean_env, "ruby #{MAIN_RB}")
  end
end

# Every variable main.rb needs to reach the build step.
def full_env(tmpdir)
  {
    'AC_TEMP_DIR'                    => tmpdir,
    'AC_OUTPUT_DIR_PATH'             => File.join(tmpdir, 'output'),
    'AC_PROJECT_PATH'                => 'App.xcodeproj',
    'AC_SCHEME'                      => 'MyScheme',
    'AC_COMPILER_INDEX_STORE_ENABLE' => 'NO',
    'AC_ENV_FILE_PATH'               => File.join(tmpdir, 'env_file')
  }
end

# The stub xcodebuild produces no artifacts, so the .app that main.rb moves out
# of BUILD_DIR is seeded here. Mirrors the directory layout main.rb expects.
def seed_simulator_app(tmpdir, configuration: nil)
  dir = File.join(
    tmpdir,
    'appcircle_build_ios_simulator',
    'SimulatorBuildDir',
    "#{configuration || 'Debug'}-iphonesimulator",
    'MyApp.app'
  )
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, 'MyApp'), 'binary')
  dir
end

# ─── Tests ────────────────────────────────────────────────────────────────────

# ─── 0. Required libraries ────────────────────────────────────────────────────
RSpec.describe 'Required libraries' do
  %w[yaml json open3 pathname].each do |lib|
    it "loads '#{lib}'" do
      expect { require lib }.not_to raise_error
    end
  end
end

# ─── 1. env_has_key ───────────────────────────────────────────────────────────
RSpec.describe '#env_has_key' do
  around do |example|
    saved = ENV['_AC_TEST_KEY']
    example.run
    ENV['_AC_TEST_KEY'] = saved
  end

  context 'positive path – key present and non-empty' do
    it 'returns the value as-is' do
      ENV['_AC_TEST_KEY'] = 'my_value'
      expect(env_has_key('_AC_TEST_KEY')).to eq('my_value')
    end

    it 'returns a path-like value without modification' do
      ENV['_AC_TEST_KEY'] = '/tmp/some/path'
      expect(env_has_key('_AC_TEST_KEY')).to eq('/tmp/some/path')
    end

    it 'returns a value that is only whitespace' do
      ENV['_AC_TEST_KEY'] = ' '
      expect(env_has_key('_AC_TEST_KEY')).to eq(' ')
    end

    it 'returns a YES/NO flag value' do
      ENV['_AC_TEST_KEY'] = 'NO'
      expect(env_has_key('_AC_TEST_KEY')).to eq('NO')
    end
  end

  context 'negative path – missing key' do
    it 'raises SystemExit when the key is not set' do
      ENV.delete('_AC_TEST_KEY')
      expect { env_has_key('_AC_TEST_KEY') }.to raise_error(SystemExit)
    end

    it 'abort message includes the key name' do
      ENV.delete('_AC_TEST_KEY')
      captured        = StringIO.new
      original_stderr = $stderr
      $stderr = captured
      begin
        env_has_key('_AC_TEST_KEY')
      rescue SystemExit
        # expected
      ensure
        $stderr = original_stderr
      end
      expect(captured.string).to match(/Missing _AC_TEST_KEY\./)
    end
  end

  context 'negative path – empty string value' do
    it 'raises SystemExit when the value is an empty string' do
      ENV['_AC_TEST_KEY'] = ''
      expect { env_has_key('_AC_TEST_KEY') }.to raise_error(SystemExit)
    end
  end
end

# ─── 2. get_env_variable ──────────────────────────────────────────────────────
RSpec.describe '#get_env_variable' do
  around do |example|
    saved = ENV['_AC_TEST_OPTIONAL']
    example.run
    ENV['_AC_TEST_OPTIONAL'] = saved
  end

  context 'positive path – key present and non-empty' do
    it 'returns the value when the key is set' do
      ENV['_AC_TEST_OPTIONAL'] = 'iPhone 15'
      expect(get_env_variable('_AC_TEST_OPTIONAL')).to eq('iPhone 15')
    end

    it 'preserves spaces in the value' do
      ENV['_AC_TEST_OPTIONAL'] = 'iPhone 15 Pro Max'
      expect(get_env_variable('_AC_TEST_OPTIONAL')).to eq('iPhone 15 Pro Max')
    end
  end

  context 'negative path – unset or empty' do
    it 'returns nil when the key is not set' do
      ENV.delete('_AC_TEST_OPTIONAL')
      expect(get_env_variable('_AC_TEST_OPTIONAL')).to be_nil
    end

    it 'returns nil when the value is an empty string' do
      ENV['_AC_TEST_OPTIONAL'] = ''
      expect(get_env_variable('_AC_TEST_OPTIONAL')).to be_nil
    end

    it 'does not abort for a missing key, unlike env_has_key' do
      ENV.delete('_AC_TEST_OPTIONAL')
      expect { get_env_variable('_AC_TEST_OPTIONAL') }.not_to raise_error
    end
  end
end

# ─── 3. runCommand ────────────────────────────────────────────────────────────
RSpec.describe '#runCommand' do
  before { allow($stdout).to receive(:puts) }

  context 'positive path' do
    it 'returns without raising for a successful command' do
      expect { runCommand('echo hi') }.not_to raise_error
    end

    it 'echoes the command it is about to run' do
      expect($stdout).to receive(:puts).with('@@[command] echo hi')
      runCommand('echo hi')
    end

    it 'succeeds for a command that writes to stderr but exits zero' do
      expect { runCommand('bash -c "echo noise >&2; exit 0"') }.not_to raise_error
    end

    it 'streams multi-line stdout without raising' do
      expect { runCommand('printf "a\\nb\\nc\\n"') }.not_to raise_error
    end
  end

  context 'negative path' do
    it 'raises when the command exits non-zero' do
      expect { runCommand('bash -c "exit 1"') }.to raise_error(RuntimeError)
    end

    it 'raises with the stderr output as the message' do
      expect { runCommand('bash -c "echo failure details >&2; exit 1"') }
        .to raise_error(RuntimeError, /failure details/)
    end

    it 'raises Errno::ENOENT for a non-existent executable' do
      expect { runCommand('ac_definitely_not_a_real_binary_xyz') }
        .to raise_error(Errno::ENOENT)
    end

    it 'raises Errno::ENOENT for an empty command' do
      expect { runCommand('') }.to raise_error(Errno::ENOENT)
    end

    it 'raises TypeError for a nil command' do
      expect { runCommand(nil) }.to raise_error(TypeError)
    end
  end
end

# ─── 4. archive – command construction ────────────────────────────────────────
RSpec.describe '#archive' do
  let(:base_args) do
    {
      repository_path: nil,
      temporary_path:  '/tmp/appcircle_build_ios_simulator',
      project_path:    'App.xcodeproj',
      scheme:          'MyScheme',
      extra_options:   [],
      xcode_build_dir: '/tmp/appcircle_build_ios_simulator/SimulatorBuildDir'
    }
  end

  # archive() reads global state set by main.rb's top-level block, which the
  # __FILE__ guard keeps from running here. Each example controls it explicitly.
  around do |example|
    saved = [$configuration_name, $compiler_index_store_enable]
    $configuration_name          = nil
    $compiler_index_store_enable = nil
    example.run
    $configuration_name, $compiler_index_store_enable = saved
  end

  # Capture the composed command instead of shelling out to the real toolchain.
  before do
    @last_cmd = nil
    allow(self).to receive(:runCommand) { |cmd| @last_cmd = cmd }
  end

  def archive_command(overrides = {})
    archive(base_args.merge(overrides))
    @last_cmd
  end

  context 'positive path – always-present flags' do
    it 'invokes xcodebuild' do
      expect(archive_command).to start_with('xcodebuild ')
    end

    it 'quotes the scheme' do
      expect(archive_command).to include('-scheme "MyScheme"')
    end

    it 'targets the iphonesimulator SDK' do
      expect(archive_command).to include('-sdk iphonesimulator')
    end

    it 'passes BUILD_DIR as a quoted build setting' do
      expect(archive_command)
        .to include('BUILD_DIR="/tmp/appcircle_build_ios_simulator/SimulatorBuildDir"')
    end

    it 'derives the derived data path from the temporary path' do
      expect(archive_command)
        .to include('-derivedDataPath "/tmp/appcircle_build_ios_simulator/SimulatorDerivedData"')
    end

    it 'hands the composed command to runCommand exactly once' do
      expect(self).to receive(:runCommand).once
      archive(base_args)
    end
  end

  context 'positive path – project type' do
    it 'uses -project for a .xcodeproj path' do
      cmd = archive_command(project_path: 'App.xcodeproj')
      expect(cmd).to include('-project "App.xcodeproj"')
      expect(cmd).not_to include('-workspace')
    end

    it 'uses -workspace for a .xcworkspace path' do
      cmd = archive_command(project_path: 'App.xcworkspace')
      expect(cmd).to include('-workspace "App.xcworkspace"')
      expect(cmd).not_to include('-project')
    end

    it 'joins the repository path with a relative project path' do
      cmd = archive_command(repository_path: '/repo', project_path: 'App.xcodeproj')
      expect(cmd).to include('-project "/repo/App.xcodeproj"')
    end

    it 'keeps an absolute project path when a repository path is also given' do
      cmd = archive_command(repository_path: '/repo', project_path: '/abs/App.xcodeproj')
      expect(cmd).to include('-project "/abs/App.xcodeproj"')
    end

    it 'handles a project path containing spaces' do
      cmd = archive_command(project_path: 'My App.xcodeproj')
      expect(cmd).to include('-project "My App.xcodeproj"')
    end
  end

  context 'positive path – optional flags' do
    it 'adds -configuration when $configuration_name is set' do
      $configuration_name = 'Release'
      expect(archive_command).to include('-configuration "Release"')
    end

    it 'quotes a configuration name containing a space' do
      $configuration_name = 'My Release'
      expect(archive_command).to include('-configuration "My Release"')
    end

    it 'adds -destination when a simulator name is given' do
      cmd = archive_command(simulator_name: 'iPhone 15')
      expect(cmd).to include("-destination 'platform=iOS Simulator,OS=latest,name=iPhone 15'")
    end

    it 'adds COMPILER_INDEX_STORE_ENABLE when the global is set' do
      $compiler_index_store_enable = 'NO'
      expect(archive_command).to include('COMPILER_INDEX_STORE_ENABLE=NO')
    end

    it 'appends every extra option in order' do
      cmd = archive_command(extra_options: ['ONLY_ACTIVE_ARCH=NO', '-arch arm64'])
      expect(cmd).to include('ONLY_ACTIVE_ARCH=NO')
      expect(cmd).to include('-arch arm64')
      expect(cmd.index('ONLY_ACTIVE_ARCH=NO')).to be < cmd.index('-arch arm64')
    end

    it 'places the project flag after the extra options' do
      cmd = archive_command(extra_options: ['-arch arm64'])
      expect(cmd.index('-arch arm64')).to be < cmd.index('-project')
    end

    it 'combines every optional flag in one command' do
      $configuration_name          = 'Release'
      $compiler_index_store_enable = 'YES'
      cmd = archive_command(simulator_name: 'iPhone 15', extra_options: ['ONLY_ACTIVE_ARCH=NO'])
      expect(cmd).to include('-configuration "Release"')
      expect(cmd).to include('-destination')
      expect(cmd).to include('COMPILER_INDEX_STORE_ENABLE=YES')
      expect(cmd).to include('ONLY_ACTIVE_ARCH=NO')
      expect(cmd).to include('-project "App.xcodeproj"')
    end
  end

  context 'negative path – optional flags left unset' do
    it 'omits -configuration when the global is nil' do
      expect(archive_command).not_to include('-configuration')
    end

    it 'omits -destination when no simulator name is given' do
      expect(archive_command).not_to include('-destination')
    end

    it 'omits COMPILER_INDEX_STORE_ENABLE when the global is nil' do
      expect(archive_command).not_to include('COMPILER_INDEX_STORE_ENABLE')
    end

    it 'adds no option flags for an empty extra_options array' do
      expect(archive_command(extra_options: [])).not_to include('ONLY_ACTIVE_ARCH')
    end

    it 'ignores extra_options when it is not an Array' do
      expect { archive_command(extra_options: '-arch arm64') }.not_to raise_error
      expect(@last_cmd).not_to include('-arch arm64')
    end

    it 'ignores extra_options when it is nil' do
      expect { archive_command(extra_options: nil) }.not_to raise_error
      expect(@last_cmd).to include('-project "App.xcodeproj"')
    end
  end

  context 'negative path – empty and malformed input' do
    it 'emits an empty quoted scheme for an empty scheme' do
      expect(archive_command(scheme: '')).to include('-scheme ""')
    end

    it 'emits an empty quoted scheme for a nil scheme' do
      expect(archive_command(scheme: nil)).to include('-scheme ""')
    end

    it 'adds neither -project nor -workspace for an unknown extension' do
      cmd = archive_command(project_path: 'App.txt')
      expect(cmd).not_to include('-project')
      expect(cmd).not_to include('-workspace')
    end

    it 'adds neither -project nor -workspace for an extensionless path' do
      cmd = archive_command(project_path: 'App')
      expect(cmd).not_to include('-project')
      expect(cmd).not_to include('-workspace')
    end

    it 'raises TypeError when the project path is nil' do
      expect { archive_command(project_path: nil) }.to raise_error(TypeError)
    end

    it 'does not call runCommand when the project path is nil' do
      expect(self).not_to receive(:runCommand)
      expect { archive(base_args.merge(project_path: nil)) }.to raise_error(TypeError)
    end

    it 'raises TypeError when args is nil' do
      expect { archive(nil) }.to raise_error(NoMethodError)
    end
  end
end

# ─── 5. start_simulator ───────────────────────────────────────────────────────
RSpec.describe '#start_simulator' do
  let(:captured) { [] }

  before { allow($stdout).to receive(:puts) }

  # Replaces the simctl shell-out so no real simulator is ever booted.
  def stub_popen3(stdout_text: '', stderr_text: '')
    allow(Open3).to receive(:popen3) do |cmd|
      captured << cmd
      [StringIO.new, StringIO.new(stdout_text), StringIO.new(stderr_text), nil]
    end
  end

  context 'positive path' do
    it 'returns true when the simulator boots without stderr output' do
      stub_popen3(stdout_text: "booted\n")
      expect(start_simulator('iPhone 15')).to be true
    end

    it 'composes the simctl boot command with a quoted simulator name' do
      stub_popen3(stdout_text: "booted\n")
      start_simulator('iPhone 15')
      expect(captured.first).to eq('xcrun simctl boot "iPhone 15"')
    end

    it 'stops reading stdout once a booted line arrives' do
      stub_popen3(stdout_text: "preparing\nbooted\ntrailing noise\n")
      start_simulator('iPhone 15')
      expect($stdout).to have_received(:puts).with("booted\n")
      expect($stdout).not_to have_received(:puts).with("trailing noise\n")
    end

    it 'returns true when stdout is empty and stderr is silent' do
      stub_popen3
      expect(start_simulator('iPhone 15')).to be true
    end

    it 'announces the simulator it is starting' do
      stub_popen3(stdout_text: "booted\n")
      start_simulator('iPhone 15')
      expect($stdout).to have_received(:puts).with('Starting simulator: iPhone 15')
    end
  end

  context 'negative path' do
    it 'returns false when simctl writes to stderr' do
      stub_popen3(stderr_text: "Unable to boot device\n")
      expect(start_simulator('iPhone 15')).to be false
    end

    it 'prints the error message from stderr' do
      stub_popen3(stderr_text: "Unable to boot device\n")
      start_simulator('iPhone 15')
      expect($stdout).to have_received(:puts).with("Unable to boot device\n")
    end

    it 'still quotes an empty simulator name' do
      stub_popen3
      start_simulator('')
      expect(captured.first).to eq('xcrun simctl boot ""')
    end

    it 'produces an empty quoted name for a nil simulator name' do
      stub_popen3
      start_simulator(nil)
      expect(captured.first).to eq('xcrun simctl boot ""')
    end

    it 'does not swallow a failure to spawn simctl' do
      allow(Open3).to receive(:popen3).and_raise(Errno::ENOENT.new('xcrun'))
      expect { start_simulator('iPhone 15') }.to raise_error(Errno::ENOENT)
    end
  end
end

# ─── 6. install_app ───────────────────────────────────────────────────────────
RSpec.describe '#install_app' do
  let(:captured) { [] }

  before { allow($stdout).to receive(:puts) }

  def stub_popen3(stderr_text: '')
    allow(Open3).to receive(:popen3) do |cmd|
      captured << cmd
      [StringIO.new, StringIO.new, StringIO.new(stderr_text), nil]
    end
  end

  context 'positive path' do
    it 'returns true when simctl install is silent on stderr' do
      stub_popen3
      expect(install_app('iPhone 15', '/out/build_simulator.app')).to be true
    end

    it 'composes the simctl install command with both arguments quoted' do
      stub_popen3
      install_app('iPhone 15', '/out/build_simulator.app')
      expect(captured.first).to eq('xcrun simctl install "iPhone 15" "/out/build_simulator.app"')
    end

    it 'quotes an app path containing spaces' do
      stub_popen3
      install_app('iPhone 15', '/out dir/My App.app')
      expect(captured.first).to eq('xcrun simctl install "iPhone 15" "/out dir/My App.app"')
    end

    it 'announces the simulator it installs on' do
      stub_popen3
      install_app('iPhone 15', '/out/build_simulator.app')
      expect($stdout).to have_received(:puts).with('Installing app on simulator: iPhone 15')
    end

    it 'confirms the install when it succeeds' do
      stub_popen3
      install_app('iPhone 15', '/out/build_simulator.app')
      expect($stdout).to have_received(:puts).with('App installed on simulator: iPhone 15')
    end
  end

  context 'negative path' do
    it 'returns false when simctl writes to stderr' do
      stub_popen3(stderr_text: "No such file or directory\n")
      expect(install_app('iPhone 15', '/out/missing.app')).to be false
    end

    it 'prints the error message from stderr' do
      stub_popen3(stderr_text: "No such file or directory\n")
      install_app('iPhone 15', '/out/missing.app')
      expect($stdout).to have_received(:puts).with("No such file or directory\n")
    end

    it 'does not print the success line when the install fails' do
      stub_popen3(stderr_text: "failed\n")
      install_app('iPhone 15', '/out/missing.app')
      expect($stdout).not_to have_received(:puts).with('App installed on simulator: iPhone 15')
    end

    it 'produces empty quoted arguments for nil inputs' do
      stub_popen3
      install_app(nil, nil)
      expect(captured.first).to eq('xcrun simctl install "" ""')
    end

    it 'does not swallow a failure to spawn simctl' do
      allow(Open3).to receive(:popen3).and_raise(Errno::ENOENT.new('xcrun'))
      expect { install_app('iPhone 15', '/out/app.app') }.to raise_error(Errno::ENOENT)
    end
  end
end

# ─── 7. ENV validation (subprocess – main.rb) ─────────────────────────────────
RSpec.describe 'ENV validation (subprocess – main.rb)' do
  let(:tmpdir) { Dir.mktmpdir('ios_build_simulator_env') }
  after { FileUtils.rm_rf(tmpdir) }

  shared_examples 'aborts with message' do |expected_pattern, env|
    it "exits non-zero and stderr matches /#{expected_pattern}/" do
      _out, err, status = run_main(env)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(Regexp.new(expected_pattern))
    end
  end

  context 'AC_TEMP_DIR' do
    context 'when missing' do
      include_examples 'aborts with message', 'Missing temporary path\.', {}
    end

    context 'when an empty string' do
      # main.rb only nil-checks this variable, so an empty value passes through
      # and the run stops at the next unset required variable instead.
      include_examples 'aborts with message',
                       'Missing AC_OUTPUT_DIR_PATH\.',
                       { 'AC_TEMP_DIR' => '' }
    end
  end

  context 'AC_OUTPUT_DIR_PATH' do
    context 'when missing' do
      include_examples 'aborts with message',
                       'Missing AC_OUTPUT_DIR_PATH\.',
                       { 'AC_TEMP_DIR' => '/tmp' }
    end

    context 'when an empty string' do
      include_examples 'aborts with message',
                       'Missing AC_OUTPUT_DIR_PATH\.',
                       { 'AC_TEMP_DIR' => '/tmp', 'AC_OUTPUT_DIR_PATH' => '' }
    end
  end

  context 'AC_PROJECT_PATH' do
    context 'when missing' do
      include_examples 'aborts with message',
                       'Missing project path\.',
                       { 'AC_TEMP_DIR' => '/tmp', 'AC_OUTPUT_DIR_PATH' => '/tmp/out' }
    end

    context 'when an empty string' do
      include_examples 'aborts with message',
                       'Missing scheme\.',
                       { 'AC_TEMP_DIR' => '/tmp', 'AC_OUTPUT_DIR_PATH' => '/tmp/out',
                         'AC_PROJECT_PATH' => '' }
    end
  end

  context 'AC_SCHEME' do
    context 'when missing' do
      include_examples 'aborts with message',
                       'Missing scheme\.',
                       { 'AC_TEMP_DIR' => '/tmp', 'AC_OUTPUT_DIR_PATH' => '/tmp/out',
                         'AC_PROJECT_PATH' => 'App.xcodeproj' }
    end

    context 'when an empty string' do
      include_examples 'aborts with message',
                       'Missing AC_COMPILER_INDEX_STORE_ENABLE\.',
                       { 'AC_TEMP_DIR' => '/tmp', 'AC_OUTPUT_DIR_PATH' => '/tmp/out',
                         'AC_PROJECT_PATH' => 'App.xcodeproj', 'AC_SCHEME' => '' }
    end
  end

  context 'AC_COMPILER_INDEX_STORE_ENABLE' do
    context 'when missing' do
      include_examples 'aborts with message',
                       'Missing AC_COMPILER_INDEX_STORE_ENABLE\.',
                       { 'AC_TEMP_DIR' => '/tmp', 'AC_OUTPUT_DIR_PATH' => '/tmp/out',
                         'AC_PROJECT_PATH' => 'App.xcodeproj', 'AC_SCHEME' => 'MyScheme' }
    end

    context 'when an empty string' do
      include_examples 'aborts with message',
                       'Missing AC_COMPILER_INDEX_STORE_ENABLE\.',
                       { 'AC_TEMP_DIR' => '/tmp', 'AC_OUTPUT_DIR_PATH' => '/tmp/out',
                         'AC_PROJECT_PATH' => 'App.xcodeproj', 'AC_SCHEME' => 'MyScheme',
                         'AC_COMPILER_INDEX_STORE_ENABLE' => '' }
    end
  end

  context 'AC_ENV_FILE_PATH' do
    it 'succeeds and writes the output variable when set' do
      seed_simulator_app(tmpdir)
      _out, err, status = run_main(full_env(tmpdir))
      expect(status.exitstatus).to eq(0), "stderr was: #{err}"
      expect(File.read(File.join(tmpdir, 'env_file'))).to include('AC_SIMULATOR_APP_PATH=')
    end

    it 'appends to an existing env file rather than truncating it' do
      seed_simulator_app(tmpdir)
      env_file = File.join(tmpdir, 'env_file')
      File.write(env_file, "PRE_EXISTING=1\n")
      _out, _err, status = run_main(full_env(tmpdir))
      expect(status.exitstatus).to eq(0)
      expect(File.read(env_file)).to include('PRE_EXISTING=1')
    end

    it 'fails with a TypeError when missing' do
      seed_simulator_app(tmpdir)
      _out, err, status = run_main(full_env(tmpdir).merge('AC_ENV_FILE_PATH' => nil))
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/TypeError|no implicit conversion/)
    end

    it 'fails with a missing-file error when an empty string' do
      seed_simulator_app(tmpdir)
      _out, err, status = run_main(full_env(tmpdir).merge('AC_ENV_FILE_PATH' => ''))
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/No such file or directory|Errno::ENOENT/)
    end

    it 'fails when it points into a directory that does not exist' do
      seed_simulator_app(tmpdir)
      _out, err, status = run_main(
        full_env(tmpdir).merge('AC_ENV_FILE_PATH' => File.join(tmpdir, 'no', 'such', 'dir', 'env'))
      )
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/No such file or directory|Errno::ENOENT/)
    end
  end

  context 'AC_REPOSITORY_DIR (optional)' do
    it 'succeeds when missing and uses the bare project path' do
      seed_simulator_app(tmpdir)
      out, err, status = run_main(full_env(tmpdir))
      expect(status.exitstatus).to eq(0), "stderr was: #{err}"
      expect(out).to include('-project "App.xcodeproj"')
    end

    it 'joins the repository directory with the project path when set' do
      seed_simulator_app(tmpdir)
      out, _err, status = run_main(full_env(tmpdir).merge('AC_REPOSITORY_DIR' => '/repo'))
      expect(status.exitstatus).to eq(0)
      expect(out).to include('-project "/repo/App.xcodeproj"')
    end

    it 'falls back to the bare project path for an empty string' do
      seed_simulator_app(tmpdir)
      out, _err, status = run_main(full_env(tmpdir).merge('AC_REPOSITORY_DIR' => ''))
      expect(status.exitstatus).to eq(0)
      expect(out).to include('-project "App.xcodeproj"')
    end
  end

  context 'AC_SIMULATOR_ARCH (optional)' do
    it 'defaults to x86_64 when missing' do
      seed_simulator_app(tmpdir)
      out, _err, status = run_main(full_env(tmpdir))
      expect(status.exitstatus).to eq(0)
      expect(out).to include('-arch x86_64')
    end

    it 'uses the given architecture when set' do
      seed_simulator_app(tmpdir)
      out, _err, status = run_main(full_env(tmpdir).merge('AC_SIMULATOR_ARCH' => 'arm64'))
      expect(status.exitstatus).to eq(0)
      expect(out).to include('-arch arm64')
    end

    it 'always pairs the architecture with ONLY_ACTIVE_ARCH=NO' do
      seed_simulator_app(tmpdir)
      out, _err, status = run_main(full_env(tmpdir).merge('AC_SIMULATOR_ARCH' => 'arm64'))
      expect(status.exitstatus).to eq(0)
      expect(out).to include('ONLY_ACTIVE_ARCH=NO')
    end

    it 'emits an empty -arch value for an empty string, since only nil is defaulted' do
      seed_simulator_app(tmpdir)
      out, _err, status = run_main(full_env(tmpdir).merge('AC_SIMULATOR_ARCH' => ''))
      expect(status.exitstatus).to eq(0)
      expect(out).to include('-arch')
      expect(out).not_to include('-arch x86_64')
    end
  end

  context 'AC_SIMULATOR_NAME (optional)' do
    it 'adds -destination and drops -arch when set' do
      seed_simulator_app(tmpdir)
      out, _err, status = run_main(
        full_env(tmpdir).merge('AC_SIMULATOR_NAME' => 'iPhone 15', 'AC_SIMULATOR_ARCH' => 'arm64')
      )
      expect(status.exitstatus).to eq(0)
      expect(out).to include("-destination 'platform=iOS Simulator,OS=latest,name=iPhone 15'")
      expect(out).not_to include('-arch arm64')
    end

    it 'boots and installs on the simulator when set' do
      seed_simulator_app(tmpdir)
      out, _err, status = run_main(full_env(tmpdir).merge('AC_SIMULATOR_NAME' => 'iPhone 15'))
      expect(status.exitstatus).to eq(0)
      expect(out).to include('Starting simulator: iPhone 15')
      expect(out).to include('Installing app on simulator: iPhone 15')
    end

    it 'skips the boot and install step when missing' do
      seed_simulator_app(tmpdir)
      out, _err, status = run_main(full_env(tmpdir))
      expect(status.exitstatus).to eq(0)
      expect(out).not_to include('Starting simulator')
    end

    it 'skips the boot and install step for an empty string' do
      seed_simulator_app(tmpdir)
      out, _err, status = run_main(full_env(tmpdir).merge('AC_SIMULATOR_NAME' => ''))
      expect(status.exitstatus).to eq(0)
      expect(out).not_to include('Starting simulator')
      expect(out).to include('-arch x86_64')
    end
  end

  context 'AC_CONFIGURATION_NAME (optional)' do
    it 'adds -configuration and reads from the matching build directory when set' do
      seed_simulator_app(tmpdir, configuration: 'Release')
      out, err, status = run_main(full_env(tmpdir).merge('AC_CONFIGURATION_NAME' => 'Release'))
      expect(status.exitstatus).to eq(0), "stderr was: #{err}"
      expect(out).to include('-configuration "Release"')
    end

    it 'omits -configuration and falls back to Debug-iphonesimulator when missing' do
      seed_simulator_app(tmpdir)
      out, _err, status = run_main(full_env(tmpdir))
      expect(status.exitstatus).to eq(0)
      expect(out).not_to include('-configuration')
    end

    it 'omits -configuration for an empty string' do
      seed_simulator_app(tmpdir)
      out, _err, status = run_main(full_env(tmpdir).merge('AC_CONFIGURATION_NAME' => ''))
      expect(status.exitstatus).to eq(0)
      expect(out).not_to include('-configuration')
    end

    it 'fails when the configured build directory holds no .app' do
      seed_simulator_app(tmpdir, configuration: 'Debug')
      _out, _err, status = run_main(full_env(tmpdir).merge('AC_CONFIGURATION_NAME' => 'Release'))
      expect(status.exitstatus).not_to eq(0)
    end
  end

  context 'AC_ARCHIVE_FLAGS (optional)' do
    it 'appends a single flag to the build command' do
      seed_simulator_app(tmpdir)
      out, _err, status = run_main(full_env(tmpdir).merge('AC_ARCHIVE_FLAGS' => '-quiet'))
      expect(status.exitstatus).to eq(0)
      expect(out).to include('-quiet')
    end

    it 'splits pipe-separated flags into separate arguments' do
      seed_simulator_app(tmpdir)
      out, _err, status = run_main(
        full_env(tmpdir).merge('AC_ARCHIVE_FLAGS' => '-quiet|-parallelizeTargets')
      )
      expect(status.exitstatus).to eq(0)
      expect(out).to include('-quiet')
      expect(out).to include('-parallelizeTargets')
    end

    it 'keeps the architecture options when flags are added' do
      seed_simulator_app(tmpdir)
      out, _err, status = run_main(full_env(tmpdir).merge('AC_ARCHIVE_FLAGS' => '-quiet'))
      expect(status.exitstatus).to eq(0)
      expect(out).to include('ONLY_ACTIVE_ARCH=NO')
      expect(out).to include('-arch x86_64')
    end

    it 'adds nothing when missing' do
      seed_simulator_app(tmpdir)
      out, _err, status = run_main(full_env(tmpdir))
      expect(status.exitstatus).to eq(0)
      expect(out).not_to include('-quiet')
    end

    it 'adds nothing for an empty string' do
      seed_simulator_app(tmpdir)
      out, _err, status = run_main(full_env(tmpdir).merge('AC_ARCHIVE_FLAGS' => ''))
      expect(status.exitstatus).to eq(0)
      expect(out).not_to include('-quiet')
    end
  end

  context 'output handling' do
    it 'moves the built .app into the output directory' do
      seed_simulator_app(tmpdir)
      _out, err, status = run_main(full_env(tmpdir))
      expect(status.exitstatus).to eq(0), "stderr was: #{err}"
      expect(File.directory?(File.join(tmpdir, 'output', 'build_simulator', 'build_simulator.app')))
        .to be true
    end

    it 'reports the resulting simulator app path' do
      seed_simulator_app(tmpdir)
      out, _err, status = run_main(full_env(tmpdir))
      expect(status.exitstatus).to eq(0)
      expect(out).to include('AC_SIMULATOR_APP_PATH : ')
      expect(out).to include('build_simulator/build_simulator.app')
    end

    it 'writes the resulting path into the env file' do
      seed_simulator_app(tmpdir)
      _out, _err, status = run_main(full_env(tmpdir))
      expect(status.exitstatus).to eq(0)
      expect(File.read(File.join(tmpdir, 'env_file')))
        .to match(%r{AC_SIMULATOR_APP_PATH=.*build_simulator/build_simulator\.app})
    end

    it 'fails when the build produced no .app to move' do
      _out, _err, status = run_main(full_env(tmpdir))
      expect(status.exitstatus).not_to eq(0)
    end
  end

  context 'build failure' do
    it 'exits non-zero when xcodebuild fails' do
      seed_simulator_app(tmpdir)
      _out, _err, status = run_main(full_env(tmpdir), stub_source: XCODEBUILD_FAILING_STUB_SOURCE)
      expect(status.exitstatus).not_to eq(0)
    end

    it 'surfaces the xcodebuild stderr output' do
      seed_simulator_app(tmpdir)
      _out, err, _status = run_main(full_env(tmpdir), stub_source: XCODEBUILD_FAILING_STUB_SOURCE)
      expect(err).to include('stub-xcodebuild failure details')
    end

    it 'does not write the env file when the build fails' do
      seed_simulator_app(tmpdir)
      run_main(full_env(tmpdir), stub_source: XCODEBUILD_FAILING_STUB_SOURCE)
      expect(File.exist?(File.join(tmpdir, 'env_file'))).to be false
    end
  end
end

# ─── 8. Loading main.rb as a library ──────────────────────────────────────────
RSpec.describe 'loading main.rb as a library' do
  it 'does not execute the step body when required' do
    out, _err, status = Open3.capture3(
      { 'AC_TEMP_DIR' => nil, 'AC_OUTPUT_DIR_PATH' => nil,
        'AC_PROJECT_PATH' => nil, 'AC_SCHEME' => nil },
      RbConfig.ruby, '-e', "require '#{MAIN_RB}'; puts 'loaded'"
    )
    expect(status.exitstatus).to eq(0)
    expect(out).to include('loaded')
    expect(out).not_to include('@@[command]')
  end

  it 'defines every function under test' do
    out, _err, status = Open3.capture3(
      RbConfig.ruby, '-e',
      "require '#{MAIN_RB}'; " \
      'puts %i[env_has_key get_env_variable start_simulator install_app archive runCommand]' \
      '.all? { |m| respond_to?(m, true) }'
    )
    expect(status.exitstatus).to eq(0)
    expect(out.strip).to eq('true')
  end
end

# ─── Coverage Report ──────────────────────────────────────────────────────────
def print_coverage_report
  return unless defined?(Coverage) && Coverage.running?

  result = begin
    Coverage.result(stop: false, clear: false)
  rescue ArgumentError
    Coverage.result
  end

  main_path = result.keys.find { |p| p&.end_with?('main.rb') }
  return puts("\nCoverage: main.rb not found in results") unless main_path

  data      = result[main_path]
  lines     = data.each_with_index.reject { |c, _| c.nil? }
  total     = lines.size
  covered   = lines.count { |c, _| c.to_i > 0 }
  pct       = total.positive? ? (covered * 100.0 / total).round(1) : 100.0
  uncovered = lines.select { |c, _| c.to_i == 0 }.map { |_, i| i + 1 }

  color = pct == 100 ? "\e[32;1m" : pct >= 80 ? "\e[33m" : "\e[31m"
  bar_filled = (pct / 5).round
  bar = "\e[32m" + '█' * bar_filled + "\e[90m" + '░' * (20 - bar_filled) + "\e[0m"

  puts "\n\e[90m#{'═' * 72}\e[0m"
  puts '  Coverage Report'
  puts "\e[90m#{'─' * 72}\e[0m"
  puts "  main.rb  #{bar}  #{color}#{pct}%\e[0m  (#{covered}/#{total} lines)"
  if uncovered.any? && uncovered.size <= 20
    puts "  Uncovered lines: \e[90m#{uncovered.join(', ')}\e[0m"
  elsif uncovered.any?
    puts "  Uncovered lines: \e[90m#{uncovered.first(15).join(', ')} … (+#{uncovered.size - 15} more)\e[0m"
  end
  puts "\e[90m#{'═' * 72}\e[0m"
end

# ─── Runner ───────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  RSpec.configure do |config|
    config.add_formatter ReadableFormatter
    config.color = true
    config.order = :defined
  end

  exit_code = RSpec::Core::Runner.run(['--order', 'defined'])
  print_coverage_report
  exit exit_code
end
