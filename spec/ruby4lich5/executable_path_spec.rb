# frozen_string_literal: true

require 'ruby4lich5/executable_path'
require 'rbconfig'
require 'tempfile'

RSpec.describe Ruby4Lich5::ExecutablePath do
  describe '.validate!' do
    it 'accepts a real, absolute, executable path silently' do
      expect { described_class.validate!(RbConfig.ruby, 'ruby_exe') }.not_to raise_error
    end

    it 'rejects nil' do
      expect { described_class.validate!(nil, 'ruby_exe') }
        .to raise_error(ArgumentError, /must not be nil or empty/)
    end

    it 'rejects a non-String with ArgumentError, not TypeError' do
      expect { described_class.validate!(123, 'ruby_exe') }
        .to raise_error(ArgumentError, /must be a String, got Integer/)
    end

    it 'rejects a bare command name resolved via PATH rather than an absolute path' do
      # The exact regression this exists to prevent: a caller passing "ruby"
      # instead of the specific baked-tree executable.
      expect { described_class.validate!('ruby', 'ruby_exe') }
        .to raise_error(ArgumentError, /must be an absolute path/)
    end

    it 'rejects an absolute path that does not exist' do
      expect { described_class.validate!('/no/such/path/ruby', 'ruby_exe') }
        .to raise_error(ArgumentError, /does not exist/)
    end

    it 'rejects an absolute, existing path that is not executable' do
      Tempfile.create('ruby4lich5-not-executable') do |file|
        File.chmod(0o644, file.path)
        expect { described_class.validate!(file.path, 'ruby_exe') }
          .to raise_error(ArgumentError, /is not executable/)
      end
    end
  end
end
