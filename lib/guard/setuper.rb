require 'thread'
require 'listen'
require 'thor/core_ext/hash_with_indifferent_access'

module Guard

  module Setuper

    DEFAULT_OPTIONS = {
      clear: false,
      notify: true,
      debug: false,
      group: [],
      plugin: [],
      watchdir: nil,
      guardfile: nil,
      no_interactions: false,
      no_bundler_warning: false,
      show_deprecations: false,
      latency: nil,
      force_polling: false,
      wait_for_delay: nil,
      listen_on: nil
    }
    DEFAULT_GROUPS = [:default]

    # Initializes the Guard singleton:
    #
    # * Initialize the internal Guard state;
    # * Create the interactor when necessary for user interaction;
    # * Select and initialize the file change listener.
    #
    # @option options [Boolean] clear if auto clear the UI should be done
    # @option options [Boolean] notify if system notifications should be shown
    # @option options [Boolean] debug if debug output should be shown
    # @option options [Array<String>] group the list of groups to start
    # @option options [Array<String>] watchdir the directories to watch
    # @option options [String] guardfile the path to the Guardfile
    #
    # @return [Guard] the Guard singleton
    #
    def setup(opts = {})
      hash_class = Thor::CoreExt::HashWithIndifferentAccess
      @options = hash_class.new(DEFAULT_OPTIONS.merge(opts))

      @running   = true
      @lock      = Mutex.new
      @runner    = ::Guard::Runner.new

      @watchdirs = _watchdirs

      ::Guard::UI.clear(force: true)
      _setup_debug if options[:debug]
      _setup_listener
      _setup_signal_traps

      reset_groups
      reset_plugins
      reset_scope

      @evaluator = ::Guard::Guardfile::Evaluator.new(opts)
      evaluator.evaluate

      setup_scope(groups: options[:group], plugins: options[:plugin])

      _setup_notifier

      self
    end

    attr_reader :options, :evaluator

    # Lazy initializer the interactor unless the user has specified not to.
    #
    def interactor
      return if options[:no_interactions] || !::Guard::Interactor.enabled

      @interactor ||= ::Guard::Interactor.new
    end

    # Clear Guard's options hash
    #
    def clear_options
      @options = nil
    end

    # Initializes the groups array with the default group(s).
    #
    # @see DEFAULT_GROUPS
    #
    def reset_groups
      @groups = DEFAULT_GROUPS.map { |name| Group.new(name) }
    end

    # Initializes the plugins array to an empty array.
    #
    # @see Guard.plugins
    #
    def reset_plugins
      @plugins = []
    end

    # Initializes the scope hash to `{ groups: [], plugins: [] }`.
    #
    # @see Guard.setup_scope
    #
    def reset_scope
      @scope = { groups: [], plugins: [] }
    end

    attr_reader :watchdirs

    # Stores the scopes defined by the user via the `--group` / `-g` option (to run
    # only a specific group) or the `--plugin` / `-P` option (to run only a
    # specific plugin).
    #
    # @see CLI#start
    # @see Dsl#scope
    #
    def setup_scope(new_scope)
      if new_scope[:groups] && new_scope[:groups].any?
        scope[:groups]  = new_scope[:groups].map { |group| ::Guard.add_group(group) }
      end

      if new_scope[:plugins] && new_scope[:plugins].any?
        scope[:plugins] = new_scope[:plugins].map { |plugin| ::Guard.plugin(plugin) }
      end
    end

    private

    # Sets up various debug behaviors:
    #
    # * Abort threads on exception;
    # * Set the logging level to `:debug`;
    # * Modify the system and ` methods to log themselves before being executed
    #
    # @see #_debug_command_execution
    #
    def _setup_debug
      Thread.abort_on_exception = true
      ::Guard::UI.options[:level] = :debug
      _debug_command_execution
    end

    # Initializes the listener and registers a callback for changes.
    #
    def _setup_listener
      if options[:listen_on]
        @listener = Listen.on(options[:listen_on], &_listener_callback)
      else
        listener_options = {}
        [:latency, :force_polling, :wait_for_delay].each do |option|
          listener_options[option] = options[option] if options[option]
        end
        listen_args = watchdirs + [listener_options]
        @listener = Listen.to(*listen_args, &_listener_callback)
      end
    end

    # Sets up traps to catch signals used to control Guard.
    #
    # Currently two signals are caught:
    # - `USR1` which pauses listening to changes.
    # - `USR2` which resumes listening to changes.
    # - 'INT' which is delegated to Pry if active, otherwise stops Guard.
    #
    def _setup_signal_traps
      unless defined?(JRUBY_VERSION)
        if Signal.list.keys.include?('USR1')
          Signal.trap('USR1') do
            unless listener.paused?
              Thread.new { within_preserved_state { ::Guard.pause } }
            end
          end
        end

        if Signal.list.keys.include?('USR2')
          Signal.trap('USR2') do
            if listener.paused?
              Thread.new { within_preserved_state { ::Guard.pause } }
            end
          end
        end

        if Signal.list.keys.include?('INT')
          Signal.trap('INT') do
            if interactor && interactor.thread
              interactor.thread.raise(Interrupt)
            else
              ::Guard.stop
            end
          end
        end
      end
    end

    # Enables or disables the notifier based on user's configurations.
    #
    def _setup_notifier
      if options[:notify] && ENV['GUARD_NOTIFY'] != 'false'
        ::Guard::Notifier.turn_on
      else
        ::Guard::Notifier.turn_off
      end
    end

    # Adds a command logger in debug mode. This wraps common command
    # execution functions and logs the executed command before execution.
    #
    def _debug_command_execution
      Kernel.send(:alias_method, :original_system, :system)
      Kernel.send(:define_method, :system) do |command, *args|
        ::Guard::UI.debug "Command execution: #{ command } #{ args.join(' ') }"
        Kernel.send :original_system, command, *args
      end

      Kernel.send(:alias_method, :original_backtick, :'`')
      Kernel.send(:define_method, :'`') do |command|
        ::Guard::UI.debug "Command execution: #{ command }"
        Kernel.send :original_backtick, command
      end
    end

    # Check if any of the changes are actually watched for
    #
    # NOTE: this is called from the listen thread - be careful to not
    # modify any state
    #
    # TODO: move this to watcher class?
    #
    def _relevant_changes?(changes)
      # TODO: make a Guardfile reloader "plugin" instead of a special case
      return true if ::Guard::Watcher.match_guardfile?(changes[:modified])

      # TODO: ignoring irrelevant files should be Listen's responsibility
      all_files = changes.values.flatten(1)
      runner.send(:_scoped_plugins) do |guard|
        return true if ::Guard::Watcher.match_files?([guard], all_files)
      end
      false
    end

    def _relative_paths(files)
      [].tap do |result|
        # Convert to relative paths (respective to the watchdir it came from)
        files.uniq.each do |file|
          file = Pathname(file)

          if file.relative?
            raise "Not supported yet!"
            result << file
          else
            result << _find_relative(file)
          end

        end
      end
    end

    def _listener_callback
      lambda do |modified, added, removed|
        # TODO: Listen should provide relative paths
        all_changes = { modified: _relative_paths(modified),
                        added: _relative_paths(added),
                        removed: _relative_paths(removed) }

        if _relevant_changes?(all_changes)
          within_preserved_state do
            runner.run_on_changes(*all_changes.values)
          end
        end
      end
    end

    def _watchdirs
      dirs = Array(options[:watchdir]).map {|dir| Pathname.new(dir) }
      return [Pathname.pwd] if dirs.empty?
      dirs.map(&:expand_path)
    end

    def _find_relative(path)
      watchdirs.each do |watchdir|
        begin
          rel = path.relative_path_from(watchdir)
          in_base = rel.to_s.split(Pathname::SEPARATOR_PAT).all? {|p| p != '..' }
          return rel if in_base
        rescue ArgumentError
        end
      end
      raise "File not watched: #{file.to_s} within: #{watchdirs.inspect}"
    end

  end
end
