module Guard
  module Guardfile
    # interface for guard dsl sources
    class Source
      attr_reader :path

      def initialize(path)
        @path = path
      end

      def eval
        return unless (current_content = content)
        ::Guard::Dsl.new.instance_eval(current_content, path.to_s, 1)
      end
    end

    # inline Guard dsl to evaluate
    class InlineSource < Source
      def initialize(content)
        @content = content
        super('(inline)')
      end

      def content
        ::Guard::UI.info 'Using inline Guardfile.'
        @content
      end

      def source?(file)
        false
      end
    end

    # Guard dsl loaded from file
    class FileSource < Source
      def initialize(path, options = {})
        @fallback = options[:fallback]
        @optional = options[:optional]
        super(path)
      end

      def content
        content = _read(path)
        return content if content || @optional

        if @fallback
          content = _read(@fallback)
          return unless content.nil?

          ::Guard::UI.error "Guardfile #{path} not found, please create one with `guard init`."
        else
          ::Guard::UI.error "No Guardfile exists at #{ path }."
        end
        abort 'Failed to read Guardfile'
      end

      def source?(file)
        file_path = Pathname.new(file).expand_path
        return true if path.expand_path == file_path
        @fallback && (@fallback.expand_path == file_path)
      end

      private

      def _read(rel_path)
        ::Guard::UI.info "Using Guardfile at #{ rel_path }."
        File.read(File.expand_path(rel_path))
      rescue Errno::ENOENT
        ::Guard::UI.info "Failed to read: #{ rel_path }."
        nil
      rescue StandardError => ex
        ::Guard::UI.error "Error reading file #{ rel_path }:"
        ::Guard::UI.error ex.inspect
        ::Guard::UI.error ex.backtrace
        abort
      end
    end

    # Evaluates default and custom Guard dsl and config files
    class Evaluator
      GUARDFILE = Pathname.pwd + 'Guardfile'
      DEFAULT = Pathname.new('~') + '.Guardfile'
      USER = Pathname.new('~') + '.guard.rb'

      def initialize(options = {})
        inline = options[:guardfile_contents]

        user_guardfiles = []
        Array(options[:guardfiles]).map do |path|
          unless path.nil? || path.empty?
            user_guardfiles << FileSource.new(path)
          end
        end

        @sources = _select_guardfiles(inline, user_guardfiles)
      end

      def evaluate
        @sources.each(&:eval)
        if ::Guard.plugins.empty?
          ::Guard::UI.error 'No plugins found in Guardfile, please add at least one.'
        end
      rescue StandardError => e
        ::Guard::UI.error "Evaluating guardfiles failed: #{ e }"
        raise
      end

      def reevaluate
        _before_reevaluate
        evaluate
        _after_reevaluate
      end

      def source?(file)
        @sources.any? { |source| source.source?(file) }
      end

      private

      def _before_reevaluate
        ::Guard.runner.run(:stop)
        ::Guard.reset_groups
        ::Guard.reset_plugins
        ::Guard.reset_scope
        ::Guard::Notifier.clear_notifiers
      end

      def _after_reevaluate
        ::Guard::Notifier.turn_on if ::Guard::Notifier.enabled?

        if ::Guard.plugins.empty?
          ::Guard::Notifier.notify('No plugins found in Guardfile, please add at least one.', title: 'Guard re-evaluate', image: :failed)
        else
          msg = 'Guardfile has been re-evaluated.'
          ::Guard::UI.info(msg)
          ::Guard::Notifier.notify(msg, title: 'Guard re-evaluate')

          ::Guard.runner.run(:start)
        end
      end

      def _select_guardfiles(inline, user_guardfiles)
        if inline
          [InlineSource.new(inline)]
        elsif user_guardfiles.any?
          user_guardfiles
        else
          [FileSource.new(GUARDFILE, fallback: DEFAULT),
            FileSource.new(USER, optional: true)
          ]
        end
      end
    end
  end
end
