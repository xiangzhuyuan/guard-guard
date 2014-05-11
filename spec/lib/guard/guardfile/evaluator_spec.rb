require 'spec_helper'

describe Guard::Guardfile::Evaluator do

  let(:local_guardfile) { File.expand_path(File.join(Dir.pwd, 'Guardfile')) }
  let(:home_guardfile) { File.expand_path(File.join('~', '.Guardfile')) }
  let(:home_config) { File.expand_path(File.join('~', '.guard.rb')) }
  let(:guardfile_evaluator) { described_class.new }
  before do
    allow(::IO).to receive(:read) { |file| raise "IO stub called for: #{file}" }
    allow(::Guard).to receive(:setup_interactor)
    #::Guard.setup
    allow(::Guard::Notifier).to receive(:notify)
  end

  def self.disable_user_config
    before {
      allow(IO).to receive(:read).with(home_config) { raise Errno::ENOENT }
    }
  end

  describe '.initialize' do
    disable_user_config

    context 'with the :guardfile_contents option' do
      let(:guardfile_evaluator) { described_class.new(guardfile_contents: valid_guardfile_string) }

      it 'uses the given Guardfile content' do
        guardfile_evaluator.evaluate

        expect(::Guard.groups.map(&:name)).to include(:default)
      end
    end

  end


  describe '.evaluate' do
    describe 'errors cases' do
      context 'with an invalid Guardfile' do
        it 'displays an error message and raises original exception' do
          expect(Guard::UI).to receive(:error).with(/Evaluating guardfiles failed: undefined method/)
          expect { described_class.new(guardfile_contents: 'Bad Guardfile').evaluate }.to raise_error(NoMethodError)
        end
      end

      context 'with no Guardfile at all' do
        it 'displays an error message and exits' do
          expect(IO).to receive(:read).twice { raise Errno::ENOENT }
          expect(Guard::UI).to receive(:error).with("Guardfile #{Pathname.pwd.join('Guardfile')} not found, please create one with `guard init`.")
          expect { guardfile_evaluator.evaluate }.to raise_error(SystemExit)
        end
      end

      context 'with a problem reading a Guardfile' do
        before { allow(File).to receive(:read).with(File.expand_path('Guardfile')) { raise Errno::EACCES.new('permission error') } }

        it 'displays an error message and exits' do
          expect(Guard::UI).to receive(:error).with(/^Error reading file/)
          expect { described_class.new.evaluate }.to raise_error(SystemExit)
        end
      end

      context 'with empty Guardfile content' do
        let(:guardfile_evaluator) { described_class.new(guardfile_contents: '') }

        it 'does not display an error message' do
          expect(Guard::UI).to receive(:error).with('No plugins found in Guardfile, please add at least one.')
          guardfile_evaluator.evaluate
        end
      end

      context 'with Guardfile content is nil' do
        let(:guardfile_evaluator) { described_class.new(guardfile_contents: nil) }

        it 'does not raise error and skip it' do
          allow(IO).to receive(:read) { "guard :rspec do; end" }
          expect(Guard::UI).to_not receive(:error)
          expect { described_class.new(guardfile_contents: nil).evaluate }.to_not raise_error
        end
      end

      context 'with a non-existing Guardfile given' do
        let(:guardfile_evaluator) { described_class.new(guardfiles: '/non/existing/path/to/Guardfile') }

        it 'raises error' do
          allow(IO).to receive(:read) { raise Errno::ENOENT }
          expect(Guard::UI).to receive(:error).with('No Guardfile exists at /non/existing/path/to/Guardfile.')
          expect { guardfile_evaluator.evaluate }.to raise_error
        end
      end
    end

    describe 'selection of the Guardfile data source' do
      before do
        allow_any_instance_of(Guard::Guardfile::Evaluator).to receive(:_instance_eval_guardfile)
      end
      disable_user_config

      context 'with no option' do
        let(:guardfile_evaluator) { described_class.new }

        context 'home Guardfile'  do
          before do
            allow(IO).to receive(:read).with(local_guardfile) { raise Errno::ENOENT }
            fake_guardfile(home_guardfile, valid_guardfile_string)
          end
        end
      end

      context 'with the :guardfile_contents option' do
        let(:guardfile_evaluator) { described_class.new(guardfile_contents: valid_guardfile_string) }

        context 'with other Guardfiles available' do
          let(:guardfile_evaluator) { described_class.new(guardfile_contents: valid_guardfile_string, guardfile: '/abc/Guardfile') }
          before do
            fake_guardfile('/abc/Guardfile', 'guard :foo')
            fake_guardfile(local_guardfile, 'guard :bar')
            fake_guardfile(home_guardfile, 'guard :bar')
          end
        end

      end

      context 'with the :guardfile option' do
        let(:guardfile_evaluator) { described_class.new(guardfiles: '../relative_path_to_Guardfile') }
        before do
          fake_guardfile(File.expand_path('../relative_path_to_Guardfile'), valid_guardfile_string)
          fake_guardfile('/abc/Guardfile', 'guard :foo')
        end

      end
    end

    it 'displays an error message when no guard are defined in Guardfile' do
      allow(IO).to receive(:read) { "" }
      expect(Guard::UI).to receive(:error).with('No plugins found in Guardfile, please add at least one.')

      subject.evaluate
    end

  end

  describe '.reevaluate' do
    before do
      allow(::Guard.runner).to receive(:run)
    end
    let(:growl) { { name: :growl, options: {} } }

    describe 'before reevaluation' do
      before do
        allow(IO).to receive(:read) { "" }
      end

      it 'stops all Guards' do
        expect(::Guard.runner).to receive(:run).with(:stop)

        guardfile_evaluator.reevaluate
      end

      it 'resets all Guard plugins' do
        expect(::Guard).to receive(:reset_plugins)

        guardfile_evaluator.reevaluate
      end

      it 'resets all groups' do
        expect(::Guard).to receive(:reset_groups)

        guardfile_evaluator.reevaluate
      end

      it 'resets all scopes' do
        expect(::Guard).to receive(:reset_scope)

        guardfile_evaluator.reevaluate
      end

      it 'clears the notifiers' do
         ::Guard::Notifier.turn_off
         ::Guard::Notifier.notifiers = [growl]
         expect(::Guard::Notifier.notifiers).to_not be_empty

         guardfile_evaluator.reevaluate

         expect(::Guard::Notifier.notifiers).to be_empty
      end
    end

    it 'evaluates the Guardfile' do
      allow(IO).to receive(:read) { "" }
      guardfile_evaluator.evaluate
      expect(guardfile_evaluator).to receive(:evaluate)

      guardfile_evaluator.reevaluate
    end

    describe 'after reevaluation' do
      context 'with notifications enabled' do
        before { allow(::Guard::Notifier).to receive(:enabled?).and_return(true) }

        it 'enables the notifications again' do
          allow(IO).to receive(:read) { "" }
          expect(::Guard::Notifier).to receive(:turn_on)

          guardfile_evaluator.reevaluate
        end
      end

      context 'with notifications disabled' do
        before { allow(::Guard::Notifier).to receive(:enabled?).and_return(false) }

        it 'does not enable the notifications again' do
          allow(IO).to receive(:read) { "" }
          expect(::Guard::Notifier).to_not receive(:turn_on)

          guardfile_evaluator.reevaluate
        end
      end

      context 'with Guards afterwards' do
        before do
          allow(IO).to receive(:read) { "guard :rspec do; end" }
          allow(::Guard.runner).to receive(:run)
        end

        it 'shows a success message' do
          expect(::Guard::UI).to receive(:info).with('Guardfile has been re-evaluated.')

          guardfile_evaluator.reevaluate
        end

        it 'shows a success notification' do
          expect(::Guard::Notifier).to receive(:notify).with('Guardfile has been re-evaluated.', title: 'Guard re-evaluate')

          guardfile_evaluator.reevaluate
        end

        it 'starts all Guards' do
          expect(::Guard.runner).to receive(:run).with(:start)

          guardfile_evaluator.reevaluate
        end
      end

      context 'without Guards afterwards' do
        it 'shows a failure notification' do
          allow(IO).to receive(:read) { "" }
          expect(::Guard::Notifier).to receive(:notify).with('No plugins found in Guardfile, please add at least one.', title: 'Guard re-evaluate', image: :failed)

          guardfile_evaluator.reevaluate
        end
      end
    end
  end

  private

  def fake_guardfile(name, contents)
    allow(IO).to receive(:read).with(name)   { contents }
  end

  def valid_guardfile_string
    '
    notification :growl

    guard :rspec

    group :w do
      guard :rspec
    end

    group :x, halt_on_fail: true do
      guard :rspec
      guard :rspec
    end

    group :y do
      guard :rspec
    end
    '
  end
end
