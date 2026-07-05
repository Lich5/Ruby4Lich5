# frozen_string_literal: true

require 'ruby4lich5/safe_token'

RSpec.describe Ruby4Lich5::SafeToken do
  describe '.validate!' do
    it 'accepts a valid token silently' do
      expect { described_class.validate!('gtk3', 'gem name') }.not_to raise_error
    end

    it 'rejects nil' do
      expect { described_class.validate!(nil, 'gem name') }
        .to raise_error(ArgumentError, /must not be nil or empty/)
    end

    it 'rejects an empty string' do
      expect { described_class.validate!('', 'gem name') }
        .to raise_error(ArgumentError, /must not be nil or empty/)
    end

    it 'rejects a whitespace-only string' do
      expect { described_class.validate!('   ', 'gem name') }
        .to raise_error(ArgumentError, /must not be nil or empty/)
    end

    it 'rejects a path-separator, blocking traversal' do
      expect { described_class.validate!('../lib/ruby4lich5', 'gem name') }
        .to raise_error(ArgumentError, /disallowed characters/)
    end

    it 'rejects a bare "." even though "." is individually an allowed character' do
      # File.join(patches_root, ".") resolves to patches_root itself -- not a
      # traversal, but not a real gem-name directory lookup either.
      expect { described_class.validate!('.', 'gem name') }
        .to raise_error(ArgumentError, /disallowed characters/)
    end

    it 'rejects a bare ".." (verified to escape patches_root via File.join otherwise)' do
      expect { described_class.validate!('..', 'gem name') }
        .to raise_error(ArgumentError, /disallowed characters/)
    end

    it 'rejects a non-String with ArgumentError, not TypeError, even when it would stringify to something valid' do
      # :gtk3.to_s is "gtk3" -- a valid-looking token if coerced. Rejecting it
      # up front, rather than coercing and validating the coerced result, is
      # what stops a caller from going on to use the original Symbol
      # afterward and getting silently wrong behavior (e.g. comparing it
      # against a String literal, which is never true for a Symbol).
      expect { described_class.validate!(:gtk3, 'gem name') }
        .to raise_error(ArgumentError, /must be a String, got Symbol/)
    end

    it 'rejects a non-String whose stringified form also fails the pattern' do
      expect { described_class.validate!({ a: 1 }, 'gem name') }
        .to raise_error(ArgumentError, /must be a String, got Hash/)
    end
  end
end
