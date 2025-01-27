require 'bundler'
require 'childprocess'
require 'English'
require 'tempfile'
require 'tty-spinner'
require 'tty-which'

require 'pdk/util'
require 'pdk/util/git'
require 'pdk/util/ruby_version'

module PDK
  module CLI
    module Exec
      class Command
        attr_reader :argv
        attr_reader :context
        attr_accessor :timeout
        attr_accessor :environment
        attr_writer :exec_group

        def initialize(*argv)
          @argv = argv

          @process = ChildProcess.build(*@argv)
          @process.leader = true

          @stdout = Tempfile.new('stdout').tap { |io| io.sync = true }
          @stderr = Tempfile.new('stderr').tap { |io| io.sync = true }

          @process.io.stdout = @stdout
          @process.io.stderr = @stderr

          # Default to running things in the system context.
          @context = :system

          # Extra environment vars to add to base set.
          @environment = {}

          # Register the ExecGroup when running in parallel
          @exec_group = nil
        end

        def context=(new_context)
          unless [:system, :module, :pwd].include?(new_context)
            raise ArgumentError, _("Expected execution context to be :system or :module but got '%{context}'.") % { context: new_context }
          end

          @context = new_context
        end

        def register_spinner(spinner, opts = {})
          return unless PDK::CLI::Util.interactive?
          @success_message = opts.delete(:success)
          @failure_message = opts.delete(:failure)

          @spinner = spinner
        end

        def add_spinner(message, opts = {})
          return unless PDK::CLI::Util.interactive?
          @success_message = opts.delete(:success)
          @failure_message = opts.delete(:failure)

          @spinner = TTY::Spinner.new("[:spinner] #{message}", opts.merge(PDK::CLI::Util.spinner_opts_for_platform))
        end

        def update_environment(additional_env)
          @environment.merge!(additional_env)
        end

        def execute!
          # Start spinning if configured.
          @spinner.auto_spin if @spinner

          # Set env for child process
          resolved_env_for_command.each { |k, v| @process.environment[k] = v }

          if [:module, :pwd].include?(context)
            mod_root = PDK::Util.module_root

            unless mod_root
              @spinner.error if @spinner

              raise PDK::CLI::FatalError, _('Current working directory is not part of a module. (No metadata.json was found.)')
            end

            if Dir.pwd == mod_root || context == :pwd
              run_process_in_clean_env!
            else
              Dir.chdir(mod_root) do
                run_process_in_clean_env!
              end
            end
          else
            run_process!
          end

          # Stop spinning when done (if configured).
          stop_spinner

          @stdout.rewind
          @stderr.rewind

          process_data = {
            stdout: @stdout.read,
            stderr: @stderr.read,
            exit_code: @process.exit_code,
            duration: @duration,
          }

          PDK.logger.debug _('STDOUT: %{output}') % {
            output: process_data[:stdout].empty? ? 'N/A' : "\n#{process_data[:stdout]}",
          }
          PDK.logger.debug _('STDERR: %{output}') % {
            output: process_data[:stderr].empty? ? 'N/A' : "\n#{process_data[:stderr]}",
          }

          process_data
        ensure
          @stdout.close
          @stderr.close
        end

        protected

        def warn_on_legacy_env_vars!
          if ENV['PUPPET_GEM_VERSION']
            PDK.logger.warn_once _(
              'PUPPET_GEM_VERSION is not supported by PDK. ' \
              'Use the --puppet-version option on your PDK command ' \
              'or set the PDK_PUPPET_VERSION environment variable instead',
            )
          end

          %w[FACTER HIERA].each do |gem|
            if ENV["#{gem}_GEM_VERSION"]
              PDK.logger.warn_once _('%{varname} is not supported by PDK.') % { varname: "#{gem}_GEM_VERSION" }
            end
          end
        end

        def resolved_env_for_command
          warn_on_legacy_env_vars!

          resolved_env = {}

          resolved_env['TERM'] = ENV['TERM']
          resolved_env['PUPPET_GEM_VERSION'] = nil
          resolved_env['FACTER_GEM_VERSION'] = nil
          resolved_env['HIERA_GEM_VERSION'] = nil

          resolved_env.merge!(@environment.dup)

          resolved_env['BUNDLE_IGNORE_CONFIG'] = '1'

          if [:module, :pwd].include?(context)
            resolved_env['GEM_HOME'] = PDK::Util::RubyVersion.gem_home
            resolved_env['GEM_PATH'] = PDK::Util::RubyVersion.gem_path

            # Make sure invocation of Ruby prefers our private installation.
            package_binpath = PDK::Util.package_install? ? File.join(PDK::Util.pdk_package_basedir, 'bin') : nil

            resolved_env['PATH'] = [
              PDK::Util::RubyVersion.bin_path,
              File.join(resolved_env['GEM_HOME'], 'bin'),
              PDK::Util::RubyVersion.gem_paths_raw.map { |gem_path| File.join(gem_path, 'bin') },
              package_binpath,
              PDK::Util.package_install? ? PDK::Util::Git.git_paths : nil,
              ENV['PATH'],
            ].compact.flatten.join(File::PATH_SEPARATOR)
          end

          resolved_env
        end

        def stop_spinner
          return unless @spinner

          # If it is a single spinner, we need to send it a success/error message
          if @process.exit_code.zero?
            @spinner.success(@success_message || '')
          else
            @spinner.error(@failure_message || '')
          end
        end

        def run_process_in_clean_env!
          ::Bundler.with_clean_env do
            run_process!
          end
        end

        def run_process!
          command_string = argv.join(' ')

          PDK.logger.debug(_("Executing '%{command}'") % { command: command_string })

          if context == :module
            PDK.logger.debug(_('Command environment:'))
            @process.environment.each do |var, val|
              PDK.logger.debug("  #{var}: #{val}")
            end
          end

          start_time = Time.now

          begin
            @process.start
          rescue ChildProcess::LaunchError => e
            raise PDK::CLI::FatalError, _("Failed to execute '%{command}': %{message}") % { command: command_string, message: e.message }
          end

          if timeout
            begin
              @process.poll_for_exit(timeout)
            rescue ChildProcess::TimeoutError
              @process.stop # tries increasingly harsher methods to kill the process.
            end
          else
            # Wait indfinitely if no timeout set.
            @process.wait
          end

          @duration = Time.now - start_time

          PDK.logger.debug(_("Execution of '%{command}' complete (duration: %{duration_in_seconds}s; exit code: %{exit_code})") %
            { command: command_string, duration_in_seconds: @duration, exit_code: @process.exit_code })
        end
      end
    end
  end
end
